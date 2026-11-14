#!/bin/bash
# Read / fix the capacitive touch-mute and LED colors of an Elgato Wave XLR
# (original model, USB 0FD9:007D).
#
# The Wave XLR keeps a 34-byte config block that is read and written with the
# USB Audio class requests GET_MEM (0x85) and SET_MEM (0x05), wValue=0, wIndex=0x3300.
# This is the same protocol Wave Link uses (WaveAPI, "LegacyUAC1" backend).
#
# Usage:
#   ./wave-xlr-mute.sh status    # read only (default)
#   ./wave-xlr-mute.sh fix       # touch-mute on, mic unmuted, default LED colors
#   ./wave-xlr-mute.sh enable    # turn touch-mute on
#   ./wave-xlr-mute.sh disable   # turn touch-mute off
#   ./wave-xlr-mute.sh colors    # reset LED colors (device and Wave Link) to defaults
#
# Wave Link pushes its own copy of the config (including LED colors) to the device
# when it starts, so `fix` and `colors` quit Wave Link, write the device, update
# Wave Link's config.json to match, and reopen Wave Link. Every write first saves
# the current state to ~/.wave-xlr-mute/backups/.

set -eo pipefail

CMD="${1:-status}"
case "$CMD" in
  status|enable|disable|fix|colors) ;;
  -h|--help|help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Usage: $0 [status|fix|enable|disable|colors]"; exit 2 ;;
esac

STATE_DIR="${WAVE_XLR_MUTE_HOME:-$HOME/.wave-xlr-mute}"
VENV="$STATE_DIR/venv"
BACKUPS="$STATE_DIR/backups"
WAVE_LINK_CONFIG="$HOME/Library/Application Support/com.elgato.WaveLink3/config.json"

if ! command -v brew >/dev/null; then
  echo "Homebrew is required (https://brew.sh)."; exit 1
fi
LIBUSB="$(brew --prefix libusb 2>/dev/null)/lib/libusb-1.0.dylib"
if [ ! -f "$LIBUSB" ]; then
  echo "==> Installing libusb..."
  brew install libusb >/dev/null
  LIBUSB="$(brew --prefix libusb)/lib/libusb-1.0.dylib"
fi
if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -I -c "import usb" 2>/dev/null; then
  echo "==> Creating Python venv with pyusb in $VENV..."
  mkdir -p "$STATE_DIR"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check pyusb
fi

WAVE_LINK_APP=""
for p in "$HOME/Applications/Elgato Wave Link.app" "/Applications/Elgato Wave Link.app"; do
  [ -d "$p" ] && WAVE_LINK_APP="$p" && break
done

cd /tmp
exec "$VENV/bin/python" -I - "$CMD" "$LIBUSB" "$BACKUPS" "$WAVE_LINK_APP" "$WAVE_LINK_CONFIG" <<'PY'
import array
import json
import os
import shutil
import subprocess
import sys
import time

import usb.backend.libusb1
import usb.core

cmd, libusb_path, backups, wave_link_app, wave_link_config = sys.argv[1:6]
VID, PID, PID_BOOTLOADER = 0x0FD9, 0x007D, 0x007E
N = 34

# Config block layout (offsets confirmed on a real unit against Wave Link's settings).
MUTED = 4                 # mic muted, 0/1
CROSSOVER = 13            # mic/PC mix crossover, percent
MUTE_COLOR = 15           # 3 bytes RGB
MIC_COLOR = 18            # 3 bytes RGB
MIX_COLOR = 21            # 3 bytes RGB
HEADPHONE_COLOR = 24      # 3 bytes RGB
MUTE_ENABLED = 27         # touch-mute enabled, 0/1
CLIPGUARD_COLOR = 29      # 3 bytes RGB

# Default LED colors: Elgato's factory ring white and Clipguard orange, but pure red
# for mute (the factory ff0006 shows up pink on the LED ring).
RING = (0xFB, 0xFF, 0xEF)
DEFAULT_COLORS = {
    MUTE_COLOR: (0xFF, 0x00, 0x00),
    MIC_COLOR: RING,
    MIX_COLOR: RING,
    HEADPHONE_COLOR: RING,
    CLIPGUARD_COLOR: (0xFF, 0x71, 0x00),
}
DEFAULT_CROSSOVER = 50
WAVE_LINK_COLOR_KEYS = {
    MUTE_COLOR: "mute",
    MIC_COLOR: "microphone",
    MIX_COLOR: "mix",
    HEADPHONE_COLOR: "headphone",
    CLIPGUARD_COLOR: "clipGuardGainReduction",
}

be = usb.backend.libusb1.get_backend(find_library=lambda _: libusb_path)
dev = usb.core.find(idVendor=VID, idProduct=PID, backend=be)
if dev is None:
    if usb.core.find(idVendor=VID, idProduct=PID_BOOTLOADER, backend=be) is not None:
        sys.exit("Wave XLR is in bootloader mode (0FD9:007E). Recover the firmware with Wave Link first.")
    sys.exit("Wave XLR (0FD9:007D) not found.")

# Open the device without claiming interface 0 (owned by the macOS audio driver).
# Control transfers on macOS don't need the claim.
dev._ctx.managed_open()
h = dev._ctx.handle


LIVE, FALLBACK = 0x00, 0x02   # GET_MEM/SET_MEM wValue of the live and fallback blocks


def get_cfg(addr=LIVE):
    buf = array.array("B", bytes(N))
    n = be.ctrl_transfer(h, 0xA1, 0x85, addr, 0x3300, buf, 500)
    cfg = bytes(buf[:n])
    if len(cfg) != N or cfg[MUTE_ENABLED] not in (0, 1) or cfg[MUTED] not in (0, 1):
        sys.exit(f"Unexpected config layout at 0x{addr:02x}, refusing to touch it: {cfg.hex(' ')}")
    return cfg


def put_cfg(data, addr=LIVE):
    return be.ctrl_transfer(h, 0x21, 0x05, addr, 0x3300, array.array("B", data), 500)


def ensure_fallback_touch_mute(want):
    """The device falls back to block 0x02 when its saved config is corrupted.
    Make sure that block has the same touch-mute setting, so the button survives."""
    fb = get_cfg(FALLBACK)
    if fb[MUTE_ENABLED] == want:
        return False
    os.makedirs(backups, exist_ok=True)
    path = os.path.join(backups, f"fallback-{stamp()}.bin")
    with open(path, "wb") as f:
        f.write(fb)
    new = bytearray(fb)
    new[MUTE_ENABLED] = want
    put_cfg(bytes(new), FALLBACK)  # note: this also loads the block as the live config
    time.sleep(0.5)
    if get_cfg(FALLBACK)[MUTE_ENABLED] != want:
        sys.exit("Fallback block write did not stick.")
    print(f"Fallback block updated: touch-mute {'on' if want else 'off'} (backup: {path})")
    return True


def rgb(c, off):
    return c[off:off + 3].hex()


def show(c):
    fb = get_cfg(FALLBACK)
    print(f"Touch-mute: {'ENABLED' if c[MUTE_ENABLED] else 'DISABLED'}  (byte 27 = {c[MUTE_ENABLED]}; "
          f"fallback block: {'on' if fb[MUTE_ENABLED] else 'off'})")
    print(f"Mic muted:  {'yes' if c[MUTED] else 'no'}  (byte 4 = {c[MUTED]})")
    print(f"LED colors: mute {rgb(c, MUTE_COLOR)}, mic {rgb(c, MIC_COLOR)}, mix {rgb(c, MIX_COLOR)}, "
          f"headphone {rgb(c, HEADPHONE_COLOR)}, clipguard {rgb(c, CLIPGUARD_COLOR)}; crossover {c[CROSSOVER]}%")


def wave_link_running():
    return subprocess.run(["pgrep", "-x", "WaveLinkMacOS"], capture_output=True).returncode == 0


def quit_wave_link():
    print("Quitting Wave Link so it doesn't push its own copy of the config...")
    subprocess.run(["osascript", "-e", 'tell application "Elgato Wave Link" to quit'], capture_output=True)
    for _ in range(20):
        if not wave_link_running():
            time.sleep(1)  # the device falls back to its stored config
            return
        time.sleep(0.5)
    sys.exit("Wave Link did not quit. Quit it manually and run this again.")


def stamp():
    return time.strftime("%Y%m%d-%H%M%S")


def target_bytes(command):
    t = {}
    if command in ("enable", "fix"):
        t[MUTE_ENABLED] = 1
    if command == "disable":
        t[MUTE_ENABLED] = 0
    if command == "fix":
        t[MUTED] = 0
    if command in ("fix", "colors"):
        for off, color in DEFAULT_COLORS.items():
            for i, v in enumerate(color):
                t[off + i] = v
        t[CROSSOVER] = DEFAULT_CROSSOVER
    return t


def update_wave_link_config():
    """Make Wave Link's saved LED colors match, so it doesn't push old ones on start."""
    if not os.path.isfile(wave_link_config):
        return
    with open(wave_link_config) as f:
        data = json.load(f)
    changed = False
    for d in data.get("devices", []):
        if d.get("kind", {}).get("value") != "waveXLR":
            continue
        feats = d.setdefault("features", {})
        colors = feats.setdefault("xlrLedColors", {})
        for off, key in WAVE_LINK_COLOR_KEYS.items():
            r, g, b = DEFAULT_COLORS[off]
            if colors.get(key) != {"red": r, "green": g, "blue": b}:
                colors[key] = {"red": r, "green": g, "blue": b}
                changed = True
        pct = feats.get("crossover", {}).get("percentage")
        if pct is not None and pct.get("value") != DEFAULT_CROSSOVER:
            pct["value"] = DEFAULT_CROSSOVER
            changed = True
        if cmd == "fix":
            # Wave Link re-applies its saved mic mute state on start.
            for inp in d.get("audioInputs", []):
                if inp.get("mute"):
                    inp["mute"] = False
                    changed = True
    if not changed:
        print("Wave Link config already matches.")
        return
    os.makedirs(backups, exist_ok=True)
    bk = os.path.join(backups, f"wavelink-config-{stamp()}.json")
    shutil.copy2(wave_link_config, bk)
    with open(wave_link_config, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Wave Link config updated (backup: {bk})")


cfg = get_cfg()
show(cfg)
if cmd == "status":
    sys.exit(0)

target = target_bytes(cmd)
touches_wave_link = cmd in ("fix", "colors")
reopen = False

if wave_link_running():
    if touches_wave_link:
        quit_wave_link()
        reopen = bool(wave_link_app)
        cfg = get_cfg()
    else:
        print("Warning: Wave Link is running and may undo this. Use `fix`, or quit Wave Link first.")

if MUTE_ENABLED in target and ensure_fallback_touch_mute(target[MUTE_ENABLED]):
    put_cfg(cfg)  # writing the fallback block replaced the live config; put it back
    time.sleep(0.3)

changes = {i: v for i, v in target.items() if cfg[i] != v}
if changes:
    os.makedirs(backups, exist_ok=True)
    path = os.path.join(backups, f"cfg-{stamp()}.bin")
    with open(path, "wb") as f:
        f.write(cfg)
    print(f"Backup: {path}")
    new = bytearray(cfg)
    for i, v in changes.items():
        new[i] = v
    put_cfg(bytes(new))
    time.sleep(0.3)
    after = get_cfg()
    if any(after[i] != v for i, v in changes.items()):
        sys.exit(f"Write did not stick: {after.hex(' ')}")
    print("Device updated:")
    show(after)
else:
    print("Device already matches.")

if touches_wave_link:
    update_wave_link_config()

if reopen:
    time.sleep(2)  # give the firmware time to store the config
    subprocess.run(["open", "-a", wave_link_app])
    print("Wave Link reopened.")
PY
