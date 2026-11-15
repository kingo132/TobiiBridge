# TobiiBridge 1.7.0

Physical smart dim now includes supported external displays in addition to the
built-in panel. Each screen retains and restores its own original brightness.

- Native external brightness where supported; otherwise Intel framebuffer
  DDC/CI brightness control (VCP 0x10).
- The existing target remains absolute. Screens already below it, including
  hardware brightness zero, are left unchanged and are never brightened to it.
- External fades and readback verification run on a background worker, with
  repeated presence commands coalesced.
- Manual changes release the affected screen. Endpoint replacement preserves
  per-screen restoration state using stable display identity.
- The menu lists discovered external smart-dim targets.
- No dependency on BetterDisplay and no software dimming or power-off commands.

Validation: 16 preference/recovery, 21 brightness-boundary and 22 external
state-machine/packet checks passed, along with display-routing checks. Live
VG280K DDC testing verified 0 and 8% stay unchanged under a 10% target, and
20% -> 10% -> 20% restoration. The production presence engine, with controlled
presence injection and real panel/DDC interfaces, dimmed both the internal panel
(81.25%) and the VG280K (20%) to 10%, then restored both original levels. The
external display was finally returned to the user's pre-test 8% setting.

The integrated tracker still observes its own tracking area. External dim
targets do not add external-screen gaze calibration. This release's DDC
transport is for Intel Macs. Physical cable hot-plug and whole-system sleep
were not tested; endpoint replacement/failure/restoration are covered by mocks.
