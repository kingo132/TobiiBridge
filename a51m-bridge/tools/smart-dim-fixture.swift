
func testTrackingDisplay() -> TrackingDisplay? {
    TrackingDisplay(id: 1, uuid: "test-panel", name: "Test internal panel",
        frame: CGRect(x: 0, y: 0, width: 200, height: 200), scale: 1, builtIn: true)
}

final class FakePhysicalBrightness {
    static var initiallyAvailable = true
    var available = FakePhysicalBrightness.initiallyAvailable
    var dimmed = false
    var isRestoring = false
    var original: Float?
    var canRefresh = false
    var canRead = true
    var failDim = false
    var failFade = false
    var refreshCount = 0
    func refreshService() { refreshCount += 1; available = canRefresh }
    func invalidateService() { available = false }
    func read() -> Float? { available && canRead ? 0.7 : nil }
    func restore(duration: TimeInterval = 0) { dimmed = false }
    func detectManualOverride() -> Bool { false }
    func dim(to level: Float, duration: TimeInterval = 0) -> Bool {
        if failDim { return false }
        dimmed = true
        return true
    }
    func advance() -> Bool { !failFade }
}

extension BridgeApp {
    static func runPersistenceTests() {
        let domain = "local.tobiibridge.persistence-tests"
        let prefs = UserDefaults(suiteName: domain)!
        defer { prefs.removePersistentDomain(forName: domain) }
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            passed += 1
            print("PASS: \(label)")
        }
        func makeApp(enabled: Bool, available: Bool) -> BridgeApp {
            prefs.removePersistentDomain(forName: domain)
            prefs.set(enabled, forKey: "physicalDimEnabled")
            FakePhysicalBrightness.initiallyAvailable = available
            let app = BridgeApp()
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            return app
        }
        func armed(_ app: BridgeApp) {
            app.nativeToken = NativeStopToken()
            app.lastFrameAt = Date()
            app.presenceReady = true
            app.presenceLastSeen = Date().addingTimeInterval(-60)
            app.manualOverrideUntil = .distantPast
        }
        func enabled(_ app: BridgeApp) -> Bool {
            app.dimEnabled && prefs.bool(forKey: "physicalDimEnabled") && app.dimMenuItem.state == .on
        }
        let app = makeApp(enabled: true, available: false)
        check(enabled(app), "unavailable backlight at launch preserves saved checkmark")
        app.updatePresence()
        check(enabled(app), "failed hardware discovery preserves preference")
        let probes = app.hardware.refreshCount
        app.updatePresence()
        check(app.hardware.refreshCount == probes, "hardware retry is throttled")
        app.hardware.canRefresh = true
        app.brightnessRetryAt = .distantPast
        app.updatePresence()
        check(app.hardware.available && enabled(app), "hardware appearing after login recovers without user toggle")
        check(!app.presenceReady, "recovery waits for fresh gaze before dimming")
        armed(app)
        app.hardware.failDim = true
        app.updatePresence()
        check(enabled(app) && !app.hardware.available, "dimming write failure suspends without clearing checkmark")
        app.hardware.failDim = false
        app.brightnessRetryAt = .distantPast
        app.updatePresence()
        check(app.hardware.available && enabled(app), "write failure recovers automatically")
        armed(app)
        app.updatePresence()
        check(app.hardware.dimmed, "smart dim resumes after hardware and fresh gaze recover")
        app.hardware.failFade = true
        app.tick()
        check(enabled(app) && !app.hardware.available, "fade failure preserves preference")
        app.hardware.failFade = false
        app.brightnessRetryAt = .distantPast
        app.updatePresence()
        app.hardware.canRead = false
        app.updatePresence()
        check(enabled(app) && !app.hardware.available, "stale brightness service preserves preference and is released")
        app.hardware.canRead = true
        app.brightnessRetryAt = .distantPast
        app.updatePresence()
        armed(app)
        app.hardware.dimmed = true
        app.hardware.failDim = true
        app.changeDimLevel(NSSlider(value: 0.2, minValue: 0.1, maxValue: 0.9, target: nil, action: nil))
        check(enabled(app), "target change write failure preserves preference")
        app.toggleSmartDim()
        check(!app.dimEnabled && !prefs.bool(forKey: "physicalDimEnabled") && app.dimMenuItem.state == .off,
              "explicit user off persists even while hardware unavailable")
        app.hardware.failDim = false
        app.brightnessRetryAt = .distantPast
        app.updatePresence()
        check(!app.hardware.available, "disabled preference does not restart hardware control")
        app.nativeToken = nil
        let off = makeApp(enabled: false, available: true)
        check(!off.dimEnabled && off.dimMenuItem.state == .off, "restart respects explicit user off")
        off.hardware.available = false
        off.toggleSmartDim()
        check(enabled(off), "user can save on while hardware is temporarily absent")
        let restarted = BridgeApp()
        restarted.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        check(enabled(restarted), "new application instance restores enabled setting")
        print("\(passed) persistence regression checks passed")
    }
}

@main struct PersistenceTests {
    static func main() {
        _ = NSApplication.shared
        BridgeApp.runPersistenceTests()
    }
}
