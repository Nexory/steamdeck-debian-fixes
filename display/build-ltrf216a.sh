#!/bin/bash
#
# build-ltrf216a.sh - build the Liteon LTR-F216A ambient light sensor driver
# out-of-tree against the running kernel, install it, load it, and make the load
# permanent.
#
# Background:
#   The Steam Deck LCD carries an ltrf216a ambient light sensor. Debian ships its
#   kernel without CONFIG_LTRF216A, so no driver binds to it. The other sensor the
#   ACPI tables reference, opt3001, is not physically present on this board and its
#   probe fails with -121 (ENOTCONN). That error is harmless and expected.
#   Result out of the box: no /sys/bus/iio light sensor at all.
#
#   Once this module is loaded, iio-sensor-proxy picks the sensor up and GNOME does
#   adaptive brightness natively. No custom brightness daemon is needed.
#
# Usage:
#   sudo bash build-ltrf216a.sh
#
# Note: this builds against the currently running kernel. After a kernel upgrade
# the module has to be rebuilt (see the DKMS note in README.md).
#
# Author: Nexory
#
set -e

[ "$(id -u)" = 0 ] || { echo "Please run with sudo:  sudo bash build-ltrf216a.sh"; exit 1; }

KV=$(uname -r)
KVER=$(echo "$KV" | grep -oP '^[0-9]+\.[0-9]+\.[0-9]+')
BUILD_DIR=/root/ltrf216a-build
MODULES_LOAD_CONF=/etc/modules-load.d/deck-als.conf

echo "== Kernel $KV (upstream v$KVER) =="

echo "== 1. Kernel headers =="
if [ ! -d "/lib/modules/$KV/build" ]; then
  apt-get update -qq || true
  apt-get install -y "linux-headers-$KV" 2>/dev/null \
    || apt-get install -y -t trixie-backports "linux-headers-$KV"
fi
[ -d "/lib/modules/$KV/build" ] || {
  echo "ERROR: no matching kernel headers found. Without them no module can be built."
  exit 1
}
echo "  build dir: $(readlink -f "/lib/modules/$KV/build")"

echo "== 2. Fetch ltrf216a.c (v$KVER) =="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/iio/light/ltrf216a.c?h=v$KVER"
if ! curl -fsSL "$URL" -o ltrf216a.c; then
  echo "  v$KVER not directly fetchable, falling back to mainline HEAD..."
  curl -fsSL "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/iio/light/ltrf216a.c" \
    -o ltrf216a.c
fi
echo "  $(wc -l < ltrf216a.c) lines fetched"
echo "obj-m := ltrf216a.o" > Makefile

echo "== 3. Build the module =="
make -C "/lib/modules/$KV/build" M="$BUILD_DIR" modules
[ -f ltrf216a.ko ] || { echo "ERROR: ltrf216a.ko was not built"; exit 1; }

echo "== 4. Install, load, and autoload on boot =="
DEST="/lib/modules/$KV/kernel/drivers/iio/light"
mkdir -p "$DEST"
cp ltrf216a.ko "$DEST/"
depmod -a
modprobe ltrf216a 2>/dev/null || insmod ./ltrf216a.ko
grep -q '^ltrf216a' "$MODULES_LOAD_CONF" 2>/dev/null || echo ltrf216a >> "$MODULES_LOAD_CONF"
echo "  autoload entry: $MODULES_LOAD_CONF"

echo "== 5. Does the sensor report light now? =="
sleep 1
LUX=""
for d in /sys/bus/iio/devices/iio:device*; do
  [ -d "$d" ] || continue
  NAME=$(cat "$d/name" 2>/dev/null || echo "?")
  if [ -f "$d/in_illuminance_input" ]; then
    LUX=$(cat "$d/in_illuminance_input")
    echo "  $NAME: ${LUX} lux"
  elif [ -f "$d/in_illuminance_raw" ]; then
    LUX=$(cat "$d/in_illuminance_raw")
    echo "  $NAME: raw=${LUX}"
  fi
done

echo
if [ -n "$LUX" ]; then
  echo "  >>> Sensor is reporting values."
  echo "  Next, enable the GNOME-native adaptive brightness path:"
  echo "      sudo bash setup-adaptive-backlight.sh"
  echo "  or do it by hand as the desktop user:"
  echo "      systemctl is-active iio-sensor-proxy"
  echo "      gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled true"
else
  echo "  >>> Module loaded, but no lux value yet. Recent kernel messages:"
  dmesg | grep -iE 'ltrf216a|illuminance' | tail -6 | sed 's/^/    /'
fi
