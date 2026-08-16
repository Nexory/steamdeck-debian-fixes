#!/usr/bin/env bash
# touch-diag.sh - collect evidence about a dead touchscreen on a Steam Deck LCD.
#
# Tells apart the two failure directions:
#   * host controller side  -> dmesg says "controller timed out", IRQ counter frozen
#   * touch chip side       -> dmesg says abort / arbitration lost / -ENXIO
#
# Read-only by default. The optional --rebind section briefly detaches and
# reattaches the I2C controller driver; that is undone in the same run and does
# not survive a reboot, but it does touch a live bus, so it is opt-in.
#
# Usage:
#   sudo ./touch-diag.sh [--rebind] [output-dir]
#
# Default output dir is /home/deck/touch-evidence. Adjust to your username,
# or pass your own directory.

set -u

I2C_ACPI_ID="AMDI0010:01"        # AMD Designware I2C controller the panel hangs off
TOUCH_ACPI_ID="FTS3528:00"       # touch controller as named by ACPI
OUT="/home/deck/touch-evidence"
DO_REBIND=0

while [ $# -gt 0 ]; do
    case "$1" in
        --rebind) DO_REBIND=1 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) OUT="$1" ;;
    esac
    shift
done

if [ "$(id -u)" != 0 ]; then
    echo "Please run as root:  sudo $0 $*" >&2
    exit 1
fi

mkdir -p "$OUT" || exit 1

{
    echo "kernel:  $(uname -r)"
    echo "product: $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    echo "date:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} | tee "$OUT/diag-system.txt"

echo
echo "== A: kernel messages - timeout vs. bus abort =="
dmesg | grep -iE 'i2c|designware|FTS3528|hid|nobody cared|tx_abrt|abort|arbitration|timed out|deferred' \
    > "$OUT/diag-dmesg.txt"
tail -20 "$OUT/diag-dmesg.txt" | sed 's/^/  /'
echo "  (full output: $OUT/diag-dmesg.txt)"

echo
echo "== B: does the controller interrupt count during a forced transfer? =="
if [ "$DO_REBIND" != 1 ]; then
    echo "  skipped (pass --rebind to run it)"
elif [ -d /sys/bus/platform/drivers/i2c_designware ]; then
    cp /proc/interrupts "$OUT/irq-before.txt"
    if echo "$I2C_ACPI_ID" > /sys/bus/platform/drivers/i2c_designware/unbind 2>>"$OUT/diag-rebind.txt"; then
        echo "  unbind ok"
    else
        echo "  unbind FAILED (see $OUT/diag-rebind.txt)"
    fi
    sleep 1
    if echo "$I2C_ACPI_ID" > /sys/bus/platform/drivers/i2c_designware/bind 2>>"$OUT/diag-rebind.txt"; then
        echo "  bind ok"
    else
        echo "  bind FAILED (see $OUT/diag-rebind.txt)"
    fi
    sleep 3
    cp /proc/interrupts "$OUT/irq-after.txt"
    echo "  -- dmesg right after the rebind --"
    dmesg | tail -12 | tee "$OUT/diag-rebind-dmesg.txt" | sed 's/^/    /'
    echo "  -- controller IRQ lines, before and after --"
    grep -iE "i2c_designware|i2c_dw|${I2C_ACPI_ID}|idma" "$OUT/irq-before.txt" | sed 's/^/    BEFORE: /'
    grep -iE "i2c_designware|i2c_dw|${I2C_ACPI_ID}|idma" "$OUT/irq-after.txt"  | sed 's/^/    AFTER:  /'
else
    echo "  i2c_designware platform driver not present"
fi

echo
echo "== C: shared IRQ damage =="
dmesg | grep -iE 'nobody cared|disabling IRQ|spurious' > "$OUT/diag-sharedirq.txt"
if [ -s "$OUT/diag-sharedirq.txt" ]; then
    sed 's/^/  /' "$OUT/diag-sharedirq.txt"
else
    echo "  none (good)"
fi

echo
echo "== D: ACPI and power state =="
{
    echo "${TOUCH_ACPI_ID} status         = $(cat "/sys/bus/acpi/devices/${TOUCH_ACPI_ID}/status" 2>/dev/null)"
    echo "${I2C_ACPI_ID} runtime_status = $(cat "/sys/bus/platform/devices/${I2C_ACPI_ID}/power/runtime_status" 2>/dev/null)"
    echo "${I2C_ACPI_ID} power/control   = $(cat "/sys/bus/platform/devices/${I2C_ACPI_ID}/power/control" 2>/dev/null)"
    echo "i2c_hid_acpi clients      = $(ls /sys/bus/i2c/drivers/i2c_hid_acpi/ 2>/dev/null | grep -iE 'FTS|i2c-' | tr '\n' ' ')"
} | tee "$OUT/diag-acpi.txt" | sed 's/^/  /'

echo
echo "== E: is there a touch input device at all? =="
found=0
for d in /sys/class/input/input*; do
    [ -r "$d/name" ] || continue
    name=$(cat "$d/name" 2>/dev/null)
    case "$name" in
        *FTS3528*)
            ev=$(ls "$d" 2>/dev/null | grep -m1 '^event')
            echo "  FOUND: $name -> /dev/input/${ev:-<no event node>}"
            found=1
            ;;
    esac
done
[ "$found" = 1 ] || echo "  no FTS3528 input device (the HID device never got registered)"

# hand the evidence back to the invoking user, not to root
if [ -n "${SUDO_USER:-}" ]; then
    chown -R "${SUDO_USER}:" "$OUT" 2>/dev/null || true
fi

echo
echo "DONE. Evidence in $OUT/"
echo "Read it like this:"
echo "  A: only 'controller timed out'      -> host controller side, needs a cold power-cycle"
echo "  A: 'abort' / 'arbitration' / -ENXIO -> touch chip side, different problem"
echo "  B: IRQ counter does not move        -> interrupt delivery is the failing link"
echo "  E: no input device                  -> matches the wedge described in README.md"
