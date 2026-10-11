# Development history

This is a condensed engineering history. Earlier experimental source snapshots were developed interactively; the release archives included in this bundle begin at V1.2.

## V0.1

- Native AppKit gaze overlay.
- Node/TypeScript bridge using Aetherall/tobiifree.
- Fixed smoothing factor `0.22`.
- Menu-bar pause/resume/quit.

## V0.2

- Experimental One Euro filtering.
- Rejected in favor of the V0.1 fixed smoothing behavior.

## V0.3

- Experimental linear coordinate correction.
- Improved subjective accuracy but remained only an interim calibration approach.

## V0.4

- 9-point software calibration.
- Median sampling per target.
- 3x3 affine least-squares fit for X and Y.
- Calibration persisted to Application Support.
- Hardware/device calibration remained untouched.

## V0.5

- Finder-launchable app.
- Removed dependence on current working directory.
- Added persistent diagnostic log location.

## V0.6

- Bundled Node runtime and bridge resources inside the `.app`.
- Standalone operation tested with the source tree temporarily renamed.

## V0.7

- Sleep/wake recovery.
- Child-process crash recovery.
- USB-stream watchdog and reconnect logic.

## V0.8

- Fixed menu-bar state that remained stuck on `connecting` after gaze streaming had already started.

## V0.9

- Manual `Reconnect now`.
- `Open diagnostic log` menu item.

## V1.0

- Show/hide gaze dot.
- Live stream Hz / valid-frame percentage.
- Stable Node-based feature baseline used for the native migration.

## Native proof-of-concept

- Zig 0.16.0 native tests passed on Intel macOS Tahoe 26.7.1.
- Swift successfully linked a Zig static library and generated a native TTP request.
- Native libusb + Zig + Swift gaze test succeeded:
  - 662 frames in ~20 seconds
  - 609 valid frames
  - ~33 Hz
  - clean USB session close

## V1.2

- Full native runtime: Swift + Zig + libusb.
- No Node.js or WebAssembly runtime.
- libusb bundled inside the app and resolved via `@rpath`.
- Existing software calibration/UI preserved.
- Sleep/reconnect logic moved to the native USB lifecycle.

## V1.3

- Presence-based experimental visual dim/privacy behavior.
- Later removed because the preferred use case was physical backlight reduction rather than a black overlay.

## V1.4

- IOKit physical LCD backlight control.
- `brightness-probe.swift` used to verify actual panel backlight changes.
- Persistent preferences work started.

## V1.5

- Application icon.
- Compact icon-only menu-bar state.
- Persistent settings via UserDefaults.
- Configurable smart-dim delay.
- Configurable target physical brightness.
- Instant or smooth dim and restore transitions.
- Configurable transition durations.
