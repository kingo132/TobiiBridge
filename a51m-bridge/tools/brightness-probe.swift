import Foundation
import IOKit
import IOKit.graphics

let key = "brightness" as CFString
var iter: io_iterator_t = 0
let match = IOServiceGetMatchingServices(
    kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iter
)
guard match == KERN_SUCCESS else {
    print("UNSUPPORTED: IODisplayConnect not available (\(match))")
    exit(2)
}
defer { IOObjectRelease(iter) }
var supported: [io_service_t] = []
while true {
    let service = IOIteratorNext(iter)
    if service == 0 { break }
    var value: Float = -1
    let result = IODisplayGetFloatParameter(service, 0, key, &value)
    let flag = IORegistryEntryCreateCFProperty(
        service, "IODisplayHasBacklight" as CFString,
        kCFAllocatorDefault, 0
    )?.takeRetainedValue()
    print("Service \(service) get=\(result) brightness=\(value) backlight=\(String(describing: flag))")
    if result == KERN_SUCCESS && value.isFinite && value > 0 && value <= 1 {
        supported.append(service)
    } else { IOObjectRelease(service) }
}
defer { supported.forEach { IOObjectRelease($0) } }
guard supported.count == 1 else {
    print("UNSUPPORTED: expected 1 readable brightness device, found \(supported.count). No changes made.")
    exit(3)
}
let service = supported[0]
var original: Float = -1
guard IODisplayGetFloatParameter(service, 0, key, &original) == KERN_SUCCESS else { exit(4) }
print("Original reported brightness: \(original)")
if CommandLine.arguments.contains("--test") {
    let target = max(0.1, original * 0.5)
    print("Testing HARDWARE brightness at \(target) for 2 seconds; observe the LCD backlight.")
    fflush(stdout)
    let write = IODisplaySetFloatParameter(service, 0, key, target)
    defer {
        let restore = IODisplaySetFloatParameter(service, 0, key, original)
        print("Restored original brightness: \(original); result=\(restore)")
    }
    var readback: Float = -1
    let readResult = IODisplayGetFloatParameter(service, 0, key, &readback)
    print("Set result: \(write); read result: \(readResult); readback: \(readback)")
    Thread.sleep(forTimeInterval: 2)
    if write != KERN_SUCCESS || readResult != KERN_SUCCESS || abs(readback-target) > 0.08 {
        print("UNSUPPORTED: IOKit brightness change not confirmed; restoring now")
    }
    print("API test passed. User must confirm actual PANEL BACKLIGHT changed, not gamma/overlay.")
} else {
    print("READ ONLY. To test a temporary physical brightness change, rerun with --test.")
}
