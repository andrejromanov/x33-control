# X33 Control

macOS menu bar app for the **E-Yooso X-33** wireless mouse (Compx chipset;
USB `25a7:fa07` for the 2.4G receiver, `25a7:fa08` when plugged in by cable). E-Yooso ships Windows-only software; this covers the
useful parts on Apple Silicon Macs.

- Battery percentage in the menu bar, voltage and charging state in the menu,
  low-battery notifications at 20 / 10 / 5 %.
- Settings stored in the mouse: polling rate, DPI stages (active stage, value
  per stage, number of stages), lift-off distance, sleep timer, debounce,
  motion sync, angle snapping, ripple control, factory reset.
- Launch at login.
- CLI mode for scripts: `X33Control --battery [--json]`, `--settings`,
  `--dump`, `--set polling 1000`, `--raw 04` (send one frame), `--measure 5`
  (count real mouse reports to check the polling rate). Run it as
  `open -n -a "X33 Control" --args --battery --output /tmp/out.txt`: launching
  through `open` uses the app's own Input Monitoring grant, running the binary
  from a terminal uses the terminal's.

## Build and install

Needs only the Xcode Command Line Tools (`swiftc`), macOS 13+.

```sh
make test      # protocol self-test
make install   # builds ~/Applications/X33 Control.app (ad-hoc signed)
make run       # install + launch
```

`Package.swift` is included for Xcode / `swift build`; the Makefile does not
use it.

## Permission

macOS treats the receiver as a keyboard (its config interface also carries a
keyboard collection), so opening it requires **Input Monitoring**. The app asks
on first launch; grant it under System Settings → Privacy & Security → Input
Monitoring for "X33 Control" only. The app never reads key or mouse events, it
only exchanges vendor reports with the receiver.

With ad-hoc signing every rebuild changes the code hash and macOS forgets the
grant. Run `make cert` once: it creates a self-signed "X33 Control Dev"
code-signing certificate in your login keychain (macOS may ask for your
password to trust it), and `make install` signs with it from then on, so the
permission survives rebuilds.

## Verified on hardware (2026-10-19, X-33 with receiver firmware 0x1312)

- Works over the receiver and over the USB cable (same protocol, different
  product id); the cable is preferred when both are present.
- Battery: command `0x04` answers from the receiver even while the mouse
  sleeps. Byte 6 is the level, byte 7 the charging flag; the voltage bytes are
  always zero on this firmware.
- Flash reads and writes need the mouse awake (move it first). Polling rate,
  active DPI stage, per-stage DPI and stage count round-trip correctly. The
  factory values were 125 Hz and 600/1200/2400/4800/9500 DPI over five stages.
- Not present on this firmware: debounce and sleep timer (bytes read 0xff), the
  version / RSSI / profile queries (status 1). The menu hides what the mouse
  does not have.

## Protocol

Vendor HID collection usage page `0xff02`, 17-byte frames: feature report 8
out, input report 9 back, checksum makes bytes 0…15 sum to `0x55`. Battery is
command `0x04` (reply byte 6 = percent, 7 = charging, 8–9 = millivolts).
Settings live in a flash map read/written with commands `0x08`/`0x07` in
10-byte chunks, each value followed by its own `0x55 - value` checksum. See
`Sources/X33Control/CompxProtocol.swift`. Flash layout follows the Pulsar /
VGN Compx drivers documented by the OpenMouse project; every write is verified
by reading the byte back.
