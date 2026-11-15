#!/usr/bin/env python3
"""Generate same-file Swift regression tests without touching real backlight or USB.

Compile the generated file alongside DisplayRouting.swift, with the bridge native
include directory. The fake replaces only hardware, input-idle and USB dependencies.
The actual production startup, preference, presence, failure and retry logic runs.
"""
from pathlib import Path
import sys

bridge = Path(__file__).resolve().parent.parent
src = (bridge / "TobiiBridge.swift").read_text()
src = src.replace('TobiiBridge-Native.log', 'TobiiBridge-PersistenceTests.log')
src = src.replace('.appendingPathComponent("TobiiBridge")',
                  '.appendingPathComponent("TobiiBridge-PersistenceTests")')
src = src.replace('TrackingDisplay.current()', 'testTrackingDisplay()')
src = src.replace('window.orderFrontRegardless()', '// Keep test overlays hidden.')
src = src.replace('UserDefaults(suiteName: "local.tobiibridge.shared")!',
                  'UserDefaults(suiteName: "local.tobiibridge.persistence-tests")!')
src = src.replace('private var hardware = PhysicalBrightness()',
                  'private var hardware = FakePhysicalBrightness()')
a = src.index('    private func startTracker() {')
b = src.index('{', a) + 1
depth, end = 1, b
while depth:
    if src[end] == '{': depth += 1
    if src[end] == '}': depth -= 1
    end += 1
src = src[:b] + '\n        // No real USB worker in these tests.\n    }' + src[end:]
src = src.replace('let idle = CGEventSource.secondsSinceLastEventType(\n                .combinedSessionState, eventType: anyInput\n            )',
                  'let idle = 100.0\n            _ = anyInput')
src = src[:src.index('@main\nstruct TobiiBridgeMain')]
harness = (bridge / "tools/smart-dim-fixture.swift").read_text()
Path(sys.argv[1]).write_text(src + harness)
