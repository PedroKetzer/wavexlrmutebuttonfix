#!/usr/bin/env python3
"""Read / fix the capacitive touch-mute and LED colors of an Elgato Wave XLR on Linux
(original model, USB 0FD9:007D).

The Wave XLR keeps a 34-byte config block that is read and written with the USB Audio
class requests GET_MEM (0x85) and SET_MEM (0x05), wIndex=0x3300. wValue 0x00 is the live
config and wValue 0x02 the block the device loads at power-on (fallback block).

Usage:
    python3 wave-xlr-mute-linux.py status    # read only (default)
    python3 wave-xlr-mute-linux.py fix       # touch-mute on, mic unmuted, default LED colors
    python3 wave-xlr-mute-linux.py enable    # turn touch-mute on
    python3 wave-xlr-mute-linux.py disable   # turn touch-mute off
    python3 wave-xlr-mute-linux.py colors    # reset LED colors and crossover only

Requirements: Python 3, pyusb (`pip install pyusb`) and libusb-1.0 (`libusb-1.0-0` on
Debian/Ubuntu, `libusb1` on Fedora/Arch). Run as root, or install the udev rule from the
README to use it as a regular user.

The snd-usb-audio driver owns the audio control interface. If the kernel refuses the
request because of that, the script briefly detaches the driver from the device and
reattaches it afterwards. Audio drops for about a second while that happens.

Every write first saves the current block to ~/.wave-xlr-mute/backups/.
"""
import array
import errno
import os
import sys
import time

try:
    import usb.backend.libusb1
    import usb.core
    import usb.util
except ImportError:
    sys.exit("pyusb is missing. Install it with: pip install pyusb")

VID, PID, PID_BOOTLOADER = 0x0FD9, 0x007D, 0x007E
N = 34
LIVE, FALLBACK = 0x00, 0x02
CTRL_INTERFACE = 0

MUTED = 4
CROSSOVER = 13
MUTE_COLOR, MIC_COLOR, MIX_COLOR, HEADPHONE_COLOR = 15, 18, 21, 24
MUTE_ENABLED = 27
CLIPGUARD_COLOR = 29

RING = (0xFB, 0xFF, 0xEF)
DEFAULT_COLORS = {
    MUTE_COLOR: (0xFF, 0x00, 0x00),
    MIC_COLOR: RING,
    MIX_COLOR: RING,
    HEADPHONE_COLOR: RING,
    CLIPGUARD_COLOR: (0xFF, 0x71, 0x00),
}
DEFAULT_CROSSOVER = 50

BACKUPS = os.path.join(os.environ.get("WAVE_XLR_MUTE_HOME", os.path.expanduser("~/.wave-xlr-mute")), "backups")
COMMANDS = ("status", "enable", "disable", "fix", "colors")


def stamp():
    return time.strftime("%Y%m%d-%H%M%S")


class WaveXLR:
    """Opens the device and issues GET_MEM / SET_MEM on the audio control interface."""

    def __init__(self):
        lib = os.environ.get("WAVE_XLR_LIBUSB")
        self.be = usb.backend.libusb1.get_backend(find_library=(lambda _: lib) if lib else None)
        if self.be is None:
            sys.exit("libusb-1.0 not found. Install libusb-1.0-0 (Debian/Ubuntu) or libusb1 (Fedora/Arch).")
        self.dev = usb.core.find(idVendor=VID, idProduct=PID, backend=self.be)
        if self.dev is None:
            if usb.core.find(idVendor=VID, idProduct=PID_BOOTLOADER, backend=self.be) is not None:
                sys.exit("Wave XLR is in bootloader mode (0FD9:007E). Recover the firmware with Wave Link first.")
            sys.exit("Wave XLR (0FD9:007D) not found.")
        try:
            self.dev._ctx.managed_open()
        except usb.core.USBError as e:
            if e.errno in (errno.EACCES, errno.EPERM):
                sys.exit("Permission denied. Run with sudo, or install the udev rule from the README.")
            raise
        self.handle = self.dev._ctx.handle
        self.detached = False
        self.claimed = False

    def _take_interface(self):
        """Fallback when the kernel rejects the request: detach snd-usb-audio and claim."""
        if sys.platform.startswith("linux") and self.dev.is_kernel_driver_active(CTRL_INTERFACE):
            print("Detaching snd-usb-audio for a moment (audio will drop briefly)...")
            self.dev.detach_kernel_driver(CTRL_INTERFACE)
            self.detached = True
        usb.util.claim_interface(self.dev, CTRL_INTERFACE)
        self.claimed = True

    def _ctrl(self, bm, req, value, data_or_len):
        buf = array.array("B", bytes(data_or_len) if isinstance(data_or_len, int) else data_or_len)
        try:
            n = self.be.ctrl_transfer(self.handle, bm, req, value, 0x3300, buf, 500)
        except usb.core.USBError as e:
            if self.claimed or e.errno not in (errno.EBUSY, errno.EACCES, errno.EPERM, errno.ENOENT, errno.EIO, None):
                raise
            self._take_interface()
            n = self.be.ctrl_transfer(self.handle, bm, req, value, 0x3300, buf, 500)
        return bytes(buf[:n])

    def get(self, addr=LIVE):
        cfg = self._ctrl(0xA1, 0x85, addr, N)
        if len(cfg) != N or cfg[MUTE_ENABLED] not in (0, 1) or cfg[MUTED] not in (0, 1):
            sys.exit(f"Unexpected config layout at 0x{addr:02x}, refusing to touch it: {cfg.hex(' ')}")
        return cfg

    def put(self, data, addr=LIVE):
        self._ctrl(0x21, 0x05, addr, data)

    def close(self):
        if self.claimed:
            usb.util.release_interface(self.dev, CTRL_INTERFACE)
        if self.detached:
            try:
                self.dev.attach_kernel_driver(CTRL_INTERFACE)
            except usb.core.USBError as e:
                print(f"Could not reattach snd-usb-audio ({e}). Unplug and replug the Wave XLR.")
        usb.util.dispose_resources(self.dev)


def rgb(c, off):
    return c[off:off + 3].hex()


def show(x, c):
    fb = x.get(FALLBACK)
    print(f"Touch-mute: {'ENABLED' if c[MUTE_ENABLED] else 'DISABLED'}  (byte 27 = {c[MUTE_ENABLED]}; "
          f"fallback block: {'on' if fb[MUTE_ENABLED] else 'off'})")
    print(f"Mic muted:  {'yes' if c[MUTED] else 'no'}  (byte 4 = {c[MUTED]})")
    print(f"LED colors: mute {rgb(c, MUTE_COLOR)}, mic {rgb(c, MIC_COLOR)}, mix {rgb(c, MIX_COLOR)}, "
          f"headphone {rgb(c, HEADPHONE_COLOR)}, clipguard {rgb(c, CLIPGUARD_COLOR)}; crossover {c[CROSSOVER]}%")


def target_bytes(cmd):
    t = {}
    if cmd in ("enable", "fix"):
        t[MUTE_ENABLED] = 1
    if cmd == "disable":
        t[MUTE_ENABLED] = 0
    if cmd == "fix":
        t[MUTED] = 0
    if cmd in ("fix", "colors"):
        for off, color in DEFAULT_COLORS.items():
            for i, v in enumerate(color):
                t[off + i] = v
        t[CROSSOVER] = DEFAULT_CROSSOVER
    return t


def backup(name, data):
    os.makedirs(BACKUPS, exist_ok=True)
    path = os.path.join(BACKUPS, f"{name}-{stamp()}.bin")
    with open(path, "wb") as f:
        f.write(data)
    return path


def run(cmd):
    x = WaveXLR()
    try:
        cfg = x.get()
        show(x, cfg)
        if cmd == "status":
            return
        target = target_bytes(cmd)

        if MUTE_ENABLED in target:
            fb = x.get(FALLBACK)
            if fb[MUTE_ENABLED] != target[MUTE_ENABLED]:
                path = backup("fallback", fb)
                new = bytearray(fb)
                new[MUTE_ENABLED] = target[MUTE_ENABLED]
                x.put(bytes(new), FALLBACK)  # also loads the block as the live config
                time.sleep(0.5)
                if x.get(FALLBACK)[MUTE_ENABLED] != target[MUTE_ENABLED]:
                    sys.exit("Fallback block write did not stick.")
                print(f"Fallback block updated (backup: {path})")
                x.put(cfg)  # put the live config back
                time.sleep(0.3)

        changes = {i: v for i, v in target.items() if cfg[i] != v}
        if not changes:
            print("Device already matches.")
            return
        print(f"Backup: {backup('cfg', cfg)}")
        new = bytearray(cfg)
        for i, v in changes.items():
            new[i] = v
        x.put(bytes(new))
        time.sleep(0.3)
        after = x.get()
        if any(after[i] != v for i, v in changes.items()):
            sys.exit(f"Write did not stick: {after.hex(' ')}")
        print("Device updated:")
        show(x, after)
    finally:
        x.close()


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd in ("-h", "--help", "help"):
        print(__doc__)
        return
    if cmd not in COMMANDS:
        sys.exit(f"Usage: {sys.argv[0]} [{'|'.join(COMMANDS)}]")
    run(cmd)


if __name__ == "__main__":
    main()
