#!/bin/bash
# Drive the Steam Deck fan on a temperature curve via steamdeck_hwmon fan1_target.
# Near-silent when cool, full at 75C. See power/README.md for why and for the traps.
# Installed to /usr/local/bin by install.sh and run as steamdeck-fancurve.service.

find_hw() {
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = steamdeck_hwmon ] && { echo "$h"; return; }
  done
}

H=$(find_hw)
[ -z "$H" ] && { modprobe steamdeck_hwmon 2>/dev/null; sleep 2; H=$(find_hw); }
[ -z "$H" ] && exit 1

# Highest of CPU (k10temp) and GPU (amdgpu) edge temperature, in whole degrees C.
maxtemp() {
  local m=0 v n x
  for x in /sys/class/hwmon/hwmon*; do
    n=$(cat "$x/name" 2>/dev/null)
    case "$n" in
      k10temp|amdgpu) v=$(( $(cat "$x/temp1_input")/1000 )); [ "$v" -gt "$m" ] && m=$v ;;
    esac
  done
  echo "$m"
}

# On stop or crash, hand the fan back to the EC (loud, but never uncooled).
trap 'echo 0 > "$H/fan1_target" 2>/dev/null; exit 0' TERM INT

# 2000 RPM up to 50C, then linear (100 RPM per degree) to 4500 at 75C. The divisor is the width of the
# ramp (75 - 50): moving the cap without it makes the target jump at the cap.
while true; do
  t=$(maxtemp)
  if   [ "$t" -le 50 ]; then tgt=2000
  elif [ "$t" -ge 75 ]; then tgt=4500
  else tgt=$(( 2000 + (t - 50) * 2500 / 25 )); fi
  echo "$tgt" > "$H/fan1_target" 2>/dev/null || exit 1
  sleep 5
done
