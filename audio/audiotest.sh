#!/usr/bin/env bash
#
# audiotest.sh - check the Steam Deck speakers and the internal microphone on a generic
#                Linux distribution, straight through ALSA (no desktop, no GUI needed).
#
# What it does:
#   0. show which sound cards ALSA sees (playback and capture)
#   1. speaker test: play a WAV file on the playback device, with a fallback device
#      if the first one stays silent or errors out
#   2. microphone test: record a few seconds from the capture device and play the
#      recording back, so you hear whether the mic picked anything up
#   3. print the PipeWire level checks to run next, if the ALSA level worked
#
# Device defaults follow the usual Steam Deck layout:
#   plughw:1,0 = capture  (internal digital microphone)
#   plughw:1,1 = playback (CS35L41 speaker amplifiers)
# The card index is NOT guaranteed to be 1. Check with "aplay -l" and "arecord -l" and
# override on the command line, for example:
#
#   MIC_DEV=plughw:2,0 SPK_DEV=plughw:2,1 bash audiotest.sh
#
# Note on plughw: this bypasses the sound server and talks to the hardware directly. If a
# device is reported as busy, PipeWire is holding it. See the troubleshooting section in
# README.md.
#
# Author: Nexory

set -uo pipefail

MIC_DEV="${MIC_DEV:-plughw:1,0}"
SPK_DEV="${SPK_DEV:-plughw:1,1}"
SPK_FALLBACK="${SPK_FALLBACK:-plughw:1,0}"
TEST_WAV="${TEST_WAV:-/usr/share/sounds/alsa/Front_Center.wav}"
REC_WAV="${REC_WAV:-/tmp/mic_test.wav}"
REC_SECONDS="${REC_SECONDS:-3}"

for tool in aplay arecord; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "'$tool' not found. Install it first:  sudo apt-get install alsa-utils"
        exit 1
    }
done

play_wav() {
    # play_wav <device> <file> -> prints the last lines of aplay output, returns aplay status
    local dev="$1" file="$2" out rc
    out="$(aplay -D "$dev" "$file" 2>&1)"
    rc=$?
    [ -n "$out" ] && printf '%s\n' "$out" | tail -2
    return $rc
}

echo "== 0) Sound cards seen by ALSA =="
echo "-- playback --"
aplay -l 2>&1 | grep -E '^card|no soundcards' || true
echo "-- capture --"
arecord -l 2>&1 | grep -E '^card|no soundcards' || true

echo
echo "== 1) SPEAKER TEST (SPK_DEV=$SPK_DEV) =="
if [ -r "$TEST_WAV" ]; then
    echo "Playing $TEST_WAV - if you hear it, the speakers work."
    if ! play_wav "$SPK_DEV" "$TEST_WAV"; then
        echo "-> $SPK_DEV silent or failed, trying $SPK_FALLBACK ..."
        play_wav "$SPK_FALLBACK" "$TEST_WAV" || echo "-> fallback failed as well."
    fi
else
    echo "$TEST_WAV not found, falling back to a generated sine tone."
    echo "If you hear a tone, the speakers work."
    speaker-test -D "$SPK_DEV" -c 2 -t sine -f 440 -l 1 2>&1 | tail -3 \
        || echo "-> speaker-test failed on $SPK_DEV"
fi

echo
echo "== 2) MICROPHONE TEST (MIC_DEV=$MIC_DEV) =="
echo "Speak now for $REC_SECONDS seconds ..."
arecord -D "$MIC_DEV" -f S16_LE -r 16000 -c 1 -d "$REC_SECONDS" "$REC_WAV" 2>&1 | tail -2

if [ -s "$REC_WAV" ]; then
    echo "Playing your recording back:"
    play_wav "$SPK_DEV" "$REC_WAV" >/dev/null 2>&1 \
        || aplay "$REC_WAV" >/dev/null 2>&1 \
        || echo "-> could not play the recording back."
    echo "Recorded file: $REC_WAV"
    echo "Level check (a flat 0.0 peak means the mic captured silence):"
    if command -v sox >/dev/null 2>&1; then
        sox "$REC_WAV" -n stat 2>&1 | grep -iE 'maximum amplitude|rms' || true
    else
        echo "  (install 'sox' for a numeric level readout: sudo apt-get install sox)"
    fi
else
    echo "-> no recording was produced. Check 'arecord -l' and the MIC_DEV setting."
fi

echo
echo "== 3) Next level up: PipeWire =="
echo "ALSA is only half the story. If the two tests above worked but applications stay"
echo "silent, check the sound server as your normal desktop user:"
echo "    wpctl status"
echo "    pw-play $TEST_WAV"
echo "    pw-record /tmp/pw_mic_test.wav   # Ctrl+C to stop"
echo "    systemctl --user restart pipewire pipewire-pulse wireplumber"
