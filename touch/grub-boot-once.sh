#!/usr/bin/env bash
# grub-boot-once.sh - boot a different installed kernel EXACTLY ONCE via GRUB.
#
# The boot after that returns to the normal default, so nothing is left changed
# on the machine. Handy for A/B testing hardware behaviour against another
# kernel without committing to it.
#
# Usage:
#   sudo ./grub-boot-once.sh <kernel-version-substring> [--reboot]
#
# Examples:
#   sudo ./grub-boot-once.sh 6.12             # stage the one-shot boot, reboot yourself
#   sudo ./grub-boot-once.sh 6.12 --reboot    # stage it and reboot now
#
# Note for the Steam Deck touchscreen case (see README.md): switching kernels
# does NOT fix a wedged FTS3528 touch controller. Both 6.12 and 7.1 behave
# identically. This script is how that negative result is reproduced, not a fix.

set -eu

VERSION=""
DO_REBOOT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --reboot) DO_REBOOT=1 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) VERSION="$1" ;;
    esac
    shift
done

if [ -z "$VERSION" ]; then
    echo "Usage: sudo $0 <kernel-version-substring> [--reboot]" >&2
    exit 2
fi

if [ "$(id -u)" != 0 ]; then
    echo "Please run as root:  sudo $0 $VERSION" >&2
    exit 1
fi

GRUB_CFG=/boot/grub/grub.cfg
[ -r "$GRUB_CFG" ] || { echo "cannot read $GRUB_CFG" >&2; exit 1; }

echo "== 1. locate the menu entry for '$VERSION' =="
# GRUB on Debian puts non-default kernels inside one "Advanced options" submenu.
SUBMENU=$(grep -oP "submenu '\K[^']+" "$GRUB_CFG" | head -1 || true)
ENTRY=$(grep -oP "menuentry '\K[^']*${VERSION}[^']*" "$GRUB_CFG" \
        | grep -v -i recovery | head -1 || true)

if [ -z "$ENTRY" ]; then
    echo "  ERROR: no non-recovery menu entry matching '$VERSION'." >&2
    echo "  Installed kernels:" >&2
    grep -oP "menuentry '\K[^']+" "$GRUB_CFG" | sed 's/^/    /' >&2
    echo "  Nothing was changed." >&2
    exit 1
fi

echo "  submenu: ${SUBMENU:-<none, entry is top level>}"
echo "  entry:   $ENTRY"

echo "== 2. make sure GRUB honours a saved default =="
if grep -q '^GRUB_DEFAULT=saved' /etc/default/grub; then
    echo "  GRUB_DEFAULT is already 'saved'"
else
    cp /etc/default/grub /etc/default/grub.bak-boot-once
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    else
        echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
    fi
    update-grub >/dev/null 2>&1 || update-grub
    echo "  GRUB_DEFAULT=saved (backup: /etc/default/grub.bak-boot-once)"
fi

echo "== 3. stage the one-shot boot =="
if [ -n "$SUBMENU" ]; then
    grub-reboot "${SUBMENU}>${ENTRY}"
else
    grub-reboot "$ENTRY"
fi
echo "  next boot -> $VERSION, the boot after that -> normal default"

if [ "$DO_REBOOT" = 1 ]; then
    echo "== 4. rebooting in 10 seconds (Ctrl-C aborts) =="
    sleep 10
    systemctl reboot
else
    echo
    echo "Staged. Reboot when ready:  sudo systemctl reboot"
    echo "After the reboot, check with:  uname -r"
fi
