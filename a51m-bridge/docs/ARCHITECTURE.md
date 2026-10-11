# Architecture

## Current native path (V1.2+)

```text
Tobii IS5 Firefly 2104:030E
        |
        | USB interface 0
        | control open 0x41 / close 0x42
        | Bulk OUT 0x05 / Bulk IN 0x83
        v
      libusb
        v
native/tobii_native.zig
        v
Aetherall/tobiifree Zig TTP/TLV core
        v
C ABI: tobii_open / tobii_step / tobii_close / gaze callback
        v
Swift + AppKit
        +-- gaze overlay
        +-- 9-point software calibration
        +-- smoothing
        +-- status/menu UI
        +-- sleep/wake + reconnect state machine
        +-- IOKit physical backlight control
```

## Why the native rewrite exists

The first working macOS implementation used Node.js, the `usb` package and the upstream WebAssembly protocol core. That path was invaluable for proving compatibility, but it required a child process, JSON-lines IPC and a bundled Node runtime.

The native path compiles the Zig protocol core into a macOS static library and exposes a small C ABI to Swift. This removes Node.js/WASM from runtime and lets Swift own lifecycle and recovery behavior directly.

## Software calibration

The macOS calibration is intentionally software-only. Nine targets are sampled and median gaze points are fitted to an affine transform:

```text
corrected_x = a0 + a1*x + a2*y
corrected_y = b0 + b1*x + b2*y
```

The resulting coefficients are stored under Application Support. Tobii device firmware calibration is not changed.

## Physical smart dim

The tested A51m R2 exposes brightness through IOKit `IODisplayGetFloatParameter` / `IODisplaySetFloatParameter`. V1.4+ can remember current brightness, lower the physical LCD backlight when gaze is absent for a configurable interval, then restore it when gaze returns.

V1.5 adds configurable delay, instant/smooth transitions, transition duration and persistent preferences.
