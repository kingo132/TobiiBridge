// Low-level IOKit boundary fixture: the production brightness class and presence
// engine run unchanged. No real service is enumerated, read or written.
func testTrackingDisplay() -> TrackingDisplay? {
    TrackingDisplay(id: 1, uuid: "test-panel", name: "Test internal panel",
        frame: CGRect(x: 0, y: 0, width: 200, height: 200), scale: 1, builtIn: true)
}

enum FixtureBrightnessIO {
    static var value: Float = 0.75
    static var readResult: IOReturn = KERN_SUCCESS
    static var writeCount = 0
    static var nextIndex = 0
    static var selectedService: io_service_t = 1
    static var connectionRetired = false
    static func discover(_ port: mach_port_t, _ matching: CFDictionary?,
                         _ iterator: UnsafeMutablePointer<io_iterator_t>) -> kern_return_t {
        iterator.pointee = 100
        nextIndex = 0
        let properties = matching as? [String: Any]
        selectedService = properties?["IOProviderClass"] as? String == "IOFramebuffer" ? 2 : 1
        return KERN_SUCCESS
    }
    static func next(_ iterator: io_iterator_t) -> io_object_t {
        defer { nextIndex += 1 }
        return nextIndex == 0 ? selectedService : 0
    }
    @discardableResult static func release(_ object: io_object_t) -> kern_return_t { KERN_SUCCESS }
    static func property(_ object: io_registry_entry_t, _ key: CFString,
                         _ allocator: CFAllocator?, _ options: IOOptionBits) -> Unmanaged<CFTypeRef>? { nil }
    static func registryID(_ object: io_registry_entry_t,
                           _ result: UnsafeMutablePointer<UInt64>) -> kern_return_t {
        result.pointee = 123
        return KERN_SUCCESS
    }
    static func read(_ object: io_service_t, _ options: IOOptionBits,
                     _ key: CFString, _ output: UnsafeMutablePointer<Float>) -> IOReturn {
        output.pointee = value
        if object == 1 && connectionRetired { return kIOReturnUnsupported }
        return readResult
    }
    static func write(_ object: io_service_t, _ options: IOOptionBits,
                      _ key: CFString, _ target: Float) -> IOReturn {
        value = target
        writeCount += 1
        return KERN_SUCCESS
    }
}

extension BridgeApp {
    static func runBrightnessBoundaryTests() {
        let domain = "local.tobiibridge.persistence-tests"
        let prefs = UserDefaults(suiteName: domain)!
        defer { prefs.removePersistentDomain(forName: domain) }
        prefs.removePersistentDomain(forName: domain)
        prefs.set(true, forKey: "physicalDimEnabled")
        var failures = 0
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if condition() { print("PASS: \(name)") }
            else { failures += 1; print("FAIL: \(name)") }
        }
        FixtureBrightnessIO.value = 0.75
        let app = BridgeApp()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        app.nativeToken = NativeStopToken()
        app.lastFrameAt = Date()
        app.presenceReady = true
        app.presenceLastSeen = Date().addingTimeInterval(-60)
        FixtureBrightnessIO.value = 0
        check(app.hardware.read() == 0, "successful IOKit reading of zero remains a valid minimum")
        app.updatePresence()
        check(app.hardware.available, "zero brightness does not discard a healthy service")
        check(app.dimEnabled && prefs.bool(forKey: "physicalDimEnabled"), "zero brightness does not trigger the legacy auto-disable path")
        check(FixtureBrightnessIO.writeCount == 0, "already-minimum brightness causes no automatic brightening")
        let zeroAtLaunch = PhysicalBrightness()
        check(zeroAtLaunch.available && zeroAtLaunch.read() == 0, "launch at minimum discovers a supported backlight")
        for valid: Float in [0, 0.001, 0.1, 0.75, 1] {
            FixtureBrightnessIO.value = valid
            check(zeroAtLaunch.read() == valid, "valid normalized brightness \(valid) is readable")
        }
        for invalid: Float in [-1, 1.1, .nan, .infinity] {
            FixtureBrightnessIO.value = invalid
            check(zeroAtLaunch.read() == nil, "invalid brightness \(invalid) remains rejected")
        }
        FixtureBrightnessIO.value = 0.75
        FixtureBrightnessIO.readResult = kIOReturnUnsupported
        check(zeroAtLaunch.read() == nil, "a real IOKit error is still an error")
        FixtureBrightnessIO.readResult = KERN_SUCCESS
        let manual = PhysicalBrightness()
        check(manual.dim(to: 0.1), "normal dim operation remains functional")
        FixtureBrightnessIO.value = 0
        check(manual.detectManualOverride(), "manual change to zero interrupts automatic dimming")
        check(!manual.dimmed, "manual minimum relinquishes automatic brightness ownership")
        FixtureBrightnessIO.value = 0.75
        let rebound = PhysicalBrightness()
        FixtureBrightnessIO.connectionRetired = true
        // An old connect can no longer resolve a display. A framebuffer still
        // resolves its replacement child through IODisplayForFramebuffer.
        check(rebound.read() == 0.75, "replacement display remains readable through the cached framebuffer")
        check(rebound.dim(to: 0.2), "dimming continues after replacement without rediscovery or retry")
        rebound.restore()
        check(rebound.read() == 0.75, "restoration uses the replacement display")
        FixtureBrightnessIO.connectionRetired = false
        app.nativeToken = nil
        print("\(checks - failures)/\(checks) low-level brightness checks passed")
        if failures > 0 { exit(1) }
    }
}

@main struct BrightnessBoundaryTests {
    static func main() {
        _ = NSApplication.shared
        BridgeApp.runBrightnessBoundaryTests()
    }
}
