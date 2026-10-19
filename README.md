# X33 Control

macOS menu bar app for the **E-Yooso X-33** wireless mouse (Compx chipset;
USB `25a7:fa07` for the 2.4G receiver, `25a7:fa08` when plugged in by cable). E-Yooso ships Windows-only software; this covers the
useful parts on Apple Silicon Macs.

- Battery percentage in the menu bar, voltage and charging state in the menu,
  low-battery notifications at 20 / 10 / 5 %.
- Settings stored in the mouse: polling rate, DPI stages (active stage, value
  per stage, number of stages), lift-off distance, sleep timer, debounce,
  motion sync, angle snapping, ripple control, factory reset.
- Buttons: all 16 slots can be set to a mouse click, DPI loop / up / down,
  scroll in four directions, fire key, polling-rate switch, light switch,
  disabled, a media key, or a keyboard shortcut (⌃ ⌥ ⇧ ⌘ plus one key,
  captured by pressing it in a dialog).
- Lighting: decorative light mode (rainbow wave, breathing, steady, neon, off),
  colour, brightness and speed; DPI indicator light (off, steady, breathing)
  and the colour shown for each DPI stage.
- Launch at login.
- CLI mode for scripts: `X33Control --battery [--json]`, `--settings`,
  `--dump [hex-address] [hex-length]`, `--set polling 1000`,
  `--set button 16 key cmd+shift+a`, `--set button 15 media playpause`,
  `--set button 6 fire 20 3`, `--set light steady 00ff00 128 50`,
  `--set dpilight breathing`, `--set dpicolor 1 ff8000`, `--raw 04` (send one
  frame), `--measure 5` (count real mouse reports to check the polling rate).
  Run it as
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

The app icon is `Packaging/icon.svg`. `Packaging/AppIcon.icns` is committed, so a
normal build needs nothing extra; after editing the SVG run `make icon`, which
needs `rsvg-convert` (`brew install librsvg`) and the system `iconutil`.

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

## Buttons

The mouse keeps a table of 16 button slots. Which physical button is which
slot was read from the factory layout of the X-33 (the menu names slots by
that layout):

| Slot | Factory function | Slot | Factory function |
|------|------------------|------|------------------|
| 1 | side, ⌃↑ | 9 | side, key 7 |
| 2 | side, ⌃← | 10 | side, key 8 |
| 3 | side, ⌃→ | 11 | middle button |
| 4 | side, Back | 12 | top button, fire key (3 clicks every 20 ms) |
| 5 | side, Forward | 13 | side, key 9 |
| 6 | side, key 6 | 14 | side, key 0 |
| 7 | right button | 15 | side, keypad + |
| 8 | left button | 16 | side, keypad − |

To identify a side button, press it in a text editor and compare with the
current assignment shown in the Buttons menu. At least one slot must stay
Left Click; the app refuses to remove the last one, as the vendor software
does. Macros (flash 0x300) are not implemented.

## Lighting

The light block was written and read back on the X-33, but the mouse was
not watched while doing it. Mode numbers (0 rainbow wave, 1 breathing,
2 steady, 3 neon, 4 off) come from the Redragon M711 Pro, which uses the same
vendor id and the same 7-byte light record with the same factory defaults. If
a mode shows a different effect on your mouse, the names in
`LightSettings.Mode` are the only thing to change. The factory state of the
X-33 is "off" (mode 4, state 0), so nothing lights up until you pick a mode.

## Verified on hardware (2026-10-19/20, X-33 with receiver firmware 0x1312)

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
- Button table and shortcut slots: a keyboard shortcut (⌘C) written to slot 16
  came back byte for byte and the slot was restored to its factory keypad −;
  the light record round-trips the same way. Flash reads answer status 1
  unless host control (command 0x03) is active.

## Protocol

Vendor HID collection usage page `0xff02`, 17-byte frames: feature report 8
out, input report 9 back, checksum makes bytes 0…15 sum to `0x55`. Battery is
command `0x04` (reply byte 6 = percent, 7 = charging, 8–9 = millivolts).
Settings live in a flash map read/written with commands `0x08`/`0x07` in
10-byte chunks, each value followed by its own `0x55 - value` checksum. See
`Sources/X33Control/CompxProtocol.swift` and `ButtonMapping.swift`. The flash
layout follows Compx's own web driver ("Control Hub": `KeyFunction` 0x60,
`ShortcutKey` 0x100, `Light` 0xa0, `DPIColor` 0x2c, `DPIEffect` 0x4c) and the
open-m711pro and OpenMouse projects; every write is verified by reading the
bytes back. A button record is `[type, param hi, param lo, checksum]`; a
shortcut slot is an event list `[2n, (kind|0x80, lo, hi)×n, (kind|0x40, lo,
hi)×n, checksum]` with kind 0 = modifier bitmask, 1 = keyboard usage,
2 = consumer usage.
