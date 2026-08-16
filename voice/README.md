# Local hands-free voice front-end

Optional add-on for the Deck server. A wake word listener, a recorder, speech
to text, a language backend and text to speech, all running on the CPU of the
machine itself. No audio and no transcript leaves the box, except whatever
your chosen language backend sends onward.

This is a **voice front-end and nothing else**. It moves audio and text
around. It is not tied to any particular task or domain: what the assistant
can actually do is decided entirely by the backend you point `LLM_CMD` at.

Everything here is optional. Nothing else on the server depends on it.

---

## The two gotchas, up front

These two cost the most debugging time by a wide margin, and neither of them
produces an error message. Read them before you start.

### 1. `vad_filter=False` in `whisper.transcribe()`

**Symptom:** the wake word triggers, the beep plays, the recording is clearly
present in the WAV file, and STT returns an empty string. No exception, no
warning, no log line. Just nothing.

**Cause:** there are two voice activity detectors in the chain. The recorder
already gates the audio with Silero VAD, so by the time a clip reaches
whisper it is speech by construction. Whisper's own built-in VAD then runs a
second, much blunter pass over the same clip and discards anything it
considers too short or too quiet, which describes most single-sentence room
recordings. It returns zero segments and that is indistinguishable from
"nobody said anything".

**Fix:** pass `vad_filter=False`. Silero is already doing that job upstream,
and doing it better, because it is deciding in real time with the microphone
level in context.

```python
segments, _ = whisper.transcribe(path, language="de", vad_filter=False, ...)
```

### 2. Piper ignores `length_scale` from the `.onnx.json`

**Symptom:** you edit `length_scale` in the voice's `.onnx.json` sidecar to
slow the speech down, and absolutely nothing changes.

**Cause:** `piper.synthesize_wav()` does not read the speed setting back out
of that sidecar. The value is only honoured when it arrives as an explicit
`SynthesisConfig` object on the call itself.

**Fix:** build the config once and pass it on every call.

```python
from piper.config import SynthesisConfig
SYN = SynthesisConfig(length_scale=1.10)   # ~10% slower, clearly easier to follow
piper.synthesize_wav(text, wav_file, syn_config=SYN)
```

---

## Architecture

```
microphone
    |
    v
arecord  (raw S16_LE, 16 kHz, mono, one long-lived process)
    |
    +--> openWakeWord "hey_jarvis"      80 ms frames, score >= threshold
    |          |
    |          v
    +--> Silero VAD                     32 ms frames, record until silence
               |
               v
        /tmp/voice-cmd.wav
               |
               v
    voiced.py  GET /?path=...           faster-whisper, CTranslate2, int8, 8 threads
               |
               v
        transcript (text)
               |
               v
    LLM_CMD                             any CLI: prompt on stdin, reply on stdout
               |
               v
        reply (text)
               |
               v
    voiced.py  GET /tts?text=...        Piper, de_DE-thorsten-high
               |
               v
    paplay / pw-play / aplay  -->  speaker
```

Two processes, split on purpose:

| Process | Role | Lifecycle |
|---|---|---|
| `voiced.py` | STT and TTS over HTTP on `127.0.0.1:9977` | user systemd service, `Restart=always` |
| `hey.py` | wake word loop, recording, orchestration | autostarted via `hey.sh`, waits for the port |

The models live in `voiced.py` and stay resident. That is the entire reason
it is a service rather than a function call: loading whisper per utterance
would add seconds to every single answer. `hey.py` holds no models except the
two small ones for wake word and VAD, so it can be restarted freely while you
are tuning thresholds.

### Wake word

openWakeWord with the pretrained `hey_jarvis_v0.1` model, running on 80 ms
frames. `WAKE_THRESH` trades false triggers against missed ones; 0.5 is a
reasonable start. After each exchange `oww.reset()` is called, because the
model keeps a rolling score buffer and will otherwise re-trigger on its own
tail.

### Capture

Once the wake word fires, Silero VAD takes over on 32 ms frames. It waits up
to `ONSET_MS` for speech to begin, then records until `END_MS` of continuous
silence. The Silero graph is stateful, so it is reset before every listening
window; skipping that reset makes it fire immediately on the leftover state
from the previous utterance.

Two details that matter in a real room:

- **Drain the buffer** after playback. `arecord` keeps filling its pipe while
  the assistant is speaking, so without a drain the next thing transcribed is
  the assistant's own answer.
- **Normalize quiet clips.** Distant speech on a small microphone lands very
  low, and whisper on a low level clip returns short or empty text. The gain
  is capped so that room noise in a genuinely silent clip is not amplified
  into something that sounds like speech.

After an answer, a `FOLLOWUP_MS` window opens in which you can keep talking
without repeating the wake word.

### Speech to text

faster-whisper (CTranslate2) on the CPU, `compute_type="int8"`,
`cpu_threads=8`.

Model choice is the single biggest lever on how usable this feels:

| Model | Latency per utterance | Notes |
|---|---|---|
| `small` | fast | slurred and unreliable for German |
| `medium` | about 6s | decent German, slow enough to be annoying |
| `cstr/whisper-large-v3-turbo-german-int8_float32` | about 1-2s | German turbo build, already int8, drop-in replacement |

The turbo German build is set through the systemd drop-in, see below.

Three settings besides the model:

- **Force the language** with `language="de"`. Auto detection on short, noisy
  room audio flips language between utterances.
- **Pass a small `initial_prompt`.** Whisper biases toward words it has just
  seen, so listing the handful of phrases you actually say cuts down on
  look-alike misreads of short commands. Keep it short: a long prompt costs
  time and starts inventing words nobody said.
- **`condition_on_previous_text=False`.** Each utterance is independent.
  Carrying the previous text over makes whisper repeat the last answer
  whenever it is unsure.

### Language backend

Deliberately generic. `LLM_CMD` is any command line that reads a prompt on
stdin and writes a plain text reply to stdout. A locally hosted model runner
and an API backed CLI both fit that shape, and nothing in `hey.py` knows or
cares which one is behind it.

```sh
LLM_CMD="my-llm-cli --quiet"
```

The persona in `~/voice/assistant.md` is prepended to every prompt, and the
last few exchanges are carried along so follow up questions make sense. Both
are plain text; see `assistant.example.md` for a starting point.

The transcript is never interpolated into the command line, it is written to
the child process on stdin, so spoken words cannot become shell words.
`LLM_CMD` itself is split with `shlex`; set `LLM_SHELL=1` only if you need a
real shell for pipes or redirection.

Leave `LLM_CMD` empty to test the whole audio path without any backend.

If your backend can execute commands, restrict what it may do **at the
backend**. This front-end has no permission model and is not the right place
for one.

### Text to speech

Piper with `de_DE-thorsten-high`, plus the explicit `SynthesisConfig` from
gotcha 2. Playback tries `paplay`, then `pw-play`, then `aplay`, in that
order, because the PipeWire and PulseAudio clients respect the session volume
and plain ALSA does not.

---

## Install

Requires a working microphone and speaker. Check them with `arecord -l` and
`aplay -l` first.

```sh
git clone https://github.com/Nexory/steamdeck-debian-fixes
cd steamdeck-debian-fixes/voice
sudo bash voice-setup.sh
```

That installs the system packages, creates `~/voice/venv`, installs
faster-whisper, piper-tts, openwakeword, onnxruntime and numpy, downloads the
Piper voice and the openWakeWord models, preloads the whisper model, copies
the programs and the example config into `~/voice/`, and installs the user
systemd unit. It also runs `loginctl enable-linger`, without which a user
service does not start until somebody logs in.

Then, **as your own user and not with sudo**:

```sh
systemctl --user daemon-reload
systemctl --user enable --now voiced
systemctl --user status voiced      # wait for "ready on http://127.0.0.1:9977"
```

First start is slow: the model is loaded from disk into RAM. Watch the log
until the ready line appears.

```sh
~/voice/hey.sh
```

Say the wake word, wait for the beep, then speak.

All paths here use `/home/deck`. **Adjust them to your username** if it is not
`deck`, in `voiced.service` and in `~/voice/voice.env`. The setup script does
this substitution for the unit file automatically.

### Configuration

Edit `~/voice/voice.env`, which `hey.sh` sources before starting `hey.py`.
See `voice.env.example` for every knob with a comment. Keep real tokens in
`voice.env` only, and keep that file out of version control.

Note that `voice.env` reaches `hey.py` only. `voiced.py` is started by systemd
and never sees it; its settings come from the drop-in below.

---

## systemd

`voiced.py` runs as a **user** service, not a system service, because it needs
the user's audio session and home directory.

`~/.config/systemd/user/voiced.service`:

```ini
[Unit]
Description=Voice STT/TTS

[Service]
ExecStart=/home/deck/voice/venv/bin/python /home/deck/voice/voiced.py
WorkingDirectory=/home/deck/voice
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
```

The model is selected by a drop-in rather than by editing the unit, so the
unit stays generic and an update does not silently reset your model choice.

`~/.config/systemd/user/voiced.service.d/model.conf`:

```ini
[Service]
Environment=WHISPER_MODEL=cstr/whisper-large-v3-turbo-german-int8_float32
```

After changing either file:

```sh
systemctl --user daemon-reload
systemctl --user restart voiced
journalctl --user -u voiced -f
```

### Do not start `voiced` twice

`hey.sh` deliberately does **not** launch `voiced.py`. The service already
owns port 9977, and a second instance dies on bind while the first keeps
serving, which produces a very confusing half broken setup. `hey.sh` polls
`/health` and waits for up to three minutes for the service to come up, then
hands over to `hey.py`.

`hey.sh` also refuses to start if a `hey.py` is already running, for the same
class of reason: two wake word loops fighting over one microphone.

### Autostart of the wake word loop

`hey.sh` needs the graphical or audio session, so autostart it as the user,
for example with a desktop autostart entry, or with a second user service that
runs after `voiced`. It exports `XDG_RUNTIME_DIR` itself so that `paplay` and
`pw-play` find the session mixer when launched outside an interactive login
shell.

---

## Files

| File | Purpose |
|---|---|
| `voiced.py` | STT and TTS HTTP service on `127.0.0.1:9977` |
| `hey.py` | wake word loop, VAD capture, orchestration |
| `hey.sh` | launcher, waits for the service, prevents double starts |
| `voice-setup.sh` | one-shot installer, run with sudo |
| `voiced.service` | user systemd unit |
| `voiced.service.d/model.conf` | drop-in that selects the whisper model |
| `assistant.example.md` | generic example persona, copy to `~/voice/assistant.md` |
| `voice.env.example` | every setting with a comment, copy to `~/voice/voice.env` |

---

## Troubleshooting

**"STT returned nothing", repeatedly.** Gotcha 1. Confirm `vad_filter=False`
is actually in the running copy at `~/voice/voiced.py`, not just in the repo.

**Speech is too fast or slurred.** Gotcha 2. Raise `length_scale` in the
`SynthesisConfig` in `voiced.py`, not in the `.onnx.json`.

**`hey.sh` times out waiting for the port.** The service is not up.
`systemctl --user status voiced` and `journalctl --user -u voiced -n 50`. A
missing model download shows up here as a stack trace on start.

**`silero_vad.onnx not found`.** It ships inside the openwakeword package.
Set `SILERO_VAD_PATH` in `voice.env` to its actual location.

**No audio in or out.** `arecord -l` and `aplay -l`, then fix `MIC_DEV` and
`SPK_DEV` in `voice.env`. Record a test clip with
`arecord -D plughw:1,0 -f S16_LE -r 16000 -c 1 -d 3 /tmp/t.wav` and play it
back before blaming anything further up the chain.

**The assistant answers its own answers.** The drain after playback is not
working. Check that playback finishes before recording resumes.

**Wake word triggers constantly.** Raise `WAKE_THRESH`. Fires too rarely,
lower it, and move the microphone away from a noise source.

**Service does not start after a reboot.** `loginctl enable-linger <user>`.

---

Author: Nexory
