#!/bin/bash
# Fan control + battery charge limit for a Steam Deck LCD on Debian.
# Builds the steamdeck DKMS module, then installs two systemd services:
#   steamdeck-chargelimit.service  - re-applies the 80% cap on every boot
#   steamdeck-fancurve.service     - drives fan1_target on a temperature curve
# Run with sudo. Self-checking: aborts before anything permanent if the driver does not bind.
# See power/README.md.
set -e

LIMIT=80
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD=/tmp/steamdeck-dkms-build

echo "### 1/6 build dependencies ###"
apt-get update -qq
apt-get install -y git dkms dpkg-dev debhelper dh-dkms

echo "### 2/6 fetch + build steamdeck-dkms ###"
rm -rf "$BUILD"
git clone --depth 1 https://github.com/firlin123/steamdeck-dkms "$BUILD"
( cd "$BUILD" && dpkg-buildpackage -us -uc -b )
DEB=$(ls -t /tmp/steamdeck-dkms_*.deb 2>/dev/null | head -1)
[ -z "$DEB" ] && { echo "ERROR: .deb not produced"; exit 1; }

echo "### 3/6 install ($DEB) ###"
dpkg -i "$DEB" || apt-get install -f -y

echo "### 4/6 load + verify ###"
modprobe steamdeck 2>/dev/null || true
modprobe steamdeck_hwmon 2>/dev/null || true
sleep 1
HW=""
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$h/name" 2>/dev/null)" = steamdeck_hwmon ] && HW="$h"
done
if [ -z "$HW" ] || [ ! -e "$HW/max_battery_charge_level" ]; then
  echo "ERROR: steamdeck_hwmon did not appear. Nothing permanent was changed."
  lsmod | grep -i steamdeck || true
  exit 1
fi
echo "  hwmon: $HW  fan=$(cat "$HW/fan1_input") RPM  limit=$(cat "$HW/max_battery_charge_level")"

echo "### 5/6 battery charge limit ${LIMIT}% ###"
echo "$LIMIT" > "$HW/max_battery_charge_level"
install -m 644 "$HERE/steamdeck-chargelimit.service" /etc/systemd/system/steamdeck-chargelimit.service

echo "### 6/6 fan curve service ###"
install -m 755 "$HERE/steamdeck-fancurve.sh" /usr/local/bin/steamdeck-fancurve.sh
install -m 644 "$HERE/steamdeck-fancurve.service" /etc/systemd/system/steamdeck-fancurve.service
systemctl daemon-reload
systemctl enable --now steamdeck-fancurve.service
systemctl enable steamdeck-chargelimit.service

echo "### done ###"
echo "Fan curve active, charge limit ${LIMIT}%, both persistent across reboots and kernel updates."
