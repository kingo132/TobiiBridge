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
- V1.7.0: smart dim also controls supported external screens using native
  brightness or Intel DDC/CI, with an independent restoration level for each screen
- V1.7.1: external-display protection pauses eye-triggered dimming whenever an
  external screen is connected, including partial-lid and external-only use
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
open "$HOME/Applications/TobiiBridge-Native-v1.7.1.app"
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
  /tmp/SmartDimPersistenceTests.swift DisplayRouting.swift ExternalBacklights.swift -o /tmp/smart-dim-tests
/tmp/smart-dim-tests
python3 tools/smart-dim-persistence-tests.py /tmp/BrightnessBoundaryTests.swift --brightness-boundaries
swiftc -framework AppKit -framework IOKit -I native \
  /tmp/BrightnessBoundaryTests.swift DisplayRouting.swift ExternalBacklights.swift -o /tmp/brightness-boundary-tests
/tmp/brightness-boundary-tests
swiftc -framework AppKit -framework IOKit ExternalBacklights.swift tools/external-backlights-tests.swift -o /tmp/external-backlights-tests
/tmp/external-backlights-tests
python3 tools/smart-dim-persistence-tests.py /tmp/ExternalSafetyTests.swift --external-safety
swiftc -framework AppKit -framework IOKit -I native \
  /tmp/ExternalSafetyTests.swift DisplayRouting.swift ExternalBacklights.swift -o /tmp/external-safety-tests
/tmp/external-safety-tests
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

### External-display protection (V1.7.1)

Eye-triggered dimming is paused whenever any external display is online, the
lid is reported closed, or display topology cannot be read. This also protects
partially closed lids: the external-display condition applies even when the
lid switch still reports open. Missing gaze cannot distinguish a user reading
another screen from a user who has left.

Entering protection restores brightness owned by the app. The enabled
preference is preserved, the menu explains the paused state, and returning to
the built-in screen alone requires fresh gaze before dimming can resume.
macOS's existing idle display-sleep policy is not changed. No short keyboard
idle timer is substituted for gaze; prolonged reading on the external display
therefore does not trigger this app's gaze-dim timeout.

This changes V1.7.0's automatic multi-screen behavior. The hardware backends
below remain available, but external hardware support does not imply reliable
external-screen gaze detection. Tobii Experience documents disabling Dim screen
when two or more monitors are connected:
[Windows Interaction features](https://help.tobii.com/hc/en-us/articles/209525449-Windows-Interaction-features).

### Multi-screen hardware controller (introduced in V1.7.0)

The controller can dim/restore the built-in panel and supported external
screens together; the V1.7.1 safety policy above governs automatic triggering.
External screens use their native brightness parameter where
available, otherwise brightness VCP `0x10` over Intel framebuffer I2C/DDC/CI.
BetterDisplay is not a runtime dependency. There is no software dimming, gamma
table, overlay, display-power or input-switch fallback.

The target remains an **absolute brightness ceiling**. A screen already at or
below that target receives no write. In particular, an external screen at
hardware brightness 0 remains at 0 even with a 10% smart-dim target. Hardware
minimum need not extinguish the LCD backlight.

Each screen records its own brightness before dimming and restores that value
when attention/input returns, the feature is disabled, calibration/pause starts,
or the app quits/sleeps. Manual brightness changes release that screen from
automatic ownership. DDC reads, fades and verification run on a serial worker;
repeat presence callbacks are coalesced. Display discovery refreshes after
configuration changes/wake and periodically, and uses stable screen identity to
keep restoration state across endpoint replacement. Ambiguous identity matches
are skipped rather than targeting an arbitrary display.

The menu lists discovered external dim targets. A display without a working
native or DDC brightness interface is not controlled. The DDC path in this
release targets Intel Macs; Apple Silicon IOAV transport is not implemented.
The integrated eye tracker still observes its own tracking area; adding dim
targets does not add external-screen gaze calibration. Keyboard/mouse activity
continues to postpone dimming as before.

Packet/I2C behavior was cross-checked against
[MonitorControl's Intel DDC implementation](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/IntelDDC.swift)
and Apple's `IOI2CInterface.h` API contract.

- The device-specific native transport currently targets VID:PID `2104:030E`.
- USB interface 0, Bulk IN `0x83`, Bulk OUT `0x05`, session open `0x41`, close `0x42` were verified on the tested system.
- The app's 9-point calibration is software-only and does **not** change Tobii firmware calibration.
- Camera / Tobii Hello Sensor access is not implemented.
- The app is experimental and unofficial.

See `docs/` for architecture, test results and the full development history.

## License

GPL-3.0, consistent with the upstream `tobiifree` project. See the repository root `LICENSE` and `NOTICE.md`.
