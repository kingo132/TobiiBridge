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
- V1.6.1: gaze dot and calibration stay on the built-in panel with external displays connected
- Live stream Hz / validity stats
- Sleep/wake recovery and automatic reconnect
- Manual reconnect
- Physical LCD backlight smart dimming through IOKit
- Configurable dim delay: 3 / 5 / 8 / 15 / 30 s
- Configurable target brightness
- Instant or smooth dim/restore transitions
- Persistent settings via UserDefaults
- V1.6.2: smart dim remains enabled across temporary backlight failures and login;
  unavailable brightness control is retried every five seconds without clearing the preference
- V1.6.3: accepts valid zero brightness and uses the framebuffer to resolve the
  current display object after connection replacement
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
open "$HOME/Applications/TobiiBridge-Native-v1.6.3.app"
```

The build copies `driver/src/tobiifree_core.zig` and `driver/src/tlv.zig` into the local native build directory, compiles the Zig bridge into a static library, compiles Swift/AppKit, bundles `libusb-1.0.0.dylib`, fixes `@rpath`, and ad-hoc signs the app.

Set `TOBIIBRIDGE_APP_PATH` to use another output path. Existing bundles are never overwritten by the build script.

## External displays (V1.6.1)

The transparent drawing surface is explicitly cleared before each frame and uses a layer-backed view. A smaller copy of the gaze dot inside an application's live window thumbnail is a preview of the overlay, not a second tracking point.

This bridge targets the **integrated** Area-51m IS5. Its tracking area is the built-in panel. Gaze dots and all nine calibration targets use the same overlay on that panel, regardless of which display is primary or contains the focused window. Connecting an external display does not move the tracking area.

The app resolves the panel with `CGDisplayIsBuiltin`, uses its full AppKit frame (including negative origins), and updates that frame when display configuration changes or the machine wakes. If no drawable built-in panel is available, it hides the overlay, disables calibration and suspends smart dimming. It never falls back to an external display. OS display mirroring may duplicate content on both physical panels; independently tracking the mirrored external panel is not supported.

If the target panel or its geometry changes during calibration, the unfinished calibration is cancelled. A new calibration records the panel UUID, and a calibration for another panel is not applied. Existing V1.5 calibration files remain compatible with the built-in tracker and are left untouched until the user explicitly saves or resets calibration. If a prior calibration was performed on the wrong screen, rerun it on the built-in panel.

This follows Tobii's documented display assignment rule: gaze is tracked only on the screen where the tracker is mounted and configured. Tobii's selectable display setup is explicitly for **non-integrated** trackers. The bridge's existing nine-point software calibration remains separate from Windows/Tobii firmware calibration; this update aligns display routing, not the Windows calibration algorithm.

References: [Multiple screens](https://help.tobii.com/hc/en-us/articles/209529429-Can-I-use-multiple-screens), [Display setup](https://help.tobii.com/hc/en-us/articles/360003101733-How-to-do-a-display-setup).

Run the routing regression checks on macOS:

```bash
swiftc DisplayRouting.swift tools/display-routing-tests.swift -o /tmp/tobii-display-tests
/tmp/tobii-display-tests
```

## Brightness probe

V1.6.2 keeps the smart-dim checkmark as the user's saved choice. Missing or
unreadable brightness control, failed writes, and failed fades suspend dimming
without changing that choice. The app retries discovery every five seconds and
waits for fresh gaze before resuming. Only the menu toggle changes the saved
enabled preference.

Hardware errors now log the IOKit return code, service/registry ID, and
target/readback brightness. A write rejection, failed read, and readback mismatch
are separate messages. The old generic failure log cannot distinguish these
causes; successful tests after a restart do not identify a prior transient fault.

Run the isolated persistence regression checks (no physical backlight writes or USB access):

```bash
python3 tools/smart-dim-persistence-tests.py /tmp/SmartDimPersistenceTests.swift
swiftc -framework AppKit -framework IOKit -I native \
  /tmp/SmartDimPersistenceTests.swift DisplayRouting.swift -o /tmp/smart-dim-tests
/tmp/smart-dim-tests
python3 tools/smart-dim-persistence-tests.py /tmp/BrightnessBoundaryTests.swift --brightness-boundaries
swiftc -framework AppKit -framework IOKit -I native \
  /tmp/BrightnessBoundaryTests.swift DisplayRouting.swift -o /tmp/brightness-boundary-tests
/tmp/brightness-boundary-tests
```

The second suite exercises the production brightness class with mocked IOKit
calls, including minimum brightness and display-connection retirement. See
[the failure analysis](docs/SMART_DIM_FAILURE_ANALYSIS.md) for live reproduction,
Apple source references, and the limits of historical attribution.

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
