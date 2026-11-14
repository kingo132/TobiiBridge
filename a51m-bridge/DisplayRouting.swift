import AppKit
import CoreGraphics

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
