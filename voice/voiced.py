#!/usr/bin/env python3
"""Local STT/TTS HTTP service for the hands-free voice front-end.

Everything runs on the CPU of the machine itself. No audio and no text leaves
the box through this service.

Endpoints (loopback only, no authentication, never bind this to 0.0.0.0):

    GET /health              -> "ok", used by hey.sh to wait for readiness
    GET /?path=/tmp/cmd.wav  -> transcribes that WAV file, returns UTF-8 text
    GET /tts?text=hello      -> returns a synthesized WAV (audio/wav)

Both models stay resident in this process, so a request costs inference only
and not a model load. That is the whole reason this is a service and not a
script: loading whisper per utterance would add seconds to every answer.

Run it as a user systemd service, see voiced.service in this directory.
"""

import io
import os
import urllib.parse
import wave
from http.server import BaseHTTPRequestHandler, HTTPServer

from faster_whisper import WhisperModel
from piper.config import SynthesisConfig
from piper.voice import PiperVoice

HOST = os.environ.get("VOICED_HOST", "127.0.0.1")
PORT = int(os.environ.get("VOICED_PORT", "9977"))

# Speech to text model, loaded through CTranslate2 in int8 on the CPU.
# "medium" is usable for German but slow (roughly 6s per utterance on this
# class of hardware). The German turbo build below answers in roughly 1-2s at
# comparable quality, which is the difference between a toy and something you
# actually use. The service unit sets this via a drop-in, see
# voiced.service.d/model.conf.
WMODEL = os.environ.get(
    "WHISPER_MODEL", "cstr/whisper-large-v3-turbo-german-int8_float32")
CPU_THREADS = int(os.environ.get("WHISPER_THREADS", "8"))

# Force the language instead of letting whisper guess. Auto detection on a
# short, noisy room recording flips languages between utterances.
LANG = os.environ.get("WHISPER_LANG", "de")

# Small vocabulary hint. Whisper biases toward words it has just seen, so
# listing the handful of phrases you actually say cuts down on look-alike
# misreads of short commands. Keep this short: a long prompt costs time and
# starts to invent words that were never spoken. Replace it with your own
# commands, in your own language.
PROMPT = os.environ.get(
    "WHISPER_PROMPT",
    "Sprachbefehle an einen Sprachassistenten im Haus. "
    "Mach das Licht im Wohnzimmer an. Stell einen Timer auf zehn Minuten. "
    "Wie warm ist es im Bad. Wie spaet ist es.",
)

# Text to speech. Adjust the path to your username if it is not "deck".
VOICE_PATH = os.path.expanduser(
    os.environ.get("PIPER_VOICE", "~/voice/de_DE-thorsten-high.onnx"))
LENGTH_SCALE = float(os.environ.get("PIPER_LENGTH_SCALE", "1.10"))

print("loading whisper %s + piper ..." % WMODEL, flush=True)
whisper = WhisperModel(
    WMODEL, device="cpu", compute_type="int8", cpu_threads=CPU_THREADS)
piper = PiperVoice.load(VOICE_PATH)

# GOTCHA 2: piper.synthesize_wav ignores the length_scale that sits in the
# .onnx.json sidecar of the voice. Editing that file changes nothing. The
# value only takes effect when an explicit SynthesisConfig object is passed
# into every synthesize_wav call. 1.10 is about ten percent slower than the
# default and noticeably easier to understand from across a room.
SYN = SynthesisConfig(length_scale=LENGTH_SCALE)

print("ready on http://%s:%d" % (HOST, PORT), flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        # One line per request would drown the journal. Errors are printed
        # explicitly below instead.
        pass

    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)

        if u.path == "/health":
            self._send(b"ok", "text/plain; charset=utf-8")
            return

        if u.path == "/tts":
            text = q.get("text", [""])[0]
            buf = io.BytesIO()
            try:
                with wave.open(buf, "wb") as wf:
                    piper.synthesize_wav(text, wf, syn_config=SYN)
            except Exception as exc:
                print("synthesis failed: %s" % exc, flush=True)
                self._send(b"", "audio/wav")
                return
            self._send(buf.getvalue(), "audio/wav")
            return

        # Anything else is a transcription request.
        path = q.get("path", [""])[0]
        text = ""
        try:
            segments, _ = whisper.transcribe(
                path,
                language=LANG,
                # GOTCHA 1: this MUST stay False here. The recorder already
                # gates the audio with Silero VAD, so what arrives is speech
                # by construction. Whisper's own VAD then runs a second, much
                # blunter pass over the same clip and drops anything short or
                # quiet, handing back an empty transcript with no error at
                # all. Symptom: the wake word triggers, the beep plays, the
                # recording is clearly there in the WAV, and STT returns
                # nothing. vad_filter=False fixes exactly that.
                vad_filter=False,
                # Greedy decoding. Beam search buys very little on single
                # short commands and costs a large share of the runtime.
                beam_size=1,
                initial_prompt=PROMPT,
                # Each utterance is independent. Carrying the previous text
                # over makes whisper repeat the last answer when it is unsure.
                condition_on_previous_text=False,
            )
            text = " ".join(s.text.strip() for s in segments).strip()
        except Exception as exc:
            print("transcribe failed: %s" % exc, flush=True)

        self._send(text.encode("utf-8"), "text/plain; charset=utf-8")


HTTPServer((HOST, PORT), Handler).serve_forever()
