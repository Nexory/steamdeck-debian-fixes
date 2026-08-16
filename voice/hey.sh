#!/bin/bash
# Start the hands-free voice front-end (wake word loop). Ctrl+C stops it.
#
# voiced.py is NOT started here. It runs as a user systemd service
# (voiced.service). Starting it a second time from this script only produces
# a port conflict on 9977 and a confusing half broken setup. This script just
# waits until the service answers, then hands over to hey.py.
set -u

# So paplay and pw-play find the session mixer when this is launched from an
# autostart entry rather than from an interactive login shell.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Adjust to your username if it is not "deck".
VOICE_DIR="${VOICE_DIR:-$HOME/voice}"
VOICED_URL="${VOICED_URL:-http://127.0.0.1:9977}"

if pgrep -f "python .*hey\.py" >/dev/null 2>&1; then
  echo "hey.py is already running, not starting a second one."
  exit 0
fi

cd "$VOICE_DIR" || { echo "no such directory: $VOICE_DIR"; exit 1; }

# shellcheck source=/dev/null
source venv/bin/activate

# Optional local configuration, see voice.env.example. Keep real tokens in
# this file and keep it out of version control.
if [ -f voice.env ]; then
  set -a
  # shellcheck source=/dev/null
  . ./voice.env
  set +a
fi

echo "waiting for the voiced service on ${VOICED_URL} ..."
ready=0
for _ in $(seq 1 180); do
  if curl -fsS -o /dev/null "${VOICED_URL}/health"; then
    ready=1
    break
  fi
  sleep 1
done

if [ "$ready" -ne 1 ]; then
  echo "voiced did not come up. Check: systemctl --user status voiced"
  exit 1
fi

exec python hey.py
