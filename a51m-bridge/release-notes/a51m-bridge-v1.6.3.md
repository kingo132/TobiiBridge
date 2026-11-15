# TobiiBridge 1.6.3

Corrects two brightness-control defects beyond V1.6.2's preference preservation:

- Treat a successful `0.0` reading as valid minimum brightness. Previously it
  became a read error, prevented discovery at launch, and prevented detection
  of a manual brightness override to minimum.
- Retain the framebuffer instead of its temporary `IODisplayConnect` child.
  IOKit's brightness functions resolve the framebuffer's current display child
  on each call, avoiding a retired connection after display reconstruction.

The zero-brightness failure was reproduced on the physical panel with unmodified
legacy code, then verified fixed. Instant, 0.5-second and 2-second dim-to-10%
tests passed and restored the initial 75% brightness. The low-level suite has
21 checks, alongside the previous 16 preference/recovery checks.

Scaling, refresh-rate, display-sleep/wake and detect-display probes did not
recreate a display-connect retirement on the current boot. That lifecycle is
verified against Apple's implementation and tested at the IOKit boundary;
the exact historical failure is not claimed as fully reproduced. See
`docs/SMART_DIM_FAILURE_ANALYSIS.md` for the evidence and limits.
