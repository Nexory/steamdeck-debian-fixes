#!/usr/bin/env python3
"""Hands-free wake word loop for a fully local voice front-end.

Pipeline per utterance:

    arecord (raw 16 kHz mono)
      -> openWakeWord  ("hey jarvis")            wake word detection
      -> Silero VAD                              record until silence
      -> voiced.py /?path=...                    speech to text
      -> LLM_CMD                                 generate a reply
      -> voiced.py /tts?text=...                 text to speech
      -> paplay / pw-play / aplay                playback

This file is a front-end and nothing else. It has no idea what it is being
asked, it just moves audio and text around. Whatever you point LLM_CMD at
decides what the assistant can actually do.

voiced.py must already be listening on 127.0.0.1:9977. It runs as a user
systemd service, so do not start it from here as well.

Stop with Ctrl+C. Every setting below can be overridden with an environment
variable, see voice.env.example.
"""

import fcntl
import glob
import os
import re
import shlex
import subprocess
import time
import urllib.parse
import urllib.request
import wave

import numpy as np
import onnxruntime as ort
import openwakeword
from openwakeword.model import Model

# --- audio devices -----------------------------------------------------------
# Run "arecord -l" and "aplay -l" to find your card and device numbers.
MIC = os.environ.get("MIC_DEV", "plughw:1,0")
SPK = os.environ.get("SPK_DEV", "plughw:1,1")

# --- wake word ---------------------------------------------------------------
WAKE = os.environ.get("WAKE_MODEL", "hey_jarvis_v0.1")
THRESH = float(os.environ.get("WAKE_THRESH", "0.5"))

# --- voice activity detection ------------------------------------------------
VAD_ON = float(os.environ.get("VAD_ON", "0.5"))      # speech starts above this
VAD_OFF = float(os.environ.get("VAD_OFF", "0.35"))   # silence below this
END_MS = int(os.environ.get("END_MS", "650"))        # silence that ends an utterance
ONSET_MS = int(os.environ.get("ONSET_MS", "3000"))   # wait for speech after the wake word
FOLLOWUP_MS = int(os.environ.get("FOLLOWUP_MS", "6000"))  # follow up without a new wake word
MAX_UTTER_MS = int(os.environ.get("MAX_UTTER_MS", "9000"))  # hard cap on one recording
MIC_GAIN = float(os.environ.get("MIC_GAIN", "20"))   # ceiling for the soft normalizer

CHUNK = 1280   # 80 ms, the frame size openWakeWord expects
VCHUNK = 512   # 32 ms, the frame size Silero VAD expects
RATE = 16000

# --- endpoints and paths -----------------------------------------------------
VOICED = os.environ.get("VOICED_URL", "http://127.0.0.1:9977")
TMP = os.environ.get("VOICE_TMP", "/tmp")
BEEP_WAV = os.path.join(TMP, "voice-beep.wav")
CMD_WAV = os.path.join(TMP, "voice-cmd.wav")
OUT_WAV = os.path.join(TMP, "voice-out.wav")

# Optional hook: a file that is touched whenever the assistant becomes active.
# Another daemon can watch it, for example to switch a display backlight on.
# Nothing breaks if the directory does not exist.
WAKE_FLAG = os.path.expanduser(os.environ.get("WAKE_FLAG", "~/voice/.wake"))

# --- language backend --------------------------------------------------------
# Deliberately generic. LLM_CMD is any command line that reads a prompt on
# stdin and writes a plain text answer to stdout. A locally hosted model
# runner and an API backed CLI both fit that shape, and nothing in this file
# knows or cares which one is behind it. Leave it empty and the assistant
# simply says that no backend is configured, which is a useful way to test
# the audio path on its own.
#
# The transcript is never interpolated into the command line, it is written to
# the child process on stdin. Spoken words therefore cannot turn into shell
# words. LLM_CMD itself is split with shlex; set LLM_SHELL=1 only if you need
# a real shell for pipes or redirection, and remember that you are then
# responsible for what is in LLM_CMD.
LLM_CMD = os.environ.get("LLM_CMD", "")
LLM_SHELL = os.environ.get("LLM_SHELL", "0") == "1"
LLM_TIMEOUT = int(os.environ.get("LLM_TIMEOUT", "120"))

# Persona file, prepended to every prompt. See assistant.example.md.
PERSONA_FILE = os.path.expanduser(
    os.environ.get("PERSONA_FILE", "~/voice/assistant.md"))

# How many previous exchanges to keep so follow up questions make sense.
HISTORY_TURNS = int(os.environ.get("HISTORY_TURNS", "6"))
HISTORY = []


# --- model loading -----------------------------------------------------------

oww = Model(wakeword_models=[WAKE], inference_framework="onnx")


def _find_vad():
    """Locate silero_vad.onnx.

    It ships inside the openwakeword package resources, so the package
    directory is the first and by far the fastest place to look. The home
    directory is only a fallback for unusual layouts.
    """
    override = os.environ.get("SILERO_VAD_PATH", "")
    if override:
        if os.path.exists(override):
            return override
        raise SystemExit("SILERO_VAD_PATH is set but does not exist: %s" % override)
    roots = [
        os.path.dirname(openwakeword.__file__),
        os.path.expanduser("~/voice"),
        os.path.expanduser("~"),
    ]
    for root in roots:
        hits = glob.glob(os.path.join(root, "**", "silero_vad.onnx"), recursive=True)
        if hits:
            return hits[0]
    raise SystemExit("silero_vad.onnx not found, set SILERO_VAD_PATH")


class Vad:
    """Thin wrapper around the Silero VAD ONNX graph.

    The model is stateful: h and c carry across frames, so reset() has to be
    called before every new listening window. Without that reset the detector
    still holds the tail of the previous utterance and fires immediately.
    """

    def __init__(self, path):
        self.s = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        self.reset()

    def reset(self):
        self.h = np.zeros((2, 1, 64), np.float32)
        self.c = np.zeros((2, 1, 64), np.float32)

    def prob(self, samples):
        x = (samples.astype(np.float32) / 32768.0).reshape(1, -1)
        out, self.h, self.c = self.s.run(
            None,
            {"input": x, "sr": np.array(RATE, np.int64), "h": self.h, "c": self.c},
        )
        return float(out[0][0])


vad = Vad(_find_vad())


# --- audio helpers -----------------------------------------------------------

def _tone(freq, dur, sr=RATE):
    t = np.linspace(0, dur, int(sr * dur), False)
    env = np.sin(np.pi * np.linspace(0, 1, t.size))   # fade in and out, no click
    return 0.16 * np.sin(2 * np.pi * freq * t) * env


def _make_beep():
    seg = np.concatenate([_tone(587.33, 0.085), _tone(783.99, 0.11)])
    with wave.open(BEEP_WAV, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((seg * 32767).astype(np.int16).tobytes())


_make_beep()


def play(path):
    """Play a WAV through whatever audio stack is actually present.

    PipeWire and PulseAudio clients respect the session volume, plain ALSA
    does not, so they are tried in that order.
    """
    for cmd in (["paplay", path],
                ["pw-play", path],
                ["aplay", "-q", "-D", SPK, path],
                ["aplay", "-q", path]):
        try:
            if subprocess.run(cmd, stderr=subprocess.DEVNULL).returncode == 0:
                return
        except FileNotFoundError:
            continue


def write_wav(path, raw):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(raw)


def transcribe(path):
    try:
        u = VOICED + "/?path=" + urllib.parse.quote(path)
        return urllib.request.urlopen(u, timeout=60).read().decode().strip()
    except Exception:
        return ""


def speak(text):
    if not text:
        return
    try:
        u = VOICED + "/tts?text=" + urllib.parse.quote(text)
        data = urllib.request.urlopen(u, timeout=30).read()
        with open(OUT_WAV, "wb") as f:
            f.write(data)
        play(OUT_WAV)
    except Exception as exc:
        print("(tts failed: %s)" % exc, flush=True)


# --- language backend --------------------------------------------------------

_MARKUP = re.compile(r"[*_`#>]+")


def _spoken(text):
    """Strip the markup a text model likes to emit. It is being read aloud."""
    text = _MARKUP.sub("", text)
    return re.sub(r"\s+", " ", text).strip()


def _persona():
    try:
        with open(PERSONA_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def ask_llm(text):
    """Send the transcript to the configured backend and return the reply."""
    if not LLM_CMD:
        return "No language backend is configured."

    parts = []
    persona = _persona()
    if persona:
        parts.append(persona)
    for role, line in HISTORY:
        parts.append("%s: %s" % (role, line))
    parts.append("User: %s" % text)
    parts.append("Assistant:")
    prompt = "\n\n".join(parts)

    cmd = LLM_CMD if LLM_SHELL else shlex.split(LLM_CMD)
    try:
        r = subprocess.run(cmd, shell=LLM_SHELL, input=prompt,
                           capture_output=True, text=True, timeout=LLM_TIMEOUT)
    except subprocess.TimeoutExpired:
        return "The language backend took too long."
    except Exception as exc:
        print("(backend failed: %s)" % exc, flush=True)
        return "The language backend could not be started."

    reply = _spoken(r.stdout or "")
    if not reply:
        err = (r.stderr or "").strip().splitlines()
        if err:
            print("(backend stderr: %s)" % err[-1], flush=True)
        return "The language backend returned nothing."

    HISTORY.append(("User", text))
    HISTORY.append(("Assistant", reply))
    while len(HISTORY) > 2 * HISTORY_TURNS:
        HISTORY.pop(0)
    return reply


# --- capture -----------------------------------------------------------------

rec = subprocess.Popen(
    ["arecord", "-q", "-D", MIC, "-f", "S16_LE", "-r", str(RATE),
     "-c", "1", "-t", "raw"],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)


def read_n(n):
    """Read exactly n samples, or None if the recorder died."""
    need = n * 2
    buf = b""
    while len(buf) < need:
        d = rec.stdout.read(need - len(buf))
        if not d:
            return None
        buf += d
    return np.frombuffer(buf, dtype=np.int16)


def drain():
    """Throw away everything arecord buffered while we were busy.

    Without this the assistant hears its own spoken answer and the beep, and
    happily transcribes them as the next command.
    """
    fd = rec.stdout.fileno()
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    try:
        while rec.stdout.read(65536):
            pass
    except Exception:
        pass
    fcntl.fcntl(fd, fcntl.F_SETFL, fl)


def _normalize(raw):
    """Lift a quiet recording toward a usable level.

    Distant speech on a small microphone lands very low, and whisper on a low
    level clip returns short or empty text. The gain is capped so room noise
    in a silent clip is not amplified into something that sounds like speech.
    """
    a = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
    peak = float(np.abs(a).max()) if a.size else 0.0
    if peak > 200:
        a = a * min(0.4 * 32767.0 / peak, MIC_GAIN)
        return np.clip(a, -32768.0, 32767.0).astype(np.int16).tobytes()
    return raw


def capture_from(first):
    """Speech has started (first frame), record until it stops."""
    chunks, sil_ms = [first.tobytes()], 0
    for _ in range(int(MAX_UTTER_MS / 32)):
        s = read_n(VCHUNK)
        if s is None:
            break
        chunks.append(s.tobytes())
        p = vad.prob(s)
        if p >= VAD_ON:
            sil_ms = 0
        elif p < VAD_OFF:
            sil_ms += 32
            if sil_ms >= END_MS:
                break
    return _normalize(b"".join(chunks))


def listen(timeout_ms):
    """Wait for speech to start, then record it. None if nobody spoke."""
    vad.reset()
    waited = 0
    while waited < timeout_ms:
        s = read_n(VCHUNK)
        if s is None:
            return None
        if vad.prob(s) >= VAD_ON:
            return capture_from(s)
        waited += 32
    return None


def wake():
    try:
        open(WAKE_FLAG, "w").close()
    except OSError:
        pass


def handle(raw):
    wake()
    write_wav(CMD_WAV, raw)
    t0 = time.time()
    text = transcribe(CMD_WAV)
    print("(recorded %.1fs, stt %.1fs)"
          % (len(raw) / 2 / float(RATE), time.time() - t0), flush=True)
    if not text:
        print("(nothing understood)", flush=True)
        return
    print("you:       %s" % text, flush=True)
    answer = ask_llm(text)
    print("assistant: %s" % answer, flush=True)
    speak(answer)


print("listening. say the wake word. Ctrl+C quits.", flush=True)
try:
    while True:
        frame = read_n(CHUNK)
        if frame is None:
            break
        if oww.predict(frame).get(WAKE, 0.0) >= THRESH:
            wake()
            play(BEEP_WAV)
            drain()
            raw = listen(ONSET_MS)
            # Conversation mode: keep answering follow ups for a short window
            # so you do not have to repeat the wake word every sentence.
            while raw:
                handle(raw)
                drain()
                raw = listen(FOLLOWUP_MS)
            # The wake word model keeps a rolling score buffer. Without this
            # reset it re-triggers on its own tail right after an exchange.
            oww.reset()
except KeyboardInterrupt:
    pass
finally:
    rec.terminate()
