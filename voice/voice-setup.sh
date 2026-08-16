#!/bin/bash
# Set up the local voice stack: openWakeWord + Silero VAD (hey.py) and
# faster-whisper + Piper (voiced.py). Everything runs offline on the CPU
# after this script has finished downloading the models.
#
#   sudo bash voice-setup.sh
#
# The script installs system packages as root and then does all Python work
# as the invoking user. Adjust HOME_USER below if it is not "deck".
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo."; exit 1; }

HOME_USER="${SUDO_USER:-deck}"
id "$HOME_USER" >/dev/null 2>&1 || { echo "no such user: $HOME_USER"; exit 1; }
HOME_DIR="$(getent passwd "$HOME_USER" | cut -d: -f6)"
VOICE_DIR="$HOME_DIR/voice"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== system dependencies =="
apt-get update
apt-get install -y python3-full python3-venv python3-pip \
                   ffmpeg alsa-utils curl wget

echo "== python environment as $HOME_USER =="
# "env" rather than "sudo VAR=value": passing variables directly to sudo is
# rejected outright by some sudoers configurations.
sudo -u "$HOME_USER" env \
    HOME="$HOME_DIR" \
    VOICE_DIR="$VOICE_DIR" \
    SRC_DIR="$SRC_DIR" \
    bash <<'EOS'
set -euo pipefail
mkdir -p "$VOICE_DIR"
cd "$VOICE_DIR"

python3 -m venv venv
source venv/bin/activate
pip install --quiet --upgrade pip

# voiced.py needs faster-whisper and piper-tts.
# hey.py needs openwakeword, onnxruntime and numpy.
pip install --quiet faster-whisper piper-tts openwakeword onnxruntime numpy

echo "-- copying the programs into $VOICE_DIR --"
for f in voiced.py hey.py hey.sh; do
  if [ -f "$SRC_DIR/$f" ]; then
    cp "$SRC_DIR/$f" "$VOICE_DIR/$f"
  fi
done
if [ -f "$VOICE_DIR/hey.sh" ]; then
  chmod +x "$VOICE_DIR/hey.sh"
fi

# Never overwrite an existing local configuration or persona.
if [ -f "$SRC_DIR/assistant.example.md" ] && [ ! -f "$VOICE_DIR/assistant.md" ]; then
  cp "$SRC_DIR/assistant.example.md" "$VOICE_DIR/assistant.md"
fi
if [ -f "$SRC_DIR/voice.env.example" ] && [ ! -f "$VOICE_DIR/voice.env" ]; then
  cp "$SRC_DIR/voice.env.example" "$VOICE_DIR/voice.env"
fi

echo "-- piper: german voice de_DE-thorsten-high --"
BASE=https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/thorsten/high
wget -q -O de_DE-thorsten-high.onnx      "$BASE/de_DE-thorsten-high.onnx"
wget -q -O de_DE-thorsten-high.onnx.json "$BASE/de_DE-thorsten-high.onnx.json"

echo "-- openwakeword: pretrained models --"
python - <<'PY'
import openwakeword.utils
openwakeword.utils.download_models()
print("ok")
PY

echo "-- checking that silero_vad.onnx is present --"
python - <<'PY'
import glob, os, openwakeword
hits = glob.glob(os.path.join(os.path.dirname(openwakeword.__file__),
                              "**", "silero_vad.onnx"), recursive=True)
if hits:
    print("found:", hits[0])
else:
    print("NOT FOUND. Set SILERO_VAD_PATH in voice.env to its location.")
PY

echo "-- preloading the whisper model (this downloads a few hundred MB) --"
python - <<'PY'
import os
from faster_whisper import WhisperModel
m = os.environ.get("WHISPER_MODEL",
                   "cstr/whisper-large-v3-turbo-german-int8_float32")
WhisperModel(m, device="cpu", compute_type="int8", cpu_threads=8)
print("ok:", m)
PY

echo "-- installing the user systemd unit --"
mkdir -p "$HOME/.config/systemd/user/voiced.service.d"
if [ -f "$SRC_DIR/voiced.service" ]; then
  sed "s#/home/deck#$HOME#g" "$SRC_DIR/voiced.service" \
    > "$HOME/.config/systemd/user/voiced.service"
fi
if [ -f "$SRC_DIR/voiced.service.d/model.conf" ]; then
  cp "$SRC_DIR/voiced.service.d/model.conf" \
     "$HOME/.config/systemd/user/voiced.service.d/model.conf"
fi
EOS

echo "== letting the user service run without an active login session =="
loginctl enable-linger "$HOME_USER"

cat <<EOF

DONE. Now, as $HOME_USER (not with sudo):

  systemctl --user daemon-reload
  systemctl --user enable --now voiced
  systemctl --user status voiced        # wait for "ready on http://127.0.0.1:9977"

Then start the wake word loop:

  $VOICE_DIR/hey.sh

Set your audio devices in $VOICE_DIR/voice.env if the defaults are wrong.
Find them with:  arecord -l   and   aplay -l
EOF
