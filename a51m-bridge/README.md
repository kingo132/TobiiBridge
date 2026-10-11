# TobiiBridge for macOS

Native macOS support for the built-in Tobii IS5 Firefly in an Alienware Area-51m R2, developed on top of the Zig TTP/TLV protocol core from [Aetherall/tobiifree](https://github.com/Aetherall/tobiifree).

Current runtime architecture: **Swift/AppKit + Zig + libusb + IOKit**. Node.js and WebAssembly are not required at runtime.

## Tested setup

- Alienware Area-51m R2
- Tobii IS5 Firefly / EyeChip `2104:030E`
- macOS Tahoe 26.7.1, Intel x86_64 Hackintosh
- Zig 0.16.0
- libusb 1.0.30

## Features

- Native gaze streaming (~33 Hz observed on the tested machine)
- 9-point software calibration
- Fixed gaze smoothing
- Gaze-dot overlay with persistent show/hide preference
- Live stream Hz / validity stats
- Sleep/wake recovery and automatic reconnect
- Manual reconnect
- Physical LCD backlight smart dimming through IOKit
- Configurable dim delay: 3 / 5 / 8 / 15 / 30 s
- Configurable target brightness
- Instant or smooth dim/restore transitions
- Persistent settings via UserDefaults
- Icon-only menu-bar status and macOS app icon

## Build inside a tobiifree checkout

Place this `a51m-bridge/` directory in the root of a `tobiifree` checkout/fork:

```text
tobiifree/
├── driver/
├── sdk/
└── a51m-bridge/
```

Install build prerequisites:

```bash
brew install zig libusb
```

Build:

```bash
cd a51m-bridge
./build.sh
```

Run:

```bash
open "$HOME/Applications/TobiiBridge-Native-v1.5.app"
```

The build copies `driver/src/tobiifree_core.zig` and `driver/src/tlv.zig` into the local native build directory, compiles the Zig bridge into a static library, compiles Swift/AppKit, bundles `libusb-1.0.0.dylib`, fixes `@rpath`, and ad-hoc signs the app.

## Brightness probe

Before relying on smart dimming on another machine:

```bash
swiftc -framework IOKit tools/brightness-probe.swift -o /tmp/tobii-brightness-probe
/tmp/tobii-brightness-probe
/tmp/tobii-brightness-probe --test
```

On the tested A51m R2 the physical panel backlight changed successfully and restored to the original value.

## Notes

- The device-specific native transport currently targets VID:PID `2104:030E`.
- USB interface 0, Bulk IN `0x83`, Bulk OUT `0x05`, session open `0x41`, close `0x42` were verified on the tested system.
- The app's 9-point calibration is software-only and does **not** change Tobii firmware calibration.
- Camera / Tobii Hello Sensor access is not implemented.
- The app is experimental and unofficial.

See `docs/` for architecture, test results and the full development history.

## License

GPL-3.0, consistent with the upstream `tobiifree` project. See the repository root `LICENSE` and `NOTICE.md`.
