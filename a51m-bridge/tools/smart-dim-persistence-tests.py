#!/usr/bin/env python3
"""Generate same-file Swift regression tests without touching real backlight or USB.

Compile the generated file alongside DisplayRouting.swift, with the bridge native
include directory. The fake replaces only hardware, input-idle and USB dependencies.
The actual production startup, preference, presence, failure and retry logic runs.
"""
from pathlib import Path
import sys

bridge = Path(__file__).resolve().parent.parent
src = Path(sys.argv[3]).read_text() if len(sys.argv) > 3 else (bridge / "TobiiBridge.swift").read_text()
boundaries = len(sys.argv) > 2 and sys.argv[2] == "--brightness-boundaries"
safety = len(sys.argv) > 2 and sys.argv[2] == "--external-safety"
src = src.replace('GazeDimmingSafety.currentPauseReason()', 'testPauseReason' if safety else 'nil')
src = src.replace('TobiiBridge-Native.log', 'TobiiBridge-PersistenceTests.log')
src = src.replace('private var externalBacklights = ExternalBacklights()',
                  'private var externalBacklights = ExternalBacklights(enabled: false)')
src = src.replace('.appendingPathComponent("TobiiBridge")',
                  '.appendingPathComponent("TobiiBridge-PersistenceTests")')
src = src.replace('TrackingDisplay.current()', 'testTrackingDisplay()')
src = src.replace('window.orderFrontRegardless()', '// Keep test overlays hidden.')
src = src.replace('UserDefaults(suiteName: "local.tobiibridge.shared")!',
                  'UserDefaults(suiteName: "local.tobiibridge.persistence-tests")!')
if not boundaries:
    src = src.replace('private var hardware = PhysicalBrightness()',
                      'private var hardware = FakePhysicalBrightness()')
else:
    # Exercise the production PhysicalBrightness class. Replace only its IOKit
    # boundary, so tests distinguish a successful zero reading from an API error.
    start = src.index('final class PhysicalBrightness')
    end = src.index('final class BridgeApp', start)
    brightness = src[start:end]
    for native, mock in {
        'IOServiceGetMatchingServices': 'FixtureBrightnessIO.discover',
        'IOIteratorNext': 'FixtureBrightnessIO.next',
        'IOObjectRelease': 'FixtureBrightnessIO.release',
        'IORegistryEntryCreateCFProperty': 'FixtureBrightnessIO.property',
        'IORegistryEntryGetRegistryEntryID': 'FixtureBrightnessIO.registryID',
        'IODisplayGetFloatParameter': 'FixtureBrightnessIO.read',
        'IODisplaySetFloatParameter': 'FixtureBrightnessIO.write',
    }.items():
        brightness = brightness.replace(native + '(', mock + '(')
    src = src[:start] + brightness + src[end:]
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
fixture = "external-safety-fixture.swift" if safety else ("brightness-boundary-fixture.swift" if boundaries else "smart-dim-fixture.swift")
harness = (bridge / "tools" / fixture).read_text()
if safety:
    dependencies = (bridge / "tools/smart-dim-fixture.swift").read_text().split('extension BridgeApp')[0]
    harness = dependencies + harness
Path(sys.argv[1]).write_text(src + harness)
