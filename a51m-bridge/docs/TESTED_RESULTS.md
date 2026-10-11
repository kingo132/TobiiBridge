# Tested results

## USB / gaze

Tested device: Tobii IS5 Firefly integrated in Alienware Area-51m R2.

- VID:PID: `2104:030E`
- Interface: 0
- Bulk IN: `0x83`
- Bulk OUT: `0x05`
- Session control open: `0x41`
- Session control close: `0x42`
- Native handshake: successful
- Native gaze subscription: successful
- 20 s native CLI run: 662 total frames, 609 valid frames
- Typical rate observed: approximately 33 Hz

## Native app packaging

Verified on the tested system:

- App launches independently of `~/tobiifree` after build.
- `libusb-1.0.0.dylib` bundled under `Contents/Frameworks`.
- Executable `LC_RPATH`: `@executable_path/../Frameworks`.
- `codesign --verify --deep --strict` passes with ad-hoc signing.
- V1.2 example process snapshot: ~1.9% CPU and ~60 MiB RSS (single point-in-time sample, not a benchmark).

## Hardware brightness

The A51m R2 panel was verified with the IOKit probe:

```text
Original reported brightness: 0.75
Testing HARDWARE brightness at 0.375
Set result: 0
Read result: 0
Readback: 0.375
Restored original brightness: 0.75
```

The user confirmed the physical LCD backlight changed rather than only gamma/overlay brightness.
