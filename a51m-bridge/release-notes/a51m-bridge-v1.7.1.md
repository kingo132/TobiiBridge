# TobiiBridge 1.7.1

Prevents missing internal-screen gaze from dimming screens while the user is
reading an external monitor or using the laptop with its lid partly closed.

- Pause eye-triggered smart dim whenever an external display is online,
  the lid is reported closed, or display topology is unknown.
- Partial-lid use is protected by external-display detection even if the lid
  switch still reports open.
- Restore brightness already owned by the app when entering protection.
- Preserve the user's enabled preference. When only the built-in display
  remains, require fresh gaze before resuming automatically.
- Show the paused reason in the menu and connected status.
- Leave macOS's normal idle screen-sleep settings unchanged; do not substitute
  a short keyboard/mouse-idle dim timer.

This intentionally changes V1.7.0: external hardware control is retained, but
automatic gaze-triggered multi-screen dimming is suspended because this
integrated tracker cannot reliably tell external-screen use from absence.

Twenty new safety tests cover partial/open/closed lid, external-only and
unknown topology, restoring dimmed screens, preserving preferences, and
resuming single-screen gaze dimming without restarting.
