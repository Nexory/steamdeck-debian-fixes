#!/bin/bash
#
# setup-adaptive-backlight.sh - enable adaptive brightness once the ambient light
# sensor module from build-ltrf216a.sh is loaded.
#
# This uses the GNOME-native path: iio-sensor-proxy exposes the IIO light sensor,
# gnome-settings-daemon consumes it. There is no custom polling daemon here.
# An earlier revision of this project shipped one; it was retired once the kernel
# module loaded, because GNOME already does the job.
#
# Usage:
#   sudo bash setup-adaptive-backlight.sh
#
# Idempotent. Aborts if no ambient light sensor reports illuminance.
#
# Author: Nexory
#
set -e

[ "$(id -u)" = 0 ] || { echo "Please run with sudo:  sudo bash setup-adaptive-backlight.sh"; exit 1; }

# The desktop user whose GNOME session should get adaptive brightness.
# Adjust to your username.
DESKTOP_USER="${DESKTOP_USER:-deck}"
BACKLIGHT=/sys/class/backlight/amdgpu_bl0

echo "== 1. Load the ambient light modules and make it permanent =="
# opt3001 is referenced by ACPI but not physically present; the failure is expected.
modprobe ltrf216a 2>/dev/null || echo "  (ltrf216a not loaded here - probably already built in)"
grep -q '^ltrf216a' /etc/modules-load.d/deck-als.conf 2>/dev/null \
  || echo ltrf216a >> /etc/modules-load.d/deck-als.conf
sleep 1

echo "== 2. Look for the sensor =="
ALS=""
for d in /sys/bus/iio/devices/iio:device*; do
  if [ -f "$d/in_illuminance_input" ] || [ -f "$d/in_illuminance_raw" ]; then
    ALS="$d"
    echo "  found: $d  ($(cat "$d/name" 2>/dev/null))"
    val=$(cat "$d/in_illuminance_input" 2>/dev/null || cat "$d/in_illuminance_raw" 2>/dev/null)
    echo "  current reading: $val"
    break
  fi
done
if [ -z "$ALS" ]; then
  echo "  ERROR: no IIO light sensor reporting illuminance. Nothing installed."
  echo "  Run build-ltrf216a.sh first."
  exit 1
fi

echo "== 3. iio-sensor-proxy =="
if ! systemctl is-active --quiet iio-sensor-proxy; then
  apt-get install -y iio-sensor-proxy
  systemctl enable --now iio-sensor-proxy
fi
echo "  iio-sensor-proxy: $(systemctl is-active iio-sensor-proxy)"
command -v monitor-sensor >/dev/null && echo "  verify live with: monitor-sensor --light"

echo "== 4. udev: make the backlight writable by the video group =="
# Only needed if you also want to set brightness by hand from a non-root process.
cat > /etc/udev/rules.d/90-deck-backlight.rules <<'EOF'
SUBSYSTEM=="backlight", ACTION=="add", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="/bin/chmod 664 /sys/class/backlight/%k/brightness"
EOF
udevadm control --reload
chgrp video "$BACKLIGHT/brightness" 2>/dev/null || true
chmod 664 "$BACKLIGHT/brightness" 2>/dev/null || true

echo "== 5. Turn on GNOME adaptive brightness for $DESKTOP_USER =="
UID_N=$(id -u "$DESKTOP_USER")
sudo -u "$DESKTOP_USER" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
  gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled true
echo "  ambient-enabled: $(sudo -u "$DESKTOP_USER" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
  gsettings get org.gnome.settings-daemon.plugins.power ambient-enabled)"

echo
echo "== 6. Status =="
echo "  actual_brightness: $(cat "$BACKLIGHT/actual_brightness")/$(cat "$BACKLIGHT/max_brightness")"
echo
echo "Done. Cover the sensor and watch the panel dim."
echo "Live sensor readings:  monitor-sensor --light"
