# Smart-dim failure analysis — 2026-11-15

## Reproduced physical failure: valid zero rejected

The previous brightness class required `value > 0` in both discovery and reads.
On the tested physical panel, setting minimum brightness produced:

```text
rawWrite=0 rawRead=0 rawValue=0.0
legacyRead=nil legacyDim=false
legacyFreshInstanceAvailable=false
```

Both IOKit operations succeeded (`KERN_SUCCESS`). The application rejected the
value. In the unmodified V1.6.1 presence engine, this reaches the generic
"Physical brightness unavailable; auto dim disabled" branch and persists off.
V1.6.2 preserves the preference, but still misclassifies zero and retries a
healthy interface. Minimum brightness also prevented manual-override detection.

V1.6.3 accepts finite values in the inclusive range `[0, 1]`. A live retest gave
`fixedRead=Optional(0.0)`, `fixedDim=true`, and successful fresh discovery while
at zero, with no automatic brightening. Initial brightness was restored.

This agrees with Apple's `IODisplayGetFloatParameter`, which normalizes the
integer value as `(value - min) / (max - min)`; the minimum is therefore zero.

## Connection lifetime defect

The previous implementation retained an `IODisplayConnect` for the app's entire
lifetime. Apple's `IODisplayWrangler::destroyDisplayConnects` synchronously
terminates these objects during connection reconstruction;
`makeDisplayConnects` creates replacements. Retaining a port does not reconnect
the retired object's registry subtree to a new display.

`IODisplayForFramebuffer` searches a supplied framebuffer's current descendants
on each call. Both the float getter and setter use this resolution path.
V1.6.3 therefore discovers and retains the readable `IOFramebuffer` endpoint
instead of a temporary connection child. Unique-device selection and physical
backlight-only control remain in place. An actual missing display can still
require suspension, but a retired connection no longer strands the controller
once its replacement exists.

The IOKit-boundary fixture retires the old connection while leaving its
framebuffer and replacement display available. Legacy code cannot read, dim or
restore through the retired connection. V1.6.3 continues all three operations
without rediscovery, a five-second retry, or a preference toggle.

## Historical failure attribution

The recorded generic failure occurred at `2026-11-14T17:29:15Z`. Independent
read-only panel snapshots at `17:29:03Z` and `17:30:03Z` reported 87.5% brightness
and an active panel. These minute-spaced readings do not support attributing
that event to sustained zero brightness, though they cannot exclude a short
intervening transition.

Earlier captures from the same historical session show repeated replacement of
the internal display object while the app remained running. One registry
ancestry capture explicitly identifies its `IODisplayConnect` below the stable
framebuffer. This makes a retired cached connection a supported explanation,
but the app did not log its retained registry ID or the failing IOKit result.
The exact historical endpoint cannot be reconstructed conclusively.

## Live attempts and scope

All temporary changes were restored. A held legacy connection was sampled
approximately every 2 ms through each successful live operation:

| Operation | Samples | API read errors | Display child replaced |
| --- | ---: | ---: | --- |
| 1280×720 → 1920×1080 → original scaling | 3231 | 0 | No |
| Display sleep, automatic wake, original mode | 3709 | 0 | No |
| 60 Hz → 120 Hz → original mode | 3542 | 0 | No |
| Framebuffer user-requested display probe | 2868 | 0 | No |

A first attempt using `CGDisplaySetDisplayMode` returned error 1000 for the
alternate mode and is not counted as a successful configuration change; the
scaling and refresh tests above used BetterDisplay's existing CLI and verified
the requested mode before restoring it.

These results do **not** reproduce retirement of the display-connect on the
current boot, and do not prove the absence of a rarer driver/lifecycle fault.
No kernel component was rolled back or modified, and no full system sleep,
physical cable hot-plug, or reboot was performed for this investigation.

Additional live tests with the revised framebuffer endpoint: instant,
0.5-second and 2-second fades from 75% to 10% all succeeded, reading
`0.099609375`, and restored to `0.75`. Zero-brightness discovery and reads were
also verified on the actual panel. There are 21 low-level brightness checks and
16 preference/recovery checks, plus the existing display-routing checks.

## Primary source references

- [Apple IOKitUser: IODisplayForFramebuffer, parameter reads and writes](https://github.com/apple-oss-distributions/IOKitUser/blob/main/graphics.subproj/IODisplayLib.c)
- [Apple IOGraphics: makeDisplayConnects and destroyDisplayConnects](https://github.com/apple-oss-distributions/IOGraphics/blob/main/IOGraphicsFamily/IODisplayWrangler.cpp)
- [Apple IOGraphics: connection-change processing and framebuffer probing](https://github.com/apple-oss-distributions/IOGraphics/blob/main/IOGraphicsFamily/IOFramebuffer.cpp)
