#!/usr/bin/env python3
#
# deck-waked.py - wake a DPMS-blanked display on TOUCH or on an external trigger file.
#
# Why this exists:
#   GNOME/mutter blanks the display after the idle timeout, but it does NOT treat
#   touchscreen input as pointer activity, so a touch never wakes the panel back up.
#   On a headless kiosk there is no mouse either, so the screen simply stays dark.
#
# What it does:
#   Watches the touchscreen event device(s) and an optional wake-trigger file, and
#   injects an invisible relative mouse "nudge" (+1 / -1 on X, net zero movement)
#   through /dev/uinput. mutter sees genuine pointer input, wakes DPMS and resets
#   the idle timer. The cursor does not move, because the two deltas cancel out.
#
# THE IMPORTANT PART (applies to any Wayland/libinput kiosk):
#   A uinput device that declares ONLY EV_REL is not classified as a pointer by
#   libinput, so mutter ignores its events and the display stays dark. Declaring an
#   EV_KEY capability with BTN_LEFT - the button is never pressed, only advertised -
#   makes libinput classify the device as a real mouse, and only THEN does the
#   relative nudge wake the display. See make_uinput() below.
#
# Runs as a root system service: needs read on /dev/input/event* and write on /dev/uinput.
# Author: Nexory
#
import os
import struct
import fcntl
import glob
import select
import time

UINPUT = "/dev/uinput"

# uinput ioctls (from linux/uinput.h)
UI_SET_EVBIT = 0x40045564   # _IOW('U', 100, int)
UI_SET_KEYBIT = 0x40045565  # _IOW('U', 101, int)
UI_SET_RELBIT = 0x40045566  # _IOW('U', 102, int)
UI_DEV_CREATE = 0x5501      # _IO('U', 1)

# event types / codes (from linux/input-event-codes.h)
EV_SYN = 0x00
EV_KEY = 0x01
EV_REL = 0x02
REL_X = 0x00
REL_Y = 0x01
BTN_LEFT = 0x110
SYN_REPORT = 0x00

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Optional external wake trigger. Any process may simply touch(1) this file to
# wake the screen, for example an optional voice assistant that wants the panel
# lit while it answers. Leave it as is if you do not use one; the file never
# needs to exist. Adjust the path to your username.
WAKE_FILE = "/home/deck/voice/.wake"

# How long after its last modification the trigger file counts as "active".
WAKE_FRESH = 3.0

# Minimum interval between two nudges. Without this, a continuous touch drag
# would emit a nudge on every poll iteration.
THROTTLE = 0.4

# Substrings used to identify the touchscreen in /sys/class/input/input*/name.
# The Steam Deck LCD reports "FTS3528". Adjust for other panels.
TOUCH_NAME_MATCHES = ("fts3528", "fts")

# Poll interval for select() on the touch devices.
POLL_INTERVAL = 0.3


def make_uinput():
    """Create the virtual pointer device and return its file descriptor.

    Capability order matters for how libinput classifies the device:
      EV_REL + REL_X/REL_Y alone  -> NOT a pointer, mutter ignores it, screen stays dark
      EV_REL + EV_KEY/BTN_LEFT    -> classified as a mouse, the nudge wakes DPMS
    BTN_LEFT is only advertised here. It is never actually pressed, so nothing is
    ever clicked in the session.
    """
    fd = os.open(UINPUT, os.O_WRONLY | os.O_NONBLOCK)

    fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_X)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)

    # The single line that makes the difference between "nothing happens" and
    # "display wakes": without a button capability libinput does not consider
    # this device a pointer.
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)

    # struct uinput_user_dev: char name[80], struct input_id id,
    # __u32 ff_effects_max, __s32 absmax/absmin/absfuzz/absflat[ABS_CNT=64]
    name = b"deck-wake".ljust(80, b"\x00")
    input_id = struct.pack("HHHH", 0x03, 0x1234, 0x5678, 1)  # BUS_USB, vendor, product, version
    ff_effects_max = struct.pack("i", 0)
    absinfo = b"\x00" * (4 * 64 * 4)
    os.write(fd, name + input_id + ff_effects_max + absinfo)

    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.3)  # give the compositor a moment to enumerate the new device
    return fd


def emit(fd, etype, code, value):
    """Write one struct input_event.

    Layout on 64-bit: struct timeval (2 x long = 16 bytes) + type (u16)
    + code (u16) + value (s32) = 24 bytes. The kernel fills in the timestamp,
    so zeros are fine here.
    """
    os.write(fd, struct.pack("llHHi", 0, 0, etype, code, value))


def nudge(fd):
    """Move the pointer one pixel right, then one pixel back. Net movement zero."""
    emit(fd, EV_REL, REL_X, 1)
    emit(fd, EV_SYN, SYN_REPORT, 0)
    emit(fd, EV_REL, REL_X, -1)
    emit(fd, EV_SYN, SYN_REPORT, 0)


def find_touch_fds():
    """Open every event device whose input name matches the touchscreen."""
    fds = []
    for d in glob.glob("/sys/class/input/input*"):
        try:
            with open(os.path.join(d, "name")) as fh:
                name = fh.read().strip().lower()
        except Exception:
            continue
        if not any(m in name for m in TOUCH_NAME_MATCHES):
            continue
        for ev in glob.glob(os.path.join(d, "event*")):
            try:
                fds.append(os.open("/dev/input/" + os.path.basename(ev),
                                   os.O_RDONLY | os.O_NONBLOCK))
            except Exception:
                pass
    return fds


def wake_file_active():
    """True if the external trigger file was touched within the last WAKE_FRESH seconds."""
    try:
        return (time.time() - os.path.getmtime(WAKE_FILE)) < WAKE_FRESH
    except Exception:
        return False


def main():
    ui = make_uinput()
    touch = find_touch_fds()
    print("deck-wake: uinput ready, %d touch device(s), waking on touch or %s"
          % (len(touch), WAKE_FILE), flush=True)

    last = 0.0
    while True:
        ready = []
        if touch:
            try:
                ready, _, _ = select.select(touch, [], [], POLL_INTERVAL)
            except Exception:
                pass
        else:
            time.sleep(POLL_INTERVAL)

        active = False
        if ready:
            for fd in ready:
                try:
                    # Drain and discard. Only the fact that input arrived matters;
                    # the events themselves still go to the compositor as usual.
                    os.read(fd, 4096)
                except Exception:
                    pass
            active = True

        if wake_file_active():
            active = True

        if active and (time.time() - last) > THROTTLE:
            nudge(ui)
            last = time.time()


if __name__ == "__main__":
    main()
