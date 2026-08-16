# steamdeck-debian-fixes

Fixes and notes from turning a Steam Deck LCD into an always-on Debian 13 home server. The Deck runs
Home Assistant in Docker with a Matter bridge, so Alexa can control everything locally without a vendor
cloud. Getting there meant fixing a pile of Steam-Deck-on-generic-Linux problems that are not documented
anywhere in one place: a touchscreen that is dead under mainline kernels, a display that will not blank
without also killing the server, silent speakers and microphone, and an ambient light sensor Debian has
no driver for. Each fix lives in its own subdirectory with a full write-up plus ready-to-run scripts.
This should help anyone running Debian or another mainline-kernel distribution on a Steam Deck LCD,
and especially anyone using one headless or as a kiosk-style server.

## Hardware / software

- Steam Deck LCD (DMI product name "Jupiter"), the original LCD model, not OLED
- Debian 13 "trixie"
- Kernel 7.1.3 from backports (fixes were also checked against the 6.12.101 stock kernel)
- GNOME on Wayland (mutter + libinput)
- Docker, for Home Assistant and the Matter bridge
- Everything below assumes the user home directory `/home/deck` - adjust to your username

## The fixes

| Fix | What it solves | Highlight |
|---|---|---|
| [./touch](./touch) | The FTS3528 touchscreen is dead under mainline Linux: the driver logs controller timeouts and no input device ever appears. Fixed by a cold boot through the BIOS Battery Storage Mode. | The wedge is on the controller side (power/IRQ), not in the kernel: 6.12.101 and 7.1.3 fail and recover identically, rebinding the I2C driver only re-runs the software probe, and the fault survives warm reboots because the rails stay powered. Only cutting power clears it. |
| [./display](./display) | A real DPMS display-off for a machine that must stay awake: the panel blanks after 60s but still wakes on a touch or on a voice command, and the server never suspends. Plus adaptive brightness from the ambient light sensor. | A uinput device that declares only `EV_REL` is not classified as a pointer by libinput, so mutter silently ignores the wake nudge and the panel stays dark with no error anywhere. Advertising `BTN_LEFT` (never pressing it) makes the identical nudge wake the display. Applies to any Wayland/libinput kiosk. |
| [./audio](./audio) | Silent internal speakers and a microphone that records nothing, with PipeWire showing no usable sink or source. | Two pieces are missing on a generic install: the Cirrus Logic CS35L41 smart-amp DSP firmware (Debian package `firmware-cirrus`, non-free-firmware component) and the ALSA UCM profiles from `alsa-ucm-conf` that WirePlumber reads to build sinks and sources. The firmware is only requested at driver probe, so the reboot is mandatory. |
| [./voice](./voice) | Optional: a fully local hands-free voice assistant on the Deck, no cloud speech services. | openWakeWord for the wake word, Silero VAD for capture-until-silence, faster-whisper for transcription and Piper for speech. Two non-obvious traps are documented first: whisper's built-in VAD silently returns an empty transcript for short or quiet clips (so `vad_filter=False`), and Piper ignores `length_scale` from the model sidecar unless it is passed explicitly in a `SynthesisConfig`. |

## Bonus tweaks

Small things that made 24/7 operation stable, not big enough for their own directory:

- Realtek WiFi drops and hangs: put `options rtw88_pci disable_aspm=1` in a file under `/etc/modprobe.d/`,
  then rebuild the initramfs and reboot.
- Disable Wi-Fi powersave (NetworkManager `wifi.powersave = 2`), otherwise the box goes unreachable
  between pings.
- Mask the sleep targets so the machine can never suspend itself:
  `sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`.
- Blank the text console after a minute by adding `consoleblank=60` to the kernel command line, which
  covers the virtual terminals the GNOME idle setting does not touch.

## Local Alexa via Matter

Home Assistant is exposed to Alexa through a Matter bridge, so lights and switches are voice-controlled
entirely on the local network, with no vendor cloud in the path. That side of the setup is out of scope
here - this repo is about the Steam Deck fixes.

## Third-party components

This repository contains only original scripts and documentation, licensed under MIT (see
LICENSE). It does not bundle or redistribute any third-party code. Everything it relies on is
fetched or installed separately from its own source and keeps its own license:

- Linux kernel `ltrf216a` driver (GPL-2.0): `display/build-ltrf216a.sh` downloads this source
  from git.kernel.org at build time and compiles it. The driver is not included here, and the
  module it builds is GPL-2.0 kernel code, not covered by this repo's MIT license.
- openWakeWord, faster-whisper, Piper, Silero VAD: the optional voice front-end imports these as
  libraries (installed with pip), and the wake-word and speech models are downloaded from their
  own sources. None are included here. See each project for its license.
- `firmware-cirrus` (cs35l41 firmware) and `alsa-ucm-conf`: installed from Debian packages by
  `audio/speaker-firmware.sh`, not included here.

In short, the MIT license below covers the original work in this repo; every external component
keeps its own license and is obtained from upstream.

## Credits and license

by Nexory

Licensed under the MIT License. The original scripts and documentation in this repository only;
see "Third-party components" above.

## Disclaimer

Written for and tested only on the Steam Deck LCD, so it may not apply to the OLED model or other
hardware. Use it at your own risk, and change the `/home/deck` paths to your own username before you
run anything.
