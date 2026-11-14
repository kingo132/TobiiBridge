# TobiiBridge 1.6.1

Fixes gaze dots and nine-point software calibration appearing on an external display when it is the primary or focused display. The integrated Area-51m Tobii now uses the built-in panel for both, including layouts with negative display coordinates and Retina scaling.

- Refreshes overlay placement after display-configuration changes and wake.
- Suspends the overlay, calibration and smart dimming when no drawable built-in panel is available, without falling back to an external monitor.
- Cancels unfinished calibration if the target panel or geometry changes.
- Binds new software calibration files to the panel UUID while preserving compatible V1.5 files.
- Shows the tracking display in the menu and adds a Cancel calibration action.
- Explicitly clears the transparent drawing surface between frames.

The built-in tracker does not gain cross-monitor gaze tracking. The existing nine-point calibration remains software-only; Tobii firmware calibration is unchanged. A small gaze-dot copy inside a live application thumbnail is a preview, not another tracking point.

Validated with an external VG280K as primary and the built-in panel below it, live gaze streaming, first-target placement, overlay relocation recovery, calibration cancellation, routing regression checks and local build/signature checks. Physical hot-plug, lid-closed mode and mirroring were not tested.

The Intel macOS app is ad-hoc signed. Unzip `TobiiBridge-v1.6.1-macOS-x86_64.zip` and move `TobiiBridge-Native-v1.6.1.app` to your Applications folder. The preferences domain is unchanged from V1.5.
