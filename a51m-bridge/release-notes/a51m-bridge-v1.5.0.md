First public release of TobiiBridge, a native macOS menu-bar app for the built-in Tobii IS5 Firefly (`2104:030E`) eye tracker in the Alienware Area-51m R2.

## Features
- Native gaze streaming over libusb (~33 Hz on the tested machine). No Node.js or WebAssembly needed at runtime.
- 9-point software calibration.
- Gaze-dot overlay and live stream Hz / validity stats.
- Sleep/wake recovery, automatic reconnect and manual reconnect.
- **Smart dimming:** dims the physical LCD backlight through IOKit when you look away. Enable `Physical smart dim` in the menu.
  - Dim delay: 3 / 5 / 8 / 15 / 30 s.
  - Configurable target brightness.
  - Instant or smooth dim and restore transitions.
- Settings are saved between launches.

## Install
1. Download `TobiiBridge-v1.5.0-macOS-x86_64.zip` and unzip it.
2. Move `TobiiBridge-Native-v1.5.app` to `~/Applications`.
3. The app is ad-hoc signed, so remove the download quarantine once:
   `xattr -dr com.apple.quarantine ~/Applications/TobiiBridge-Native-v1.5.app`
4. Open it. It runs in the menu bar.

## Tested on
- Alienware Area-51m R2, macOS Tahoe 26.7.1 (Intel x86_64 Hackintosh). See the [EFI repository](https://github.com/kingo132/a51m-r2-5700m-hackintosh).

The app is experimental and unofficial. Calibration is software-only and does not change the tracker's firmware. Licensed under GPL-3.0 and built on [Aetherall/tobiifree](https://github.com/Aetherall/tobiifree).
