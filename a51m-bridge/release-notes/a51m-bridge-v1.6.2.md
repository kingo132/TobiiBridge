# TobiiBridge 1.6.2

Physical smart dim now keeps the user's saved enabled choice when backlight
control is temporarily unavailable. Previously, discovery or brightness failures
could save `physicalDimEnabled=false`, so the checkmark stayed off on later launches.

- Retry backlight discovery every five seconds after hardware failures.
- Release a failed service and reacquire it, then require fresh gaze before dimming.
- Let the user save either enabled or disabled while hardware is unavailable.
- Log separate read, write-rejection and readback-mismatch errors with IOKit
  result codes, service registry IDs and target/actual values.
- Add sixteen isolated preference and recovery regression checks.

Validation: local build and signature verification; sixteen simulated failure
and restart checks; a live backlight test from 0.75 to 0.60 using both instant
and 0.5-second fade paths, restored to 0.75. The historical generic failure did
not retain enough detail to establish its exact hardware cause. No cold boot or
real hardware fault injection was performed.

The app remains ad-hoc signed and uses the existing shared preferences domain.
