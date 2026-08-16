#!/usr/bin/env bash
#
# speaker-firmware.sh - install the Cirrus Logic CS35L41 amplifier firmware that the
#                       Steam Deck speakers need on a generic Linux distribution.
#
# Why this exists:
#   The Deck does not drive its speakers from a plain codec output. The two speakers hang
#   behind Cirrus Logic CS35L41 "smart amps" with an on-chip DSP. That DSP runs a firmware
#   blob (speaker protection / tuning) which the kernel driver loads from
#   /lib/firmware/cirrus/ at probe time. SteamOS ships those blobs, a stock Debian install
#   does not, so the card enumerates, the mixer looks fine, and playback stays completely
#   silent.
#
# What this script does (all of it):
#   1. refresh the package lists
#   2. install the Debian firmware package "firmware-cirrus"
#   3. list the cs35l41 files that are present in /lib/firmware/cirrus/ afterwards
#   4. tell you to reboot, because the amp only picks the firmware up on driver probe
#
# It does NOT touch ALSA UCM, PipeWire or any mixer setting. See README.md for the full
# procedure around this step.
#
# Usage:  sudo bash speaker-firmware.sh
#
# Author: Nexory

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this with root privileges:  sudo bash speaker-firmware.sh"
    exit 1
fi

echo "== 1) Refreshing package lists =="
apt-get update

echo
echo "== 2) Installing firmware-cirrus =="
if ! apt-get install -y firmware-cirrus; then
    echo
    echo "firmware-cirrus could not be installed."
    echo "On Debian it lives in the 'non-free-firmware' component. Make sure your apt"
    echo "sources contain it, for example in /etc/apt/sources.list:"
    echo
    echo "    deb http://deb.debian.org/debian trixie main contrib non-free-firmware"
    echo
    echo "then run 'sudo apt-get update' and start this script again."
    exit 1
fi

echo
echo "== 3) CS35L41 firmware files present now =="
# Note: do not pipe straight into head here. The exit status of a pipeline is the status of
# its LAST command, so "ls | grep | head || echo ..." would report success even when grep
# found nothing at all. Capture first, then decide.
found="$(ls -1 /lib/firmware/cirrus/ 2>/dev/null | grep -i cs35l41 || true)"

if [ -n "$found" ]; then
    printf '%s\n' "$found" | head -20
    total="$(printf '%s\n' "$found" | wc -l)"
    echo "($total cs35l41 file(s) in /lib/firmware/cirrus/)"
else
    echo "(no cs35l41 files found - the distribution package alone is not enough here,"
    echo " see the troubleshooting section in README.md)"
fi

echo
echo "The firmware is on disk. A REBOOT is required so the amplifier driver loads it:"
echo "    sudo reboot"
echo
echo "After the reboot, check the kernel log and run the audio test:"
echo "    sudo dmesg | grep -i cs35l41"
echo "    bash audiotest.sh"
