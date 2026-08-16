#!/usr/bin/env bash
# touch-capture.sh - snapshot the state of a WORKING touchscreen on a Steam Deck LCD.
#
# Run this right after the touchscreen comes back (see README.md), so there is a
# real known-good baseline to diff against if it ever wedges again. Strictly
# read-only: it reads sysfs, debugfs, procfs and dmesg, and writes files into the
# output directory. It changes no device state.
#
# Usage:
#   sudo ./touch-capture.sh [output-dir]
#
# Default output dir is /home/deck/touch-evidence. Adjust to your username,
# or pass your own directory.

set -u

TOUCH_ACPI_ID="FTS3528:00"
OUT="${1:-/home/deck/touch-evidence}"

if [ "$(id -u)" != 0 ]; then
    echo "Please run as root:  sudo $0 $*" >&2
    exit 1
fi

mkdir -p "$OUT" || exit 1

{
    echo "kernel:  $(uname -r)"
    echo "product: $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    echo "date:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} | tee "$OUT/working-system.txt"

echo
echo "== driver binding =="
ls -l "/sys/bus/i2c/devices/i2c-${TOUCH_ACPI_ID}/driver" 2>/dev/null | sed 's/^/  /' \
    || echo "  no driver bound to i2c-${TOUCH_ACPI_ID}"

echo
echo "== input devices =="
grep -iE "FTS3528|touch" /proc/bus/input/devices 2>/dev/null | sed 's/^/  /'
cp /proc/bus/input/devices "$OUT/working-input-devices.txt" 2>/dev/null || true

EVENT_NODE=""
for d in /sys/class/input/input*; do
    [ -r "$d/name" ] || continue
    case "$(cat "$d/name" 2>/dev/null)" in
        *FTS3528*)
            ev=$(ls "$d" 2>/dev/null | grep -m1 '^event')
            [ -n "$ev" ] && EVENT_NODE="/dev/input/$ev"
            ;;
    esac
done

echo
echo "== dmesg: the successful bring-up sequence =="
dmesg | grep -iE "FTS3528|i2c_hid|designware|hid-multitouch|input:|GpioInt" \
    > "$OUT/working-dmesg.txt"
tail -20 "$OUT/working-dmesg.txt" | sed 's/^/  /'

echo
echo "== GPIO state (touch reset / interrupt pins) =="
if [ -r /sys/kernel/debug/gpio ]; then
    cat /sys/kernel/debug/gpio > "$OUT/working-gpio.txt" 2>/dev/null
    grep -iE "FTS|i2c-FTS3528|pinctrl_amd" "$OUT/working-gpio.txt" 2>/dev/null | sed 's/^/  /'
    echo "  (full GPIO table: $OUT/working-gpio.txt)"
else
    echo "  /sys/kernel/debug/gpio not readable (is debugfs mounted?)"
fi

echo
echo "== interrupt counters =="
grep -iE "FTS3528|i2c_hid|pinctrl_amd|i2c_designware" /proc/interrupts \
    | tee "$OUT/working-irq-touch.txt" | sed 's/^/  /'
cp /proc/interrupts "$OUT/working-interrupts.txt" 2>/dev/null || true

echo
echo "== ACPI status =="
echo "  ${TOUCH_ACPI_ID} status = $(cat "/sys/bus/acpi/devices/${TOUCH_ACPI_ID}/status" 2>/dev/null)"

if [ -n "${SUDO_USER:-}" ]; then
    chown -R "${SUDO_USER}:" "$OUT" 2>/dev/null || true
fi

echo
if [ -n "$EVENT_NODE" ]; then
    echo "RESULT: touch input node present -> $EVENT_NODE"
    echo "Confirm live events with:  sudo evtest $EVENT_NODE"
    echo "Baseline saved in $OUT/working-*"
else
    echo "RESULT: no FTS3528 input node. The touchscreen is NOT working right now,"
    echo "so this snapshot is not a usable baseline. See README.md and run"
    echo "touch-diag.sh instead."
    exit 1
fi
