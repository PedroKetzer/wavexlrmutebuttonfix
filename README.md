# wavexlrmutebuttonfix

## Description

Small scripts for macOS, Linux and Windows that read and restore the capacitive
touch-mute and the LED colors of the original **Elgato Wave XLR** (USB `0FD9:007D`).

Some Wave XLR units end up with the touch-mute switched off in the device's own
configuration. When that happens:

- Tapping the top of the unit does nothing, or works once and then stops.
- The touch sensor itself is fine and still picks up your finger.
- Wave Link has no setting for it, and reinstalling the firmware does not help, because
  the configuration is stored apart from the firmware.

The same unit can also end up with garbage LED colors (a pinkish ring, a mute color that
looks orange, or a ring that just turns off when muted). Wave Link reads those colors
from the device, saves them in its own `config.json`, and pushes them back every time it
starts, so they keep coming back.

The scripts turn touch-mute back on, can unmute the mic, and reset the LED colors. They
talk to the device over the same USB protocol Wave Link uses. On macOS the script also
keeps Wave Link's saved settings in sync.

### How it works

The Wave XLR keeps a 34-byte config block that is read and written with standard
USB Audio Class 1 memory requests on the control interface:

| Operation | bmRequestType | bRequest | wValue | wIndex   | Length |
|-----------|---------------|----------|--------|----------|--------|
| Read      | `0xA1`        | `0x85` (`GET_MEM`) | `0x0000` | `0x3300` | 34 |
| Write     | `0x21`        | `0x05` (`SET_MEM`) | `0x0000` | `0x3300` | 34 |

The bytes this script uses:

| Byte    | Meaning                                                          |
|---------|------------------------------------------------------------------|
| 4       | Mic muted (`0`/`1`)                                              |
| 13      | Mic/PC mix crossover, in percent                                 |
| 15–17   | Mute LED color (RGB)                                             |
| 18–20   | Microphone LED color (RGB)                                       |
| 21–23   | Mix LED color (RGB)                                              |
| 24–26   | Headphone LED color (RGB)                                        |
| 27      | `mute_enabled`: when `0`, the firmware ignores the touch sensor  |
| 29–31   | Clipguard gain-reduction LED color (RGB)                         |

Default colors written by `fix` and `colors`:

| LED       | RGB      | Note                                                              |
|-----------|----------|-------------------------------------------------------------------|
| Ring (mic, mix, headphone) | `fbffef` | Elgato factory white                     |
| Mute      | `ff0000` | Pure red. The factory `ff0006` looks pink on the LED ring         |
| Clipguard | `ff7100` | Elgato factory orange                                             |

The LED ring makes even small channel values clearly visible: `ff0006` shows up pink
and `ff2600` shows up orange. Use pure values (`0` for the unused channels) if you
change the colors.

The protocol comes from Wave Link's own `WaveAPI.framework` (the `LegacyUAC1` backend).
The byte positions were then confirmed on a real unit by watching the block change
while tapping the sensor and while changing settings in Wave Link. Other addresses seen
on the same unit, for reference:

| `wValue` | Content                                                                 |
|----------|-------------------------------------------------------------------------|
| `0x00`   | Live config (the block above)                                           |
| `0x02`   | Fallback config, same layout. Loaded at power-on (see below). Writing it also loads it as the live config |
| `0x01`   | Live status: bytes 0–3 are the raw touch signal (~100 idle, 6,000–10,000 touched), followed by level meters |
| `0x0A`   | Device info: protocol version, firmware commit, serial, then the touch thresholds (lower 900, upper 1500 on the tested unit) |

### Why the fallback block matters

When the Wave XLR powers on it loads the fallback block (`wValue 0x02`), and Wave Link
then pushes its own saved settings on top. Wave Link never sets `mute_enabled`. On the
tested unit the fallback block had touch-mute switched off, which was the original bug:
the button kept coming back disabled.

`fix` and `enable` also turn touch-mute on in the fallback block (and `disable` turns it
off there too), so the button works from power-on, with or without Wave Link.

Observed on the tested unit and not fully explained: before the fallback block was
written, the device sometimes powered on with its last live config instead. After the
write it always powers on with the fallback block.

## Known issue: Wave Link 3.5.0 scrambles the settings

On the tested unit, **Wave Link 3.5.0** wrote garbage to the Wave XLR about 0.1 s after
it connected:

- random LED colors
- crossover at 0
- very low gain
- mic muted

It then saved those values in its `config.json` and pushed them again on every
reconnect. **Wave Link 3.2.2 does not do this**: across several reconnects it only
pushed normal values. 3.4.0 was not tested.

If your colors, gain or mute keep coming back wrong:

1. Run `./wave-xlr-mute.sh fix` to clean up the device and Wave Link's `config.json`.
2. Install Wave Link 3.2.2 from Elgato's CDN:
   `https://edge.elgato.com/egc/macos/ewlm/release/ElgatoWaveLink-3.2.2.2896.dmg`
   (signed and notarized by Corsair Memory, Inc., team `Y93VXCB8Q5`).
3. Keep it from updating itself back to 3.5.0:

   ```sh
   defaults write com.elgato.WaveLink3 SUEnableAutomaticChecks -bool false
   defaults write com.elgato.WaveLink3 SUAutomaticallyUpdate -bool false
   ```

### Why Wave Link has to be closed

Wave Link pushes its own copy of the config to the device when it starts and on
reconnect, and that undoes changes made behind its back. Writes made with Wave Link
closed are stored by the device and survive unplugging.

On macOS, `fix` and `colors` handle this for you:

1. Quit Wave Link.
2. Write the device config.
3. Update the Wave XLR entry in
   `~/Library/Application Support/com.elgato.WaveLink3/config.json` to match.
4. Reopen Wave Link.

`enable` and `disable` only write the device. They warn if Wave Link is running.

On Windows the script refuses to write while Wave Link is running. Close it first. Wave
Link doesn't exist on Linux.

## Installation

All platforms need an original Elgato Wave XLR. The MK.2 uses a different protocol.

```sh
git clone https://github.com/PedroKetzer/wavexlrmutebuttonfix.git
cd wavexlrmutebuttonfix
```

### macOS

Requires [Homebrew](https://brew.sh) and `python3`.

```sh
chmod +x wave-xlr-mute.sh
```

On first run the script installs `libusb` with Homebrew and creates a Python venv with
`pyusb` in `~/.wave-xlr-mute/venv`. No `sudo` is needed.

### Linux

Requires Python 3, `pyusb` and libusb-1.0:

```sh
sudo apt install python3-usb libusb-1.0-0      # Debian/Ubuntu
# or: sudo dnf install python3-pyusb libusb1   # Fedora
```

To run it without `sudo`, add a udev rule and replug the Wave XLR:

```sh
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="0fd9", ATTR{idProduct}=="007d", MODE="0660", TAG+="uaccess"' \
  | sudo tee /etc/udev/rules.d/70-wave-xlr.rules
sudo udevadm control --reload-rules
```

If the kernel rejects the request because `snd-usb-audio` owns the control interface,
the script detaches the driver for a moment and reattaches it. Audio drops for about a
second.

### Windows

Requires Python 3 and [UsbDk](https://github.com/daynix/UsbDk/releases) (reboot after
installing it):

```powershell
py -m pip install pyusb libusb-package
```

Windows has no user-mode API for these requests while the audio driver owns the device.
UsbDk lets libusb take the device over for a moment without replacing any driver. Audio
drops while the script runs and comes back when it exits.

## Usage

| Platform | Command                                  |
|----------|------------------------------------------|
| macOS    | `./wave-xlr-mute.sh <command>`           |
| Linux    | `python3 wave-xlr-mute-linux.py <command>` |
| Windows  | `py wave-xlr-mute-windows.py <command>`  |

Commands (same on all platforms):

```sh
./wave-xlr-mute.sh status    # read only (default)
./wave-xlr-mute.sh fix       # touch-mute on, mic unmuted, default LED colors
./wave-xlr-mute.sh enable    # turn touch-mute on
./wave-xlr-mute.sh disable   # turn touch-mute off
./wave-xlr-mute.sh colors    # reset LED colors and crossover only
```

`fix` and `colors` overwrite any custom LED colors with the defaults above. Pick new
colors in Wave Link afterwards if you want something else.

Example:

```text
$ ./wave-xlr-mute.sh fix
Touch-mute: ENABLED  (byte 27 = 1)
Mic muted:  no  (byte 4 = 0)
LED colors: mute ff2600, mic fbffef, mix fbffef, headphone fbffef, clipguard ff7100; crossover 50%
Quitting Wave Link so it doesn't push its own copy of the config...
Backup: /Users/you/.wave-xlr-mute/backups/cfg-20261114-000015.bin
Device updated:
Touch-mute: ENABLED  (byte 27 = 1)
Mic muted:  no  (byte 4 = 0)
LED colors: mute ff0000, mic fbffef, mix fbffef, headphone fbffef, clipguard ff7100; crossover 50%
Wave Link config updated (backup: /Users/you/.wave-xlr-mute/backups/wavelink-config-20261114-000015.json)
Wave Link reopened.
```

Safety:

- Only the bytes listed above are changed. The rest of the block is written back as read.
- The script refuses to write if the block does not look like the expected layout.
- Before every write, the current block is saved to `~/.wave-xlr-mute/backups/`, and
  Wave Link's `config.json` is copied there before it is edited.
- If the unit shows up as `0FD9:007E`, it is in bootloader mode. Recover the firmware
  with Wave Link first.

To check that the fix stuck, unplug and replug the Wave XLR, then run
`./wave-xlr-mute.sh status`.

### Troubleshooting

- **LED colors change, or the mic comes up muted, after plugging the unit in:** see
  [Known issue: Wave Link 3.5.0 scrambles the settings](#known-issue-wave-link-350-scrambles-the-settings).
- **Mute LED looks orange or pink instead of red:** the mute color has a small green or
  blue component. Run `colors`, or set the mute color to `255, 0, 0` in Wave Link.
- **LED just turns off when muted:** the mute color is black or nearly black. Run
  `colors`.

## Contributing

Issues and merge requests are welcome. Please test on real hardware and include a
before/after dump of the config block (`wValue 0x00`) in the description.

- **macOS script:** works on the tested setup (Wave XLR firmware 1.3.1, Wave Link 3.5.0
  and 3.2.2, macOS 26.7.3 on Apple Silicon).
- **Linux and Windows scripts:** the shared logic was tested against the same unit from
  macOS. The platform-specific parts were not tested on real Linux or Windows machines:
  detaching `snd-usb-audio` on Linux, and UsbDk plus the Wave Link check on Windows.
  Reports are welcome.

The project is not affiliated with or endorsed by Elgato or Corsair. Use at your own
risk.
