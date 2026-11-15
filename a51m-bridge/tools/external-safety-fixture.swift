var testPauseReason: String? = nil

extension BridgeApp {
    static func runSafetyTests() {
        let domain = "local.tobiibridge.persistence-tests"
        let prefs = UserDefaults(suiteName:domain)!
        prefs.removePersistentDomain(forName:domain)
        prefs.set(true,forKey:"physicalDimEnabled")
        defer { prefs.removePersistentDomain(forName:domain) }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(),name)
            checks += 1
            print("PASS: \(name)")
        }
        let external = GazeDimmingSafety.pauseReason(displayIsBuiltIn:[true,false],lidClosed:false)
        check(external != nil,"open lid with external display pauses gaze dimming")
        check(GazeDimmingSafety.pauseReason(displayIsBuiltIn:[true,false],lidClosed:false) != nil,
              "partial lid remains protected without a closed-lid signal")
        check(GazeDimmingSafety.pauseReason(displayIsBuiltIn:[false],lidClosed:false) != nil,
              "external-only topology remains protected")
        check(GazeDimmingSafety.pauseReason(displayIsBuiltIn:[true,false],lidClosed:true) != nil,
              "closed lid with external display remains protected")
        check(GazeDimmingSafety.pauseReason(displayIsBuiltIn:[true],lidClosed:true) != nil,
              "closed lid suppresses gaze even before display topology updates")
        check(GazeDimmingSafety.pauseReason(displayIsBuiltIn:nil,lidClosed:false) != nil,
              "unknown display topology cannot arm dimming")
        check(GazeDimmingSafety.pauseReason(displayIsBuiltIn:[],lidClosed:false) != nil,
              "no online displays cannot arm dimming")
        check(GazeDimmingSafety.pauseReason(displayIsBuiltIn:[true],lidClosed:false) == nil,
              "single internal display permits ordinary gaze dimming")

        testPauseReason = nil
        FakePhysicalBrightness.initiallyAvailable = true
        let app = BridgeApp()
        app.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
        func arm() {
            app.nativeToken = NativeStopToken()
            app.lastFrameAt = Date()
            app.presenceReady = true
            app.presenceLastSeen = Date().addingTimeInterval(-60)
            app.manualOverrideUntil = .distantPast
        }
        arm()
        app.updatePresence()
        check(app.hardware.dimmed,"single-display eye absence still dims normally")
        testPauseReason = external
        app.refreshDimmingSafety()
        check(!app.hardware.dimmed,"connecting external display restores an already dimmed screen")
        check(!app.presenceReady,"entering protection clears stale presence state")
        check(app.dimEnabled && prefs.bool(forKey:"physicalDimEnabled"),"protection preserves the saved enabled preference")
        arm()
        app.hardware.failDim = true
        app.updatePresence()
        check(!app.hardware.dimmed && app.hardware.available,"long eye absence with external display never attempts dimming")
        check(app.presenceInfoItem.title == "Backlight: paused: external display connected", "menu explains why dimming is paused")
        for _ in 0..<3 { app.receivePresence(valid:true,x:0.5,y:0.5) }
        check(!app.presenceReady,"gaze samples cannot rearm dimming while protected")
        testPauseReason = nil
        app.refreshDimmingSafety()
        check(!app.presenceReady,"disconnecting external display requires fresh gaze")
        app.hardware.failDim = false
        for _ in 0..<3 { app.receivePresence(valid:true,x:0.5,y:0.5) }
        check(app.presenceReady,"fresh gaze rearms after returning to the internal display")
        arm(); app.updatePresence()
        check(app.hardware.dimmed,"gaze dimming resumes after external disconnect without app restart")
        testPauseReason = "lid closed"
        app.refreshDimmingSafety(); arm(); app.updatePresence()
        check(!app.hardware.dimmed,"lid-close protection restores and prevents dimming")
        app.toggleSmartDim(); app.updatePresence()
        check(!prefs.bool(forKey:"physicalDimEnabled") && app.presenceInfoItem.title == "Backlight: disabled",
              "explicit user off remains off while protected")
        app.nativeToken = nil
        app.shuttingDown = true
        print("\(checks) external-display safety checks passed")
    }
}

@main struct ExternalSafetyTests {
    static func main() { _ = NSApplication.shared; BridgeApp.runSafetyTests() }
}
