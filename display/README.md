# Steam Deck LCD on Debian 13: display blanking and adaptive brightness

Two related fixes for a Steam Deck LCD running Debian 13 (trixie) with GNOME on
Wayland, used as an always-on kiosk / home server with no keyboard and no mouse
attached.

* **Fix A** - real display-off (DPMS blank) that still wakes on **touch** or on an
  external **trigger file**, using a tiny uinput daemon.
* **Fix B** - adaptive brightness from the ambient light sensor, by building the
  missing `ltrf216a` kernel module out of tree.

Fix A is the interesting one, and the core of it is not Deck specific: it applies
to **any Wayland / libinput kiosk with a touchscreen and no mouse**.

Tested on:

| Item | Value |
|---|---|
| Hardware | Steam Deck LCD (AMD Van Gogh) |
| OS | Debian 13 (trixie) |
| Desktop | GNOME on Wayland (mutter) |
| Touch controller | FTS3528 (matched by name in `/sys/class/input/input*/name`) |
| Ambient light sensor | Liteon LTR-F216A |
| Backlight | `/sys/class/backlight/amdgpu_bl0` (0 - 65535) |

> All paths in this repo use `/home/deck`. **Adjust to your username.**

---

## Fix A - display-off that wakes on touch

### 1. Make GNOME blank the display (and only the display)

Two settings, run **as the desktop user**, not as root:

```bash
# Blank the display after 60 seconds of inactivity.
gsettings set org.gnome.desktop.session idle-delay 'uint32 60'

# Do NOT suspend the machine when idle on AC. This is a server; only the
# panel should go dark, the box has to stay up.
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
```

Verify:

```bash
gsettings get org.gnome.desktop.session idle-delay
# uint32 60
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type
# 'nothing'
```

Note the quoting on `idle-delay`: the schema type is `u`, so the value must be
passed as the literal string `'uint32 60'`. `gsettings set ... 60` fails.

This part works. The panel goes properly dark (DPMS off, backlight off), and the
machine keeps running. The problem is getting back out of it.

### 2. The problem

**mutter does not wake a blanked display on touchscreen input.**

Touch events from the FTS3528 do not reset the idle timer and do not trigger a
DPMS wake, because libinput classifies that device as a touchscreen, not as a
pointer. On a normal laptop this never shows up: you press a key or move the
trackpad and the screen comes back. On a headless kiosk there is no keyboard and
no mouse, so the display is blanked and **nothing you can do at the panel brings
it back**. You have to SSH in and poke the compositor.

### 3. The solution

A small root daemon, [`deck-waked.py`](deck-waked.py), that:

1. opens every `/dev/input/event*` belonging to the touchscreen and `select()`s on them,
2. also watches an optional trigger file (see below),
3. on any activity, injects a **net-zero relative mouse nudge** through
   `/dev/uinput`: move X by `+1`, sync, move X by `-1`, sync.

mutter sees genuine pointer input, wakes DPMS and resets the idle timer. The
pointer does not actually move, because the two deltas cancel out. Touch events
themselves are only drained, never consumed or rewritten, so normal touch input
continues to reach the session as usual.

### 4. The key insight: EV_REL alone is not a pointer

**This is the part worth remembering.**

The obvious implementation creates a uinput device that declares `EV_REL` with
`REL_X` and `REL_Y`, writes the relative events, and does nothing else. That
implementation **does not work**. The events are emitted, the kernel accepts
them, `evtest` on the virtual device shows them arriving, and the display stays
completely dark.

The reason is libinput's device classification. A device that advertises only
relative axes and no buttons is not classified as `LIBINPUT_DEVICE_CAP_POINTER`.
libinput therefore does not treat its events as pointer activity, mutter never
sees a reason to wake the screen, and the idle timer is never reset. There is no
error anywhere. It simply silently does nothing.

The fix is one extra capability:

```python
fcntl.ioctl(fd, UI_SET_EVBIT,  EV_REL)
fcntl.ioctl(fd, UI_SET_RELBIT, REL_X)
fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)

fcntl.ioctl(fd, UI_SET_EVBIT,  EV_KEY)     # <-- the difference
fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)   # <-- advertised, never pressed
```

Declaring `EV_KEY` with `BTN_LEFT` makes libinput classify the device as a real
mouse. The button is only **advertised**; the daemon never emits a press or a
release, so nothing is ever clicked in the session. With those two ioctls in
place, the same relative nudge that did nothing before now wakes the display
immediately.

That one capability is the entire difference between "nothing happens" and
"display wakes". If you are writing any kind of wake, presence, or
anti-idle helper for a Wayland compositor, declare a button.

Two smaller details that also matter:

* **Wait after `UI_DEV_CREATE`.** The compositor needs a moment to enumerate the
  new device. Nudges sent immediately after creation are lost. The daemon sleeps
  0.3 s.
* **Throttle the nudges.** A finger dragging across the panel produces a
  continuous event stream. Without the 0.4 s throttle the daemon emits a nudge on
  every poll iteration for as long as you touch the screen.

### 5. Optional external trigger

`deck-waked.py` also watches a trigger file:

```python
WAKE_FILE = "/home/deck/voice/.wake"
WAKE_FRESH = 3.0
```

If that file's mtime is newer than `WAKE_FRESH` seconds, the daemon nudges. Any
process can therefore wake the panel with a plain `touch(1)`:

```bash
touch /home/deck/voice/.wake
```

This is deliberately generic. For example, an optional voice assistant can touch
this file to wake the screen while it answers. The file never has to exist; if
it is absent the daemon simply ignores it and wakes on touch only. Change
`WAKE_FILE` to wherever suits your setup.

### 6. Install

```bash
sudo install -m 755 deck-waked.py /usr/local/bin/deck-waked.py
sudo install -m 644 deck-wake.service /etc/systemd/system/deck-wake.service

# uinput is not loaded by default on Debian; make it permanent
echo uinput | sudo tee /etc/modules-load.d/uinput.conf

sudo systemctl daemon-reload
sudo systemctl enable --now deck-wake.service
sudo systemctl status deck-wake.service
```

The unit file:

```ini
[Unit]
Description=Deck Display Wake (Touch/Voice)

[Service]
ExecStartPre=-/sbin/modprobe uinput
ExecStart=/usr/bin/python3 /usr/local/bin/deck-waked.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

`ExecStartPre` carries a leading `-` so that an already-loaded or built-in
`uinput` does not fail the unit. The service runs as root because it needs read access to
`/dev/input/event*` and write access to `/dev/uinput`.

### 7. Verify

```bash
# The daemon reports how many touch devices it attached to.
journalctl -u deck-wake -n 20
# deck-wake: uinput ready, 1 touch device(s), waking on touch or /home/deck/voice/.wake

# The virtual device must show up as a mouse, not as "unknown".
sudo libinput list-devices | grep -A4 deck-wake

# Full test: wait out the idle-delay until the panel is dark, then tap it.
```

If the panel does not come back, check in this order:

1. `ls -l /dev/uinput` - module loaded?
2. `journalctl -u deck-wake` - did the daemon find any touch device? If it found
   zero, your controller reports a different name. Check
   `grep -i . /sys/class/input/input*/name` and extend `TOUCH_NAME_MATCHES`.
3. `sudo libinput list-devices` - is `deck-wake` listed with a pointer
   capability? If not, the `EV_KEY` / `BTN_LEFT` ioctls did not take effect.

---

## Fix B - adaptive brightness from the ambient light sensor

### 1. The problem

The Deck LCD has a **Liteon LTR-F216A** ambient light sensor, but out of the box
Debian gives you no light sensor at all:

* The Debian kernel is built **without `CONFIG_LTRF216A`**, so no driver ever
  binds to the part that is actually there.
* The ACPI tables also reference an **opt3001**, which is **not physically
  present** on this board. Its probe fails with **-121 (ENOTCONN)**. That error
  in `dmesg` is expected and harmless; do not chase it.

Result: `/sys/bus/iio/devices/` has no illuminance device, `iio-sensor-proxy` has
nothing to publish, and GNOME shows no "Automatic Brightness" toggle.

### 2. The fix: build ltrf216a out of tree

The driver exists upstream, it is just not compiled in Debian's config. Build it
against the running kernel:

```bash
sudo bash build-ltrf216a.sh
```

What the script does:

1. installs `linux-headers-$(uname -r)` if missing (falls back to
   `trixie-backports`),
2. fetches `drivers/iio/light/ltrf216a.c` for the matching upstream tag from
   git.kernel.org, falling back to mainline HEAD,
3. builds it with a one-line `obj-m := ltrf216a.o` Makefile,
4. installs the `.ko` into `/lib/modules/$(uname -r)/kernel/drivers/iio/light/`,
   runs `depmod -a`, and `modprobe`s it,
5. adds `ltrf216a` to `/etc/modules-load.d/deck-als.conf` so it loads on boot,
6. reads back `in_illuminance_input` to confirm the sensor is live.

Doing it by hand is four commands:

```bash
sudo apt-get install -y linux-headers-$(uname -r)
mkdir -p /root/ltrf216a-build && cd /root/ltrf216a-build
curl -fsSL "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/iio/light/ltrf216a.c" -o ltrf216a.c
echo "obj-m := ltrf216a.o" > Makefile
make -C /lib/modules/$(uname -r)/build M=$PWD modules
```

### 3. Autoload on boot

One line, one file:

```bash
echo ltrf216a | sudo tee /etc/modules-load.d/deck-als.conf
```

Do **not** put `opt3001` in there. It is not present and only adds a failed probe
to every boot.

Confirm after a reboot:

```bash
lsmod | grep ltrf216a
cat /sys/bus/iio/devices/iio:device*/name
# ltrf216a
cat /sys/bus/iio/devices/iio:device*/in_illuminance_input
```

### 4. Let GNOME do the rest

Once the module is loaded, no custom daemon is needed. `iio-sensor-proxy` picks
up the IIO device and gnome-settings-daemon consumes it:

```bash
systemctl is-active iio-sensor-proxy
# active

# as the desktop user:
gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled true
```

Live check of what the sensor reports:

```bash
monitor-sensor --light
```

"Automatic Brightness" also appears in GNOME Settings > Power once the sensor is
visible.

`setup-adaptive-backlight.sh` in this directory wraps steps 3 and 4, checks that
the sensor actually reports illuminance before changing anything, and installs a
udev rule that makes `/sys/class/backlight/amdgpu_bl0/brightness` writable by the
`video` group (only needed if you also want to set brightness by hand from a
non-root process).

> An earlier revision of this project used a custom polling daemon that read the
> sensor and wrote the backlight itself. It was **retired** once the kernel module
> loaded, because GNOME already does this natively and does it better (smoothing,
> respecting the user's manual override). The GNOME-native path above is the
> recommended one.

### 5. Kernel upgrades

An out-of-tree module built this way is bound to the kernel it was built against.
After a kernel upgrade, `ltrf216a` will not load until you rerun
`build-ltrf216a.sh` under the new kernel. If you upgrade often, package it with
DKMS instead so it rebuilds automatically.

---

## Files

| File | Purpose |
|---|---|
| `deck-waked.py` | Fix A: touch / trigger-file wake daemon, uinput nudge |
| `deck-wake.service` | Fix A: systemd unit for the daemon |
| `build-ltrf216a.sh` | Fix B: out-of-tree build of the ambient light sensor module |
| `setup-adaptive-backlight.sh` | Fix B: enable the GNOME-native adaptive brightness path |

## Quick reference

```bash
# Fix A
gsettings set org.gnome.desktop.session idle-delay 'uint32 60'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
sudo install -m 755 deck-waked.py /usr/local/bin/deck-waked.py
sudo install -m 644 deck-wake.service /etc/systemd/system/deck-wake.service
echo uinput | sudo tee /etc/modules-load.d/uinput.conf
sudo systemctl daemon-reload && sudo systemctl enable --now deck-wake.service

# Fix B
sudo bash build-ltrf216a.sh
echo ltrf216a | sudo tee /etc/modules-load.d/deck-als.conf
gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled true
```

---

Maintained by Nexory. Use at your own risk; these touch kernel modules, udev
rules and system services.
