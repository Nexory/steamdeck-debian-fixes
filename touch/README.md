# Steam Deck LCD: touchscreen dead under mainline Linux (Debian 13)

Display works, audio works, controls work, and the touchscreen is completely dead
after installing a generic Linux distribution on a Steam Deck LCD.

This is almost always **not** a broken panel and **not** a kernel bug. It is a
power/IRQ wedge inside the touch controller, and it is cleared by one BIOS menu
entry. The whole fix takes about two minutes and needs no driver, no patch and no
kernel downgrade.

- **Hardware:** Steam Deck LCD (DMI product name `Jupiter`)
- **Verified on:** Debian 13 trixie, kernel `7.1.3+deb13-amd64` (backports) and
  the stock `6.12.101` kernel
- **Touch controller:** FTS3528 on the AMD I2C bus, ACPI id `AMDI0010:01`, bus `i2c-1`
- **Input device name:** `FTS3528:00 2808:1015`

Paths in this document use `/home/deck`. Adjust to your username.

---

## TL;DR - the fix

1. Shut the Deck down completely (not sleep, not reboot).
2. Hold **Volume Up + Power** until the boot chime, then release. The BIOS /
   Setup Utility appears.
3. Select **Battery Storage Mode** and confirm. The Deck powers off hard, and
   the battery is now physically disconnected.
4. Plug in USB-C power. The Deck cold-boots.

Touch works from that boot on, and it keeps working across ordinary warm reboots.
It only comes back if the controller loses power deeply again (full battery
drain, or another storage-mode cycle). If that happens, repeat the same steps.

---

## Symptom

After a clean install of Debian 13 (or any other mainline-kernel distribution)
on a Steam Deck LCD:

- The screen lights up and renders normally. Backlight, brightness and the
  gamepad controls are fine.
- Touch input does nothing at all. No cursor movement, no taps, no gestures.
- `dmesg` is full of I2C HID timeouts. The exact wording varies by kernel
  version, but it looks like this:

```
i2c_designware AMDI0010:01: controller timed out
i2c_hid_acpi i2c-FTS3528:00: failed to reset device
i2c_hid_acpi i2c-FTS3528:00: can't add hid device: -61
i2c_hid_acpi: probe of i2c-FTS3528:00 failed with error -61
```

- Because the HID device never gets added, no input node is created for it.
  `/proc/bus/input/devices` and `/sys/class/input/` have no `FTS3528` entry at
  all, so there is nothing for `evtest` or `libinput` to open.

The giveaway is the wording. **`controller timed out` is a controller-side
symptom.** If the touch chip itself were answering but unhappy, you would see
I2C abort or `-ENXIO` style errors instead, coming from the slave side of the
bus. A plain timeout means the transfer never completed on the host controller.

---

## Confirm that your case matches

Run these three checks before doing anything. All of them are read-only.

### 1. Kernel messages

```bash
dmesg | grep -iE 'fts|i2c_hid|hid-multitouch'
```

You are looking for `FTS3528` lines that end in a timeout or a failed probe. If
you instead see a successful sequence ending in `input: FTS3528:00 2808:1015 as
/devices/...`, your touch controller is fine and your problem is elsewhere
(compositor, libinput configuration, screen rotation matrix).

### 2. Does an input device exist at all?

```bash
for d in /sys/class/input/input*; do
  printf '%s: %s\n' "${d##*/}" "$(cat "$d/name" 2>/dev/null)"
done
```

On a wedged Deck there is no `FTS3528:00 2808:1015` line. On a healthy Deck
there is exactly one, and it owns an `eventN` node.

### 3. Does the event device actually report touches?

Install `evtest` first:

```bash
sudo apt install evtest
```

Find the node and open it:

```bash
sudo evtest "$(
  for d in /sys/class/input/input*; do
    case "$(cat "$d/name" 2>/dev/null)" in
      *FTS3528*) printf '/dev/input/%s\n' "$(ls "$d" | grep -m1 '^event')"; break;;
    esac
  done
)"
```

Touch the screen. A working controller emits a burst of `ABS_MT_*` and
`BTN_TOUCH` events per contact. Silence with the node present is a different
problem from the node being absent entirely.

There is also a bundled helper that runs all of the above plus the deeper
checks. See [Scripts](#scripts) below.

---

## Root cause

The FTS3528 touch controller hangs off the AMD Designware I2C controller
(`AMDI0010:01`, exposed as `i2c-1`) and signals through a GPIO interrupt. When
the Deck is flashed with a distribution that is not SteamOS, the controller can
end up in a state where it neither answers on the bus nor raises its interrupt.
Every `i2c_hid_acpi` probe then runs into the host controller timeout shown
above, and the HID device is never registered.

Three properties pin this down as a **controller-side power/IRQ wedge**:

1. **It is not a kernel regression.** Kernel `6.12.101` (Debian stock) and
   `7.1.3+deb13-amd64` (backports) behave identically: both wedged before the
   fix, both working after it, with no other change. A/B testing the kernel is a
   dead end here, and any advice that starts with "downgrade your kernel" is
   solving a different problem.
2. **It is not a driver-visible fault.** The driver stack is doing the right
   thing. It asks, nothing answers, it times out and gives up. Rebinding
   `i2c_designware` or `i2c_hid_acpi` at runtime does not help, because rebinding
   re-runs the software probe without changing the hardware state.
3. **It survives a warm reboot.** This is the important part. A normal
   `reboot` keeps the rails that feed the controller alive, so the wedge is
   carried straight into the next boot. Only a real loss of power to the
   controller resets it.

The panel is not involved. The display path is separate from the touch digitizer
and works throughout.

---

## The fix, step by step

The goal is a **true cold power-cycle of the touch controller**. Pulling the
USB-C cable is not enough, and holding the power button is not enough, because
the internal battery keeps feeding the rails either way. The Deck BIOS has an
entry that physically disconnects the battery, which is exactly the hammer
needed here.

### 1. Power off completely

```bash
sudo systemctl poweroff
```

Wait until the Deck is fully dark. Do not use suspend and do not use reboot.

### 2. Enter the BIOS

Hold **Volume Up**, then press and hold **Power**. Keep Volume Up held until you
hear the boot chime and the Setup Utility appears. Release both.

Use the D-pad and A to navigate.

### 3. Select "Battery Storage Mode"

The entry is on the main Setup Utility page (on some BIOS revisions it sits one
level down under the power or setup submenu). Confirm the prompt.

The Deck powers off hard and immediately. This is expected. The battery is now
disconnected from the board, so nothing on the device is powered, including the
touch controller. This is also called ship mode, and it is a supported, official
BIOS function - it is what the device ships in from the factory.

Nothing is erased. Storage mode does not touch the OS, the partitions or the
BIOS settings.

### 4. Plug in USB-C power

Connect the charger. The Deck comes back out of storage mode and cold-boots. On
this boot the touch controller powers up from scratch and enumerates cleanly.

### 5. Verify

```bash
dmesg | grep -iE 'fts|i2c_hid|hid-multitouch'
```

A healthy boot ends with an `input:` line, something like:

```
i2c_hid_acpi i2c-FTS3528:00: HID device ...
input: FTS3528:00 2808:1015 as /devices/platform/AMDI0010:01/i2c-1/i2c-FTS3528:00/...
hid-multitouch 0018:2808:1015.0001: input,hidraw0: I2C HID v1.00 Device [FTS3528:00 2808:1015]
```

Then confirm with `evtest` as shown above, and touch the screen.

---

## How long the fix lasts

- **Warm reboots:** touch keeps working. `reboot`, kernel updates, switching
  between the 6.12 and 7.1 kernels - all fine once the controller has come up
  clean once.
- **Suspend and resume:** fine.
- **Deep power loss:** the wedge can come back. That means a full battery
  drain to zero, another storage-mode cycle, or leaving the Deck flat and
  unplugged for a long time.

If touch dies again, run the same four steps. Nothing accumulates and nothing
degrades from repeating it.

---

## What does not work

Documented so you do not spend an evening on any of these. All were tried on the
affected device.

| Attempt | Result |
| --- | --- |
| Warm reboot, repeatedly | No change. The wedge survives warm reboots by definition. |
| Unplug USB-C, hold power 10+ seconds | No change. The internal battery still powers the controller. |
| Downgrading to the stock 6.12.101 kernel | No change. Both kernels wedge identically. |
| Rebinding `i2c_designware` / `i2c_hid_acpi` via sysfs | No change. Software probe re-run, hardware state untouched. |
| Lowering the I2C bus speed from 400 kHz to 100 kHz | No change. Ruled out. |
| Reflashing the BIOS | Not needed. Ruled out. |
| Blacklisting or reloading `hid_multitouch` | No change. The HID device never gets created in the first place. |
| Kernel parameters (`i2c_designware` options, `acpi_osi`, IRQ overrides) | No change. |

---

## Scripts

All scripts are POSIX-ish bash and are meant to be read before they are run.
Default output directory is `/home/deck/touch-evidence`; adjust to your
username, or pass a directory as the first argument.

### `touch-diag.sh`

Collects everything needed to tell a controller-side wedge from a slave-side
fault. Read-only by default.

```bash
sudo ./touch-diag.sh                      # read-only checks
sudo ./touch-diag.sh --rebind             # additionally rebind the I2C controller
sudo ./touch-diag.sh --rebind /tmp/eviz   # custom output directory
```

Sections:

- **A** - the kernel messages, filtered. `timed out` points at the controller
  side; `abort` / `arbitration` / `-ENXIO` point at the slave side.
- **B** (only with `--rebind`) - unbind and rebind `AMDI0010:01` on the
  `i2c_designware` platform driver, and compare `/proc/interrupts` before and
  after. If the controller interrupt counter does not move across a forced
  transfer, interrupt delivery is the failing link. The rebind is undone in the
  same run and does not persist across a reboot, but it does briefly detach a
  live bus, which is why it is opt-in.
- **C** - shared-IRQ damage (`nobody cared`, `disabling IRQ`, `spurious`).
- **D** - ACPI status of `FTS3528:00`, runtime power state of `AMDI0010:01`, and
  which clients `i2c_hid_acpi` currently owns.

### `touch-capture.sh`

Snapshots the state of a **working** touchscreen. Run it right after the fix, so
you have a known-good reference to diff against if the wedge ever returns.
Strictly read-only.

```bash
sudo ./touch-capture.sh
```

It records driver binding, the input device list, the successful `dmesg`
sequence, the GPIO table from debugfs, the interrupt counters and the ACPI
status, and it prints a pass/fail verdict on whether the touch input node exists.

### `grub-boot-once.sh`

Boots a different installed kernel exactly once via `grub-reboot`, then falls
back to the normal default on the boot after that. Useful for A/B testing any
hardware behaviour against another kernel.

```bash
sudo ./grub-boot-once.sh 6.12            # stage the one-shot boot
sudo ./grub-boot-once.sh 6.12 --reboot   # stage it and reboot immediately
```

It backs up `/etc/default/grub` before switching `GRUB_DEFAULT` to `saved`, and
it refuses to change anything if it cannot find a matching non-recovery menu
entry.

For **this particular** problem the script is a way to reproduce the negative
result, not a fix: the touchscreen is dead on both 6.12 and 7.1, which is one of
the reasons the cause is known to be hardware state and not kernel code.

---

## FAQ

**Is "Battery Storage Mode" safe? Will it erase anything?**
It is a stock BIOS function that Valve ships for storing and shipping the device.
It disconnects the battery and powers the Deck off. It does not touch storage,
partitions, the OS or saved BIOS settings.

**How do I get out of storage mode?**
Plug in USB-C power. That is the only way, and it is the intended way. The power
button alone will not wake it.

**Do I need the official charger?**
Any USB-C supply that the Deck normally charges from works.

**Does this affect the Steam Deck OLED?**
This document is verified on the LCD model (`Jupiter`) with the FTS3528
controller. The OLED uses different touch hardware. The general principle - a
wedged I2C peripheral needs a genuine power cut, not a warm reboot - still
applies, but the specific device ids here will not match.

**Does SteamOS have the same problem?**
Not in practice. SteamOS ships with the platform quirks and firmware handling
that Valve maintains for this device, so the controller is normally brought up
cleanly. The wedge shows up when a generic distribution takes over.

**Do I need a custom kernel, a DKMS module or a patch?**
No. Nothing is compiled and no module is added. The in-tree `i2c_designware`,
`i2c_hid_acpi` and `hid_multitouch` drivers are correct and sufficient. The only
thing that was ever wrong is the power state of the controller.

**Touch works but the coordinates are rotated or mirrored.**
That is a separate, purely software issue. The panel is mounted rotated, so the
compositor needs a transformation matrix on the `FTS3528:00 2808:1015` device.
That is out of scope for this document.

**The input node exists but `evtest` shows nothing when I touch the screen.**
Different failure mode. The controller enumerated, so it is not the wedge
described here. Check that you opened the right `eventN` node, and that no other
process is grabbing the device exclusively.

**Can this be automated so I never have to enter the BIOS?**
Not from userspace. The whole point is that the rails feeding the controller
have to drop, and nothing the OS can write to sysfs will do that while the
battery is connected. A `systemd` unit cannot substitute for a physical power
cut.

**How often does it come back?**
Only after a deep power loss. In normal daily use, once fixed it stays fixed.

---

## Notes on method

Every claim above comes from the affected device, not from a forum post:

- Both kernels were booted on the same install, with the same userspace, and
  produced the same wedged state, which is what rules out a regression.
- The `controller timed out` versus abort distinction in `dmesg` is what
  separates a host-controller problem from a chip-not-answering problem, and it
  is why the fix targets power rather than the driver.
- The working state was captured immediately after the fix (`touch-capture.sh`)
  so that a future failure can be diffed against a real known-good baseline
  instead of a memory of one.

Maintained by **Nexory**.
