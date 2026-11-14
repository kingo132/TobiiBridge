# Tested results

## V1.6.1 external-display routing

Verified on the Area-51m R2 with an external VG280K as the primary display and the built-in Retina display arranged below it:

- Built-in panel selected at AppKit frame `(0, -720, 1280, 720)`, backing scale `2`.
- Live USB handshake and gaze subscription successful.
- Overlay window and the first nine-point calibration target placed on the built-in panel.
- A display-configuration notification restored an intentionally relocated overlay to the exact panel frame and resized the view correctly.
- Test calibration cancelled without changing the existing saved calibration file.
- Routing regression checks cover external-primary ordering, no built-in panel, negative origins, mixed scaling, legacy calibration decoding and panel UUID binding.
- Offscreen drawing checks confirm previous dot pixels are cleared after movement and hiding.
- V1.6.1 app built and passed strict ad-hoc signature verification locally.

Physical cable hot-plug, lid-closed operation, OS display mirroring and a complete new nine-point calibration were not exercised in this session. Windows display-routing behavior was checked against Tobii's documentation, not a parallel Windows installation.

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
