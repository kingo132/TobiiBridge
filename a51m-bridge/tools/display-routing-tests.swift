import AppKit

@main
struct DisplayRoutingTests {
    static func main() throws {
        let panel = TrackingDisplay(id: 2, uuid: "panel", name: "Internal",
            frame: CGRect(x: 0, y: -720, width: 1280, height: 720), scale: 2, builtIn: true)
        let external = TrackingDisplay(id: 1, uuid: "external", name: "External primary",
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720), scale: 2, builtIn: false)
        precondition(TrackingDisplay.select(from: [external, panel]) == panel)
        precondition(TrackingDisplay.select(from: [panel, external]) == panel)
        precondition(TrackingDisplay.select(from: [panel]) == panel)
        precondition(TrackingDisplay.select(from: [external]) == nil)
        precondition(TrackingDisplay.select(from: []) == nil)

        // Primary-screen changes and different arrangements must retain the
        // physical panel and its exact AppKit origin, including negative X/Y.
        let movedPanel = TrackingDisplay(id: 2, uuid: "panel", name: "Internal",
            frame: CGRect(x: -1920, y: 240, width: 1280, height: 720), scale: 2, builtIn: true)
        precondition(TrackingDisplay.select(from: [external, movedPanel])?.frame == movedPanel.frame)
        let mixedScaleExternal = TrackingDisplay(id: 3, uuid: "external2", name: "4K",
            frame: CGRect(x: 1280, y: 0, width: 3840, height: 2160), scale: 1, builtIn: false)
        precondition(TrackingDisplay.select(from: [mixedScaleExternal, external, panel]) == panel)

        let legacy = Data(#"{"xCoefficients":[0,1,0],"yCoefficients":[0,0,1],"rmsPoints":2}"#.utf8)
        var calibration = try JSONDecoder().decode(CalibrationData.self, from: legacy)
        precondition(calibration.applies(to: panel))
        precondition(!calibration.applies(to: external))
        precondition(!calibration.applies(to: nil))
        calibration.displayUUID = panel.uuid
        let encoded = try JSONEncoder().encode(calibration)
        let saved = try JSONDecoder().decode(CalibrationData.self, from: encoded)
        precondition(saved.displayUUID == "panel")
        precondition(saved.applies(to: movedPanel))
        calibration.displayUUID = "different-panel"
        precondition(!calibration.applies(to: panel))
        print("PASS: integrated display selection, external primary, reorder, unplug, no display, negative origins, mixed scaling, legacy calibration, UUID binding")

        if let live = TrackingDisplay.current() {
            print("Live target: \(live.name), uuid=\(live.uuid), frame=\(live.frame), scale=\(live.scale)")
            precondition(live.builtIn)
        }
    }
}
