# Steam Deck LCD: speakers and microphone on Debian 13

Getting sound out of a Steam Deck LCD (and the internal mic in) after installing a generic
Linux distribution instead of SteamOS. Written and tested on Debian 13 (trixie).

Home directory paths in this repository are written as `/home/deck`. Adjust them to your
own username. The two scripts here need no fixed location at all, put them anywhere, for
example `/home/deck/steamdeck-debian-fixes/audio/`, and run them from there.

## Symptom

You install Debian on the Deck, everything else works, and:

* the speakers stay completely silent, at any volume, although a card shows up in
  `aplay -l` and the mixer looks perfectly normal,
* headphones on the 3.5 mm jack may well work while the internal speakers do not,
* the internal microphone records nothing, or `arecord` produces a file that is pure
  silence,
* PipeWire either shows no usable sink/source at all, or shows one that plays into
  the void.

Nothing here is broken hardware. Two pieces of software are missing.

## What is actually missing

**1. CS35L41 amplifier firmware.**
The Deck does not drive its speakers from a plain codec line-out. Each speaker sits behind
a Cirrus Logic CS35L41 "smart amp" that contains its own DSP. That DSP needs a firmware
blob (speaker protection and tuning) which the kernel driver loads from
`/lib/firmware/cirrus/` when it probes the device. SteamOS ships those blobs. A stock
Debian install does not, so the driver comes up, the card enumerates, the mixer controls
exist, and absolutely no sound reaches the speakers.

On Debian the blobs come from the package **`firmware-cirrus`**, which lives in the
`non-free-firmware` component.

**2. ALSA UCM configuration.**
The Deck's audio complex is not a single simple codec. It is an AMD ACP I2S block plus the
codec plus the two CS35L41 amps, and the routing between them is not discoverable. ALSA
Use Case Manager (UCM) profiles describe which PCM device is the speaker path, which is the
capture path, and which mixer switches have to be flipped to make either of them audible.
PipeWire/WirePlumber reads exactly those profiles to build its sinks and sources.

Without a matching UCM profile you get raw PCM devices with no sensible default routing,
which is why `wpctl status` can look empty or wrong even after the firmware is in place.
On Debian these profiles come from the package **`alsa-ucm-conf`** and are installed under
`/usr/share/alsa/ucm2/`.

Both parts have to be in place. Firmware alone gives you a silent amp with correct-looking
mixers; UCM alone gives you correct routing into an amp that never got its DSP code.

## Procedure

Steps 1 and 4 are what the two scripts in this directory automate. The rest is the context
around them.

### 1. Install the amplifier firmware

```bash
sudo bash speaker-firmware.sh
```

What the script does, and nothing else:

1. `apt-get update`
2. `apt-get install -y firmware-cirrus`
3. lists the `cs35l41*` files that are now in `/lib/firmware/cirrus/`
4. prints that a reboot is required

If apt cannot find the package, your sources are missing the `non-free-firmware`
component. Add it, for example in `/etc/apt/sources.list`:

```
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
```

then `sudo apt-get update` and run the script again.

### 2. Reboot

```bash
sudo reboot
```

This is not optional. The CS35L41 driver only requests its firmware while probing the
device, so a blob that lands on disk after the driver came up is simply not used. A reboot
is the simplest way to get a clean probe.

### 3. Verify that the firmware was actually loaded

```bash
sudo dmesg | grep -i cs35l41
```

Lines like `Direct firmware load for cirrus/cs35l41-dsp1-... failed` mean the driver asked
for a file name that is not present. Compare the requested name against what you have:

```bash
ls -l /lib/firmware/cirrus/ | grep -i cs35l41
```

### 4. Make sure ALSA UCM is installed

```bash
sudo apt-get install --reinstall alsa-ucm-conf alsa-utils
ls /usr/share/alsa/ucm2/
ls /usr/share/alsa/ucm2/conf.d/
```

Then find out what your kernel actually calls the card, and whether a UCM profile matches
it:

```bash
cat /proc/asound/cards
aplay -l
arecord -l
alsaucm -c <card-name-from-proc-asound-cards> list _verbs
```

If `alsaucm` lists verbs (for example `HiFi`), a profile was found and PipeWire can use it.
If it errors out with no matching configuration, the `alsa-ucm-conf` version you have does
not know this machine yet. In that case get a newer `alsa-ucm-conf` (backport, or the
upstream `alsa-project/alsa-ucm-conf` tree copied into `/usr/share/alsa/ucm2/`) rather than
hand-writing mixer scripts.

### 5. Restart the sound server

UCM profiles are read when the session audio stack starts, so a fresh install of
`alsa-ucm-conf` does nothing until PipeWire and WirePlumber restart. As your normal
desktop user, **not** with sudo:

```bash
systemctl --user restart pipewire pipewire-pulse wireplumber
wpctl status
```

Over a plain SSH login the user bus may not be reachable. Export the runtime directory
first if `systemctl --user` complains:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
```

### 6. Test

```bash
bash audiotest.sh
```

See the next section for what it checks and how to test by hand.

## Testing

### Straight through ALSA, bypassing the sound server

```bash
aplay -l                                   # playback devices
arecord -l                                 # capture devices
speaker-test -D plughw:1,1 -c 2 -t sine -f 440 -l 1
aplay -D plughw:1,1 /usr/share/sounds/alsa/Front_Center.wav
arecord -D plughw:1,0 -f S16_LE -r 16000 -c 1 -d 3 /tmp/mic_test.wav
aplay -D plughw:1,1 /tmp/mic_test.wav
```

The usual Deck layout is `plughw:1,0` for capture and `plughw:1,1` for playback, but the
card index depends on what else is loaded, so read it out of `aplay -l` instead of
trusting the 1.

### Through PipeWire

```bash
wpctl status                               # are there sinks and sources at all
pw-play /usr/share/sounds/alsa/Front_Center.wav
pw-record /tmp/pw_mic_test.wav             # Ctrl+C to stop
pw-play /tmp/pw_mic_test.wav
pactl list short sinks
pactl list short sources
```

If the ALSA level works and the PipeWire level does not, the problem is UCM or the sound
server session, not the firmware.

### What `audiotest.sh` does

```bash
bash audiotest.sh
MIC_DEV=plughw:2,0 SPK_DEV=plughw:2,1 bash audiotest.sh    # override the devices
```

1. prints the playback and capture cards ALSA sees
2. plays `/usr/share/sounds/alsa/Front_Center.wav` on `$SPK_DEV`, and on a fallback device
   if that is silent or errors out; if the WAV file is missing it falls back to a
   `speaker-test` sine tone
3. records `$REC_SECONDS` (default 3) seconds of mono 16 kHz audio from `$MIC_DEV`, plays
   it back, and prints a peak/RMS readout if `sox` is installed
4. prints the PipeWire commands to run next

Environment variables it honours: `MIC_DEV`, `SPK_DEV`, `SPK_FALLBACK`, `TEST_WAV`,
`REC_WAV`, `REC_SECONDS`.

## Troubleshooting

**`ls /lib/firmware/cirrus/ | grep cs35l41` comes back empty after the install.**
The distribution package is too old or does not carry these blobs. Take the files from the
upstream `linux-firmware` tree instead and drop them into `/lib/firmware/cirrus/`, then
reboot and check `dmesg` again for the exact file name the driver requested.

**`dmesg` shows a firmware name that does not exist on disk.**
The driver builds the file name from the machine identifiers, so the name is specific to
the board. Match what it asks for; do not rename an unrelated blob into place.

**`aplay` or `arecord` reports "Device or resource busy".**
PipeWire is holding the device, and `plughw:` talks to the hardware directly. Either test
through the server with `pw-play` / `pw-record`, or stop the user services for the moment:

```bash
systemctl --user stop pipewire pipewire-pulse wireplumber
```

**Everything reports success, still nothing audible.**
Check the mixer for a muted or zeroed control on the right card:

```bash
alsamixer -c 1        # M unmutes, arrow keys set the level
amixer -c 1 scontrols
```

Also check the levels in `wpctl status` and unmute the default sink there.

**`wpctl status` shows no sink or source.**
That is the UCM side, not the firmware side. Go back to step 4, confirm
`alsaucm -c <card> list _verbs` returns something, then restart WirePlumber.

**The microphone records pure silence but no error.**
Confirm you are on the capture device that belongs to the internal mic (`arecord -l`), and
check the capture switches in `alsamixer -c 1` (press F4 for the capture view, space to
enable a source).

## Files in this directory

| File | Purpose |
| --- | --- |
| `speaker-firmware.sh` | Installs `firmware-cirrus`, lists the resulting cs35l41 blobs, tells you to reboot. Run with sudo. |
| `audiotest.sh` | Speaker and microphone check through ALSA, plus the PipeWire commands to try next. Run as your normal user. |

Notes on the scripts:

* the speaker test plays the standard `/usr/share/sounds/alsa/Front_Center.wav` from
  `alsa-utils`, or a `speaker-test` tone as fallback, so it has no dependencies beyond
  `alsa-utils`,
* be careful piping a command whose result you check into `tail`: a pipeline reports the
  status of its last element, so the check reads `tail`'s exit status, not the command's.
  These scripts capture the output first and then test the real status, so the
  "no firmware found" and "fallback device" branches actually trigger.

## Author

Nexory
