import AppKit
import CoreGraphics
import IOKit

// A missing gaze sample cannot distinguish absence from reading another display
// or an obscured tracker under a partially closed lid. Fail closed for gaze dim.
enum GazeDimmingSafety {
    static func pauseReason(displayIsBuiltIn flags: [Bool]?, lidClosed: Bool) -> String? {
        if lidClosed { return "lid closed" }
        guard let flags, !flags.isEmpty else { return "display configuration unavailable" }
        if flags.contains(false) { return "external display connected" }
        return nil
    }

    static func currentPauseReason() -> String? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else {
            return pauseReason(displayIsBuiltIn: nil, lidClosed: false)
        }
        let flags = ids.prefix(Int(count)).map { CGDisplayIsBuiltin($0) != 0 }
        // This also protects partial-lid use even when the lid switch is open.
        if flags.contains(false) { return pauseReason(displayIsBuiltIn: flags, lidClosed: false) }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        var closed = false
        if root != 0 {
            closed = (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) == true
            IOObjectRelease(root)
        }
        return pauseReason(displayIsBuiltIn: flags, lidClosed: closed)
    }
}

// This bridge drives the integrated IS5 in the Area-51m, not a movable USB
// peripheral. The physical panel determines the tracking area, never focus,
// screen order, the menu bar, or the mouse position.
struct TrackingDisplay: Equatable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let frame: CGRect
    let scale: CGFloat
    let builtIn: Bool

    static func select(from displays: [TrackingDisplay]) -> TrackingDisplay? {
        displays.first { $0.builtIn && !$0.frame.isEmpty }
    }

    static func current() -> TrackingDisplay? {
        select(from: NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let id = number.uint32Value
            guard let reference = CGDisplayCreateUUIDFromDisplayID(id) else {
                return nil
            }
            let uuid = CFUUIDCreateString(nil, reference.takeRetainedValue()) as String
            return TrackingDisplay(id: id, uuid: uuid, name: screen.localizedName,
                                   frame: screen.frame, scale: screen.backingScaleFactor,
                                   builtIn: CGDisplayIsBuiltin(id) != 0)
        })
    }
}

struct CalibrationData: Codable {
    let xCoefficients: [Double]
    let yCoefficients: [Double]
    let rmsPoints: Double
    // Optional for compatibility with V1.5 files, which belonged to the
    // integrated tracker. New calibrations explicitly record the panel UUID.
    var displayUUID: String? = nil

    func applies(to display: TrackingDisplay?) -> Bool {
        guard let display, display.builtIn else { return false }
        return displayUUID == nil || displayUUID == display.uuid
    }
}
