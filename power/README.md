# Fan control and battery charge limit

On a Steam Deck LCD running Debian, two things go wrong that the stock and backports kernels give you no
control over, because the `steamdeck` platform driver Valve ships in SteamOS is not built:

- **The fan runs loud at idle and "hunts."** With no OS-side fan control the embedded controller (EC)
  runs its own curve, which on a cool, idle server keeps the fan spinning around 4000 RPM or oscillates
  between 0 and ~4000 for no load reason. There is no `fan*` or `pwm*` entry under `/sys/class/hwmon` at
  all, so nothing can even read the fan, let alone control it.
- **The battery cycles 24/7.** Kept on AC, the pack is not held at a fixed level: it drifts down and
  recharges in an endless loop, which wears it faster and adds a charging-related fan blip each time.
  No charge-limit control is exposed either.

Both are fixed by the same out-of-tree module.

## What is missing

SteamOS carries a `steamdeck` MFD / hwmon driver (Valve's `evlaV/linux-integration` tree) that exposes
`steamdeck_hwmon` with `fan1_input`, `fan1_target` and `max_battery_charge_level`. Debian does not build
it: `modinfo steamdeck` finds nothing and no matching platform device exists. The community package
`firlin123/steamdeck-dkms` builds exactly this driver as a DKMS module, so it rebuilds automatically on
every kernel update. It compiles cleanly against the Debian 13 backports kernel (7.1.3) and the stock
6.12.

Do NOT install the full `jupiter-hw-support` package on a non-SteamOS distro: it is known to cause boot
problems. The DKMS module alone is all you need.

## The fix

`install.sh` does the whole thing (run with `sudo`):

1. Installs build deps (`git dkms dpkg-dev debhelper dh-dkms`).
2. Clones and builds `firlin123/steamdeck-dkms` into a `.deb` and installs it. DKMS registers the module
   and an initramfs hook loads it at boot; kernel updates rebuild it automatically.
3. Loads the module and verifies `steamdeck_hwmon` appeared with `max_battery_charge_level`. It aborts
   before changing anything permanent if the driver does not bind.
4. Sets a **battery charge limit of 80%** (`LIMIT` at the top of `install.sh`) and installs `steamdeck-chargelimit.service` to re-apply it on
   every boot (the value resets to unlimited when the module loads).
5. Installs `steamdeck-fancurve.service`, a small daemon that drives `fan1_target` on a temperature
   curve: near-silent (2000 RPM) below 50C, ramping linearly to full (~4500) at 80C.

Change the limit or the curve by editing the two files before running, or edit the installed copies
(`/etc/systemd/system/steamdeck-chargelimit.service`, `/usr/local/bin/steamdeck-fancurve.sh`) and
`systemctl restart` afterwards.

## Non-obvious traps

- **`fan1_target = 0` means "hand control back to the EC" (loud), not "fan off."** Writing 0 does not
  stop the fan, it releases it to the EC's own curve. To run the fan quietly you must write a low
  non-zero target. On the LCD the fan tracks the target well (writing 2000 gives ~2036 RPM) and tops out
  around 4550 RPM.
- Because of that the fan daemon rewrites its target **every few seconds** to keep manual control, and on
  stop or crash it writes 0 so the EC takes over again (loud, but never uncooled).
- The charge limit lives in `max_battery_charge_level` and defaults back to unlimited each time the
  module loads, which is why it needs a boot-time service, not a one-off write. If the pack is already
  above the new limit it simply stops charging and drifts down to it.

## Verifying

- `cat /sys/class/hwmon/hwmon*/name` should list `steamdeck_hwmon`.
- Under that hwmon: `fan1_input` (RPM), `fan1_target`, `max_battery_charge_level` (should read 80).
- `dkms status` should show the module installed for your running kernel.
- Under load the fan ramps with temperature; a CPU-heavy task on the LCD settles around 75C with the fan
  still short of its maximum.

Credit: the driver is Valve's, packaged for DKMS by
[firlin123/steamdeck-dkms](https://github.com/firlin123/steamdeck-dkms).
