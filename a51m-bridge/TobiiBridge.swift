import AppKit
import Foundation
import IOKit
import IOKit.graphics
import CoreGraphics
import TobiiNative

struct Observation {
    let x: Double
    let y: Double
    let tx: Double
    let ty: Double
}

struct CalibrationData: Codable {
    let xCoefficients: [Double]
    let yCoefficients: [Double]
    let rmsPoints: Double
}

final class GazeView: NSView {
    var point: CGPoint? {
        didSet { needsDisplay = true }
    }

    var target: CGPoint? {
        didSet { needsDisplay = true }
    }

    var instruction = "" {
        didSet { needsDisplay = true }
    }

    var progress = 0.0 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let t = target {
            NSColor.black.withAlphaComponent(0.83).setFill()
            bounds.fill()

            let x = t.x * bounds.width
            let y = t.y * bounds.height

            NSColor.systemTeal
                .withAlphaComponent(0.25)
                .setFill()

            NSBezierPath(
                ovalIn: NSRect(
                    x: x - 34,
                    y: y - 34,
                    width: 68,
                    height: 68
                )
            ).fill()

            NSColor.systemTeal.setStroke()

            let ring = NSBezierPath(
                ovalIn: NSRect(
                    x: x - 17,
                    y: y - 17,
                    width: 34,
                    height: 34
                )
            )

            ring.lineWidth = 3
            ring.stroke()

            NSColor.white.setFill()

            NSBezierPath(
                ovalIn: NSRect(
                    x: x - 4,
                    y: y - 4,
                    width: 8,
                    height: 8
                )
            ).fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 21),
                .foregroundColor: NSColor.white
            ]

            (instruction as NSString).draw(
                at: NSPoint(x: 30, y: 35),
                withAttributes: attributes
            )

            NSColor.systemTeal.setFill()

            NSRect(
                x: 30,
                y: 74,
                width: max(0, bounds.width - 60) * progress,
                height: 4
            ).fill()

            return
        }

        guard let p = point else { return }

        let x = p.x * bounds.width
        let y = p.y * bounds.height

        NSColor.systemTeal
            .withAlphaComponent(0.20)
            .setFill()

        NSBezierPath(
            ovalIn: NSRect(
                x: x - 28,
                y: y - 28,
                width: 56,
                height: 56
            )
        ).fill()

        NSColor.systemTeal
            .withAlphaComponent(0.90)
            .setFill()

        NSBezierPath(
            ovalIn: NSRect(
                x: x - 8,
                y: y - 8,
                width: 16,
                height: 16
            )
        ).fill()

        NSColor.white.setFill()

        NSBezierPath(
            ovalIn: NSRect(
                x: x - 3,
                y: y - 3,
                width: 6,
                height: 6
            )
        ).fill()
    }
}


// Native USB transport is executed on one background worker.
// Never close libusb from AppKit while tobii_step() may be reading.
final class NativeStopToken {
    private let lock = NSLock()
    private var requested = false

    func requestStop() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}

final class NativeGazeRouter {
    static let shared = NativeGazeRouter()
    typealias Handler = (Double, Double, UInt32, UInt32) -> Void
    private let lock = NSLock()
    private var handler: Handler?

    func setHandler(_ next: Handler?) {
        lock.lock()
        handler = next
        lock.unlock()
    }

    func deliver(_ x: Double, _ y: Double, _ l: UInt32, _ r: UInt32) {
        lock.lock()
        let receive = handler
        lock.unlock()
        receive?(x, y, l, r)
    }
}

// C ABI trampoline. Never touch AppKit from this background callback.
private func nativeGazeCallback(
    _ x: Double, _ y: Double, _ l: UInt32, _ r: UInt32
) {
    NativeGazeRouter.shared.deliver(x, y, l, r)
}

final class NativeLogger {
    static let shared = NativeLogger()
    private let lock = NSLock()
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TobiiBridge-Native.log")

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }
}

// Physical backlight control only. No gamma LUT and no overlay fallback.
// IODisplayConnect may be unavailable on some Hackintosh configurations.
// Physical backlight only: no gamma/overlay. All calls originate on AppKit's main thread.
final class PhysicalBrightness {
    private var service: io_service_t = 0
    private(set) var original: Float?
    private(set) var dimmed = false
    private var lastWritten: Float?
    private let key = "brightness" as CFString

    private struct Fade {
        let from: Float
        let to: Float
        let began: TimeInterval
        let duration: TimeInterval
        let restoring: Bool
    }
    private var fade: Fade?
    var isRestoring: Bool { fade?.restoring == true }

    init() {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iter
        ) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        var found: [(io_service_t, Bool)] = []
        while true {
            let entry = IOIteratorNext(iter)
            if entry == 0 { break }
            var value: Float = -1
            if IODisplayGetFloatParameter(entry, 0, key, &value) == KERN_SUCCESS,
               value.isFinite, value > 0, value <= 1 {
                let prop = IORegistryEntryCreateCFProperty(
                    entry, "IODisplayHasBacklight" as CFString,
                    kCFAllocatorDefault, 0
                )?.takeRetainedValue()
                found.append((entry, (prop as? Bool) == true))
            } else {
                IOObjectRelease(entry)
            }
        }
        let builtIn = found.filter { $0.1 }
        let chosen: io_service_t?
        if builtIn.count == 1 { chosen = builtIn[0].0 }
        else if found.count == 1 { chosen = found[0].0 }
        else { chosen = nil }
        for (candidate, _) in found where candidate != chosen {
            IOObjectRelease(candidate)
        }
        if let chosen { service = chosen }
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    var available: Bool { service != 0 }

    func read() -> Float? {
        guard available else { return nil }
        var value: Float = -1
        guard IODisplayGetFloatParameter(service, 0, key, &value) == KERN_SUCCESS,
              value.isFinite, value > 0, value <= 1 else { return nil }
        return value
    }

    @discardableResult
    private func write(_ value: Float) -> Bool {
        guard available else { return false }
        let target = min(1, max(0.1, value))
        guard IODisplaySetFloatParameter(service, 0, key, target) == KERN_SUCCESS,
              let actual = read(), abs(actual - target) <= 0.08 else { return false }
        lastWritten = actual
        return true
    }

    private func forget() {
        fade = nil
        dimmed = false
        original = nil
        lastWritten = nil
    }

    // If the user changes the system brightness mid-fade, stop ALL writes.
    func detectManualOverride() -> Bool {
        guard dimmed, let current = read(), let lastWritten else { return false }
        guard abs(current - lastWritten) > 0.07 else { return false }
        forget()
        return true
    }

    @discardableResult
    func dim(to level: Float, duration: TimeInterval = 0) -> Bool {
        guard available else { return false }
        if !dimmed {
            guard let current = read() else { return false }
            original = current
        }
        guard let baseline = original else { return false }
        let target = min(level, baseline)
        guard target < baseline - 0.01 else { return true }
        guard let current = read() else { return false }
        dimmed = true
        if duration <= 0 {
            fade = nil
            if write(target) { return true }
            _ = IODisplaySetFloatParameter(service, 0, key, baseline)
            forget()
            return false
        }
        fade = Fade(from: current, to: target,
                    began: ProcessInfo.processInfo.systemUptime,
                    duration: duration, restoring: false)
        return true
    }

    func restore(duration: TimeInterval = 0) {
        guard dimmed, let baseline = original else { return }
        guard let current = read() else { forget(); return }
        if let lastWritten, abs(current - lastWritten) > 0.07 {
            forget() // A user override must win.
            return
        }
        if duration <= 0 || abs(current - baseline) < 0.005 {
            _ = write(baseline)
            forget()
        } else {
            fade = Fade(from: current, to: baseline,
                        began: ProcessInfo.processInfo.systemUptime,
                        duration: duration, restoring: true)
        }
    }

    // Call at 20 Hz. Smoothstep, and the next direction can replace an in-flight fade.
    // Returns false if a hardware write/readback fails.
    @discardableResult
    func advance() -> Bool {
        guard let f = fade else { return true }
        let t = min(1, max(0, (ProcessInfo.processInfo.systemUptime - f.began) / f.duration))
        let eased = Float(t * t * (3 - 2 * t))
        let next = f.from + (f.to - f.from) * eased
        if let current = read(), abs(current - next) < 0.008 && t < 1 { return true }
        guard write(next) else {
            if let original { _ = IODisplaySetFloatParameter(service, 0, key, original) }
            forget()
            return false
        }
        if t >= 1 {
            fade = nil
            if f.restoring { forget() }
        }
        return true
    }
}


final class BridgeApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var gazeView: GazeView!

    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var calibrationItem: NSMenuItem!

    // Main-thread ownership; the token itself is lock-protected.
    private var nativeToken: NativeStopToken?
    private var exitReplyPending = false

    private enum Indicator: Equatable {
        case connecting, connected, dimmed, disconnected, reconnecting, paused, sleeping
    }
    private var indicator: Indicator = .connecting
    private var indicatorSymbol = ""
    private var infoItem: NSMenuItem!

    private var dotVisible = false
    private var dotItem: NSMenuItem!
    private var statsItem: NSMenuItem!

    // Persistent settings share one defaults domain across app versions.
    private let preferences = UserDefaults(suiteName: "local.tobiibridge.shared")!
    private var hardware = PhysicalBrightness()
    private var dimEnabled = false
    private var dimLevel: Float = 0.25
    private var dimMenuItem: NSMenuItem!
    private var dimLevelLabel: NSTextField!
    private var presenceInfoItem: NSMenuItem!
    private var presenceLastSeen = Date()
    private var presenceStreak = 0
    private var presenceReady = false
    private var manualOverrideUntil = Date.distantPast
    private var dimAfter: TimeInterval = 8.0
    private var dimTransitionSmooth = true
    private var restoreTransitionSmooth = true
    private var dimFadeSeconds: TimeInterval = 0.5
    private var restoreFadeSeconds: TimeInterval = 0.5
    private var delayMenu: NSMenu!
    private var delayRootItem: NSMenuItem!
    private var dimModeMenu: NSMenu!
    private var restoreModeMenu: NSMenu!
    private var dimDurationMenu: NSMenu!
    private var restoreDurationMenu: NSMenu!
    private let streamFreshness: TimeInterval = 2.0

    private var framesInWindow = 0
    private var validFramesInWindow = 0
    private var statsStart = Date()


    private var sleeping = false
    private var shuttingDown = false
    private var restarting = false
    private var retryScheduled = false

    // Updated for EVERY gaze frame, even invalid ones.
    // A lack of frames indicates a stalled USB stream.
    private var lastFrameAt: Date?

    private let reconnectDelay: TimeInterval = 3.0
    private let streamTimeout: TimeInterval = 12.0

    private var paused = false

    private var filteredPoint: CGPoint?
    private var lastValidTime = Date.distantPast

    // Preserve V0.1 smoothing.
    private let smoothing: CGFloat = 0.22

    private var calibration: CalibrationData?

    private let targets: [CGPoint] = [
        CGPoint(x: 0.50, y: 0.50),
        CGPoint(x: 0.15, y: 0.15),
        CGPoint(x: 0.50, y: 0.15),
        CGPoint(x: 0.85, y: 0.15),
        CGPoint(x: 0.85, y: 0.50),
        CGPoint(x: 0.85, y: 0.85),
        CGPoint(x: 0.50, y: 0.85),
        CGPoint(x: 0.15, y: 0.85),
        CGPoint(x: 0.15, y: 0.50)
    ]

    private var calibrating = false
    private var targetIndex = 0
    private var targetStart = Date()
    private var samples: [CGPoint] = []
    private var observations: [Observation] = []
    private var retries = 0

    private let settleSeconds = 0.7
    private let targetSeconds = 2.4

    private var calibrationPath: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return support
            .appendingPathComponent("TobiiBridge")
            .appendingPathComponent("calibration.json")
    }

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        NSApp.setActivationPolicy(.accessory)

        createOverlay()
        dotVisible = preferences.object(forKey: "showGazeDot") as? Bool ?? false
        dimEnabled = preferences.bool(forKey: "physicalDimEnabled")
        let stored = preferences.object(forKey: "physicalDimLevel") as? Float ?? 0.25
        dimLevel = min(0.9, max(0.1, stored))
        let delay = preferences.object(forKey: "dimAfterSeconds") as? Double ?? 8.0
        dimAfter = [3.0, 5.0, 8.0, 15.0, 30.0].contains(delay) ? delay : 8.0
        dimTransitionSmooth = preferences.object(forKey: "dimTransitionSmooth") as? Bool ?? true
        restoreTransitionSmooth = preferences.object(forKey: "restoreTransitionSmooth") as? Bool ?? true
        let fadeIn = preferences.object(forKey: "dimFadeSeconds") as? Double ?? 0.5
        let fadeOut = preferences.object(forKey: "restoreFadeSeconds") as? Double ?? 0.5
        dimFadeSeconds = [0.3, 0.5, 1.0, 2.0].contains(fadeIn) ? fadeIn : 0.5
        restoreFadeSeconds = [0.3, 0.5, 1.0, 2.0].contains(fadeOut) ? fadeOut : 0.5
        createMenu()
        loadCalibration()
        presenceStatus(hardware.available ? "waiting" : "no physical brightness control")
        if dimEnabled && !hardware.available {
            dimEnabled = false
            preferences.set(false, forKey: "physicalDimEnabled")
            dimMenuItem.state = .off
        }

        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        startTracker()

        Timer.scheduledTimer(
            withTimeInterval: 0.05,
            repeats: true
        ) { [weak self] _ in
            self?.tick()
        }
    }

    private func createOverlay() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            NSApp.terminate(nil)
            return
        }

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true

        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        gazeView = GazeView(
            frame: NSRect(
                origin: .zero,
                size: screen.frame.size
            )
        )

        window.contentView = gazeView
        window.orderFrontRegardless()
    }

    private func setIndicator(_ next: Indicator) {
        let priorIndicator = indicator
        let symbol: String
        let description: String
        switch next {
        case .connecting:
            symbol = "arrow.triangle.2.circlepath"; description = "Connecting"
        case .connected:
            symbol = dimEnabled ? "eye.circle" : "eye.fill"
            description = dimEnabled ? "Connected · smart dim on" : "Connected"
        case .dimmed:
            symbol = "moon.fill"; description = "Physical backlight dimmed"
        case .disconnected:
            symbol = "eye.slash"; description = "Disconnected"
        case .reconnecting:
            symbol = "arrow.clockwise.circle"; description = "Reconnecting"
        case .paused:
            symbol = "pause.circle"; description = "Paused"
        case .sleeping:
            symbol = "moon.zzz"; description = "Sleeping"
        }
        if priorIndicator == next && indicatorSymbol == symbol &&
           statusItem.button?.image != nil { return }
        indicator = next
        indicatorSymbol = symbol
        let img = NSImage(systemSymbolName: symbol,
                          accessibilityDescription: "Tobii " + description)
            ?? NSImage(systemSymbolName: "eye", accessibilityDescription: "Tobii")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Tobii Native V1.5 · " + description
        infoItem?.title = "Status: " + description
    }

    private func makeModeMenu(selector: Selector) -> NSMenu {
        let menu = NSMenu()
        for (tag, name) in [(0, "Instant"), (1, "Smooth")] {
            let item = NSMenuItem(title: name, action: selector, keyEquivalent: "")
            item.tag = tag
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private func makeDurationMenu(selector: Selector) -> NSMenu {
        let menu = NSMenu()
        for millis in [300, 500, 1000, 2000] {
            let item = NSMenuItem(title: String(format: "%.1f seconds", Double(millis)/1000),
                                  action: selector, keyEquivalent: "")
            item.tag = millis
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private func updateTransitionMenu() {
        for item in delayMenu.items {
            item.state = item.tag == Int(dimAfter) ? .on : .off
        }
        for item in dimModeMenu.items {
            item.state = item.tag == (dimTransitionSmooth ? 1 : 0) ? .on : .off
        }
        for item in restoreModeMenu.items {
            item.state = item.tag == (restoreTransitionSmooth ? 1 : 0) ? .on : .off
        }
        for item in dimDurationMenu.items {
            item.state = item.tag == Int(dimFadeSeconds * 1000) ? .on : .off
        }
        for item in restoreDurationMenu.items {
            item.state = item.tag == Int(restoreFadeSeconds * 1000) ? .on : .off
        }
        dimDurationMenu.items.forEach { $0.isEnabled = dimTransitionSmooth }
        restoreDurationMenu.items.forEach { $0.isEnabled = restoreTransitionSmooth }
    }

    @objc private func changeDimDelay(_ sender: NSMenuItem) {
        dimAfter = TimeInterval(sender.tag)
        preferences.set(dimAfter, forKey: "dimAfterSeconds")
        delayRootItem.title = "Dim after: \(Int(dimAfter)) seconds"
        presenceLastSeen = Date()
        updateTransitionMenu()
    }

    @objc private func changeDimMode(_ sender: NSMenuItem) {
        dimTransitionSmooth = sender.tag == 1
        preferences.set(dimTransitionSmooth, forKey: "dimTransitionSmooth")
        updateTransitionMenu()
    }

    @objc private func changeRestoreMode(_ sender: NSMenuItem) {
        restoreTransitionSmooth = sender.tag == 1
        preferences.set(restoreTransitionSmooth, forKey: "restoreTransitionSmooth")
        updateTransitionMenu()
    }

    @objc private func changeDimDuration(_ sender: NSMenuItem) {
        dimFadeSeconds = Double(sender.tag) / 1000
        preferences.set(dimFadeSeconds, forKey: "dimFadeSeconds")
        updateTransitionMenu()
    }

    @objc private func changeRestoreDuration(_ sender: NSMenuItem) {
        restoreFadeSeconds = Double(sender.tag) / 1000
        preferences.set(restoreFadeSeconds, forKey: "restoreFadeSeconds")
        updateTransitionMenu()
    }

    private var selectedDimDuration: TimeInterval {
        dimTransitionSmooth ? dimFadeSeconds : 0
    }
    private var selectedRestoreDuration: TimeInterval {
        restoreTransitionSmooth ? restoreFadeSeconds : 0
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )

        let menu = NSMenu()
        infoItem = NSMenuItem(title: "Status: Connecting", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(.separator())
        setIndicator(.connecting)

        dotItem = NSMenuItem(
            title: "Show gaze dot",
            action: #selector(toggleGazeDot),
            keyEquivalent: ""
        )
        dotItem.target = self
        dotItem.state = dotVisible ? .on : .off
        menu.addItem(dotItem)

        statsItem = NSMenuItem(
            title: "Stream: waiting for data",
            action: nil,
            keyEquivalent: ""
        )
        statsItem.isEnabled = false
        menu.addItem(statsItem)

        menu.addItem(.separator())

        dimMenuItem = NSMenuItem(
            title: "Physical smart dim",
            action: #selector(toggleSmartDim),
            keyEquivalent: ""
        )
        dimMenuItem.target = self
        dimMenuItem.state = dimEnabled ? .on : .off
        dimMenuItem.isEnabled = hardware.available
        menu.addItem(dimMenuItem)

        delayMenu = NSMenu()
        for delay in [3, 5, 8, 15, 30] {
            let item = NSMenuItem(title: "\(delay) seconds",
                                  action: #selector(changeDimDelay(_:)), keyEquivalent: "")
            item.tag = delay
            item.target = self
            delayMenu.addItem(item)
        }
        delayRootItem = NSMenuItem(title: "Dim after: \(Int(dimAfter)) seconds",
                                   action: nil, keyEquivalent: "")
        delayRootItem.submenu = delayMenu
        menu.addItem(delayRootItem)

        dimModeMenu = makeModeMenu(selector: #selector(changeDimMode(_:)))
        let dimMode = NSMenuItem(title: "Dim transition", action: nil, keyEquivalent: "")
        dimMode.submenu = dimModeMenu
        menu.addItem(dimMode)

        restoreModeMenu = makeModeMenu(selector: #selector(changeRestoreMode(_:)))
        let restoreMode = NSMenuItem(title: "Restore transition", action: nil, keyEquivalent: "")
        restoreMode.submenu = restoreModeMenu
        menu.addItem(restoreMode)

        dimDurationMenu = makeDurationMenu(selector: #selector(changeDimDuration(_:)))
        let dimDuration = NSMenuItem(title: "Dim fade duration", action: nil, keyEquivalent: "")
        dimDuration.submenu = dimDurationMenu
        menu.addItem(dimDuration)

        restoreDurationMenu = makeDurationMenu(selector: #selector(changeRestoreDuration(_:)))
        let restoreDuration = NSMenuItem(title: "Restore fade duration", action: nil, keyEquivalent: "")
        restoreDuration.submenu = restoreDurationMenu
        menu.addItem(restoreDuration)
        updateTransitionMenu()

        let sliderHolder = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        dimLevelLabel = NSTextField(labelWithString: "Dim backlight to \(Int(dimLevel * 100))%")
        dimLevelLabel.frame = NSRect(x: 16, y: 30, width: 240, height: 17)
        sliderHolder.addSubview(dimLevelLabel)
        let slider = NSSlider(value: Double(dimLevel), minValue: 0.1,
                              maxValue: 0.9, target: self,
                              action: #selector(changeDimLevel(_:)))
        slider.frame = NSRect(x: 14, y: 4, width: 230, height: 23)
        slider.isContinuous = false
        slider.isEnabled = hardware.available
        sliderHolder.addSubview(slider)
        let sliderMenuItem = NSMenuItem()
        sliderMenuItem.view = sliderHolder
        menu.addItem(sliderMenuItem)

        presenceInfoItem = NSMenuItem(title: "Physical backlight: checking",
                                      action: nil, keyEquivalent: "")
        presenceInfoItem.isEnabled = false
        menu.addItem(presenceInfoItem)

        let restoreItem = NSMenuItem(title: "Restore brightness now",
                                     action: #selector(restoreScreenNow),
                                     keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)

        menu.addItem(.separator())

        let reconnect = NSMenuItem(
            title: "Reconnect now",
            action: #selector(reconnectNow),
            keyEquivalent: ""
        )
        reconnect.target = self
        menu.addItem(reconnect)

        let logs = NSMenuItem(
            title: "Open diagnostic log",
            action: #selector(openLog),
            keyEquivalent: ""
        )
        logs.target = self
        menu.addItem(logs)

        menu.addItem(.separator())

        calibrationItem = NSMenuItem(
            title: "Calibrate (9 points)",
            action: #selector(startCalibration),
            keyEquivalent: ""
        )

        calibrationItem.target = self
        menu.addItem(calibrationItem)

        let reset = NSMenuItem(
            title: "Reset software calibration",
            action: #selector(resetCalibration),
            keyEquivalent: ""
        )

        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        pauseItem = NSMenuItem(
            title: "Pause tracking",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )

        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit TobiiBridge",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )

        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func loadCalibration() {
        guard let data = try? Data(
            contentsOf: calibrationPath
        ),
        let result = try? JSONDecoder().decode(
            CalibrationData.self,
            from: data
        ),
        result.xCoefficients.count == 3,
        result.yCoefficients.count == 3,
        result.xCoefficients.allSatisfy({ $0.isFinite }),
        result.yCoefficients.allSatisfy({ $0.isFinite })
        else {
            return
        }

        calibration = result
        print(
            "Loaded software calibration.",
            "RMS:", result.rmsPoints
        )
    }

    private func saveCalibration(_ c: CalibrationData) throws {
        let path = calibrationPath

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try JSONEncoder().encode(c)

        try data.write(
            to: path,
            options: .atomic
        )
    }

    private func applyCalibration(
        x: Double,
        y: Double
    ) -> CGPoint {
        guard let c = calibration else {
            return CGPoint(x: x, y: y)
        }

        let a = c.xCoefficients
        let b = c.yCoefficients

        return CGPoint(
            x: a[0] + a[1] * x + a[2] * y,
            y: b[0] + b[1] * x + b[2] * y
        )
    }

    // MARK: - Physical backlight presence engine

    private func presenceStatus(_ message: String) {
        let next = "Backlight: " + message
        if presenceInfoItem?.title != next { presenceInfoItem?.title = next }
    }

    private func resetPresence(_ reason: String) {
        hardware.restore()
        presenceLastSeen = Date()
        presenceStreak = 0
        presenceReady = false
        presenceStatus(reason)
    }

    private func receivePresence(valid: Bool, x: Double?, y: Double?) {
        // Only a fresh gaze point on the tracked screen indicates attention.
        let looking = valid && x != nil && y != nil &&
            (0...1).contains(x!) && (0...1).contains(y!)
        if looking {
            presenceStreak = min(presenceStreak + 1, 3)
            if presenceStreak >= 3 {
                presenceReady = true
                presenceLastSeen = Date()
                if hardware.dimmed && !hardware.isRestoring {
                    hardware.restore(duration: selectedRestoreDuration)
                    setIndicator(.connected)
                }
            }
        } else {
            presenceStreak = 0
        }
    }

    private func updatePresence() {
        guard dimEnabled, hardware.available else {
            hardware.restore()
            presenceStatus(hardware.available ? "disabled" : "unsupported by display")
            return
        }
        guard !sleeping, !shuttingDown, !calibrating, !paused else {
            hardware.restore()
            presenceStatus("suspended")
            return
        }
        guard let token = nativeToken, !token.isStopped,
              let lastFrameAt,
              Date().timeIntervalSince(lastFrameAt) < streamFreshness else {
            resetPresence("USB unavailable")
            return
        }
        if hardware.detectManualOverride() {
            manualOverrideUntil = Date().addingTimeInterval(30)
            presenceLastSeen = Date()
            presenceStatus("manual brightness override")
            setIndicator(.connected)
            return
        }
        if Date() < manualOverrideUntil {
            presenceStatus("manual brightness override")
            return
        }
        // Don't dim while the person is actively using keyboard or mouse.
        if let anyInput = CGEventType(rawValue: UInt32.max) {
            let idle = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: anyInput
            )
            if idle.isFinite && idle >= 0 && idle < 3 {
                presenceLastSeen = Date()
                if hardware.dimmed && !hardware.isRestoring {
                    hardware.restore(duration: selectedRestoreDuration)
                    setIndicator(.connected)
                }
                presenceStatus("input active")
                return
            }
        }
        guard presenceReady else {
            hardware.restore()
            presenceStatus("waiting for gaze")
            return
        }
        let missingFor = Date().timeIntervalSince(presenceLastSeen)
        if missingFor >= dimAfter {
            if !hardware.dimmed {
                if let current = hardware.read(), current <= dimLevel + 0.01 {
                    presenceStatus("already below dim target")
                } else if hardware.dim(to: dimLevel, duration: selectedDimDuration) {
                    setIndicator(.dimmed)
                    presenceStatus("physically dimmed to \(Int(dimLevel * 100))%")
                } else {
                    dimEnabled = false
                    preferences.set(false, forKey: "physicalDimEnabled")
                    dimMenuItem.state = .off
                    presenceStatus("brightness write failed")
                    NativeLogger.shared.write("Physical brightness unavailable; auto dim disabled")
                }
            }
        } else {
            if hardware.dimmed && !hardware.isRestoring {
                hardware.restore(duration: selectedRestoreDuration)
                setIndicator(.connected)
            }
            presenceStatus("looking / grace period")
        }
    }

    @objc private func toggleSmartDim() {
        guard hardware.available else {
            presenceStatus("unsupported by display")
            return
        }
        dimEnabled.toggle()
        preferences.set(dimEnabled, forKey: "physicalDimEnabled")
        dimMenuItem.state = dimEnabled ? .on : .off
        resetPresence(dimEnabled ? "waiting for gaze" : "disabled")
        if nativeToken != nil && !paused { setIndicator(.connected) }
    }

    @objc private func changeDimLevel(_ sender: NSSlider) {
        dimLevel = Float(sender.doubleValue)
        preferences.set(dimLevel, forKey: "physicalDimLevel")
        dimLevelLabel.stringValue = "Dim backlight to \(Int(dimLevel * 100))%"
        if hardware.dimmed && !hardware.dim(to: dimLevel, duration: selectedDimDuration) {
            hardware.restore()
            dimEnabled = false
            preferences.set(false, forKey: "physicalDimEnabled")
            dimMenuItem.state = .off
            presenceStatus("brightness write failed")
        }
    }

    @objc private func restoreScreenNow() {
        hardware.restore()
        presenceLastSeen = Date()
        manualOverrideUntil = Date().addingTimeInterval(10)
        presenceStatus("manually restored")
        if nativeToken != nil && !paused { setIndicator(.connected) }
    }

    private func startTracker() {
        guard !sleeping, !shuttingDown, nativeToken == nil else { return }

        let token = NativeStopToken()
        nativeToken = token
        resetPresence("connecting")
        restarting = false
        lastFrameAt = Date()
        filteredPoint = nil
        gazeView.point = nil
        framesInWindow = 0
        validFramesInWindow = 0
        statsStart = Date()
        statsItem.title = "Stream: connecting"
        setIndicator(.connecting)
        NativeLogger.shared.write("Starting native USB worker")

        // Only this worker calls open/step/close, always in that order.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            NativeGazeRouter.shared.setHandler { [weak self, weak token] x, y, l, r in
                DispatchQueue.main.async { [weak self, weak token] in
                    guard let self, let token,
                          self.nativeToken === token,
                          !token.isStopped,
                          !self.sleeping, !self.shuttingDown else { return }
                    let valid = (l == 0 || r == 0) &&
                        x.isFinite && y.isFinite &&
                        (-0.5...1.5).contains(x) &&
                        (-0.5...1.5).contains(y)
                    self.updateGaze(valid: valid, x: x, y: y)
                }
            }
            tobii_set_gaze_callback(nativeGazeCallback)
            let opened = tobii_open()
            if opened == 0 {
                NativeLogger.shared.write("USB opened; starting handshake")
                while !token.isStopped {
                    let code = tobii_step()
                    if code < 0 {
                        NativeLogger.shared.write("tobii_step failed: \(code)")
                        break
                    }
                    if code == 2 {
                        NativeLogger.shared.write("Handshake complete, gaze subscribed")
                    }
                }
                // All USB calls, including close, stay on the same worker.
                tobii_close()
                NativeLogger.shared.write("USB session closed")
            } else {
                NativeLogger.shared.write("USB open failed: \(opened)")
            }
            tobii_set_gaze_callback(nil)
            NativeGazeRouter.shared.setHandler(nil)
            DispatchQueue.main.async { [weak self] in
                self?.nativeWorkerFinished(token)
            }
        }
    }

    private func nativeWorkerFinished(_ token: NativeStopToken) {
        guard nativeToken === token else { return }
        nativeToken = nil
        resetPresence("disconnected")
        lastFrameAt = nil
        restarting = false
        filteredPoint = nil
        gazeView.point = nil
        if exitReplyPending {
            exitReplyPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
        } else if !shuttingDown && !sleeping {
            setIndicator(.disconnected)
            scheduleRetry()
        }
    }

    private func abortCalibrationForDisconnect() {
        guard calibrating else { return }
        calibrating = false
        samples.removeAll()
        observations.removeAll()
        gazeView.target = nil
        gazeView.instruction = ""
        calibrationItem.isEnabled = true
        calibrationItem.title = "Calibrate (9 points)"
        NativeLogger.shared.write("Software calibration interrupted; saved calibration preserved")
    }

    private func stopNativeTracker() {
        nativeToken?.requestStop()
    }

    private func updateGaze(
        valid: Bool,
        x: Double?,
        y: Double?
    ) {
        lastFrameAt = Date()

        framesInWindow += 1
        if valid {
            validFramesInWindow += 1
        }
        receivePresence(valid: valid, x: x, y: y)

        if paused { setIndicator(.paused) }
        else if !calibrating && indicator != .connected && indicator != .dimmed {
            setIndicator(.connected)
            NativeLogger.shared.write("Tobii gaze stream active")
        }

        guard valid, let x, let y,
              x.isFinite, y.isFinite else {
            return
        }

        if calibrating {
            let elapsed = Date().timeIntervalSince(
                targetStart
            )

            // Ignore samples while the eye is moving
            // toward the newly displayed target.
            if elapsed >= settleSeconds &&
               elapsed < targetSeconds {
                samples.append(CGPoint(x: x, y: y))
            }

            return
        }

        guard !paused else { return }

        let corrected = applyCalibration(x: x, y: y)

        guard (0...1).contains(corrected.x),
              (0...1).contains(corrected.y) else {
            return
        }

        if let old = filteredPoint {
            filteredPoint = CGPoint(
                x: old.x +
                    (corrected.x - old.x) * smoothing,
                y: old.y +
                    (corrected.y - old.y) * smoothing
            )
        } else {
            filteredPoint = corrected
        }

        lastValidTime = Date()
        gazeView.point = dotVisible
            ? filteredPoint
            : nil
    }

    private func tick() {
        if shuttingDown || sleeping {
            return
        }

        checkStreamHealth()
        refreshStreamStats()
        updatePresence()
        if !hardware.advance() {
            dimEnabled = false
            preferences.set(false, forKey: "physicalDimEnabled")
            dimMenuItem.state = .off
            manualOverrideUntil = Date().addingTimeInterval(30)
            presenceStatus("brightness write failed")
            NativeLogger.shared.write("Physical brightness fade failed; auto dim disabled")
            setIndicator(.connected)
        }

        if calibrating {
            let elapsed = Date().timeIntervalSince(
                targetStart
            )

            gazeView.progress = min(
                1,
                Double(targetIndex) / 9 +
                    min(elapsed / targetSeconds, 1) / 9
            )

            if elapsed >= targetSeconds {
                finishTarget()
            }

            return
        }

        guard !paused else { return }

        if Date().timeIntervalSince(lastValidTime) > 0.35 {
            filteredPoint = nil
            gazeView.point = nil
        }
    }

    @objc private func startCalibration() {
        guard !calibrating, !sleeping,
              let token = nativeToken, !token.isStopped,
              let last = lastFrameAt,
              Date().timeIntervalSince(last) < 1.0 else { return }

        paused = false
        calibrating = true
        hardware.restore()
        targetIndex = 0
        retries = 0

        observations.removeAll()
        samples.removeAll()

        filteredPoint = nil
        gazeView.point = nil

        calibrationItem.title = "Calibrating..."
        calibrationItem.isEnabled = false

        showTarget()
    }

    private func showTarget() {
        targetStart = Date()
        samples.removeAll()

        gazeView.target = targets[targetIndex]
        gazeView.instruction =
            "Look at the center of the dot · " +
            "\(targetIndex + 1) / 9"
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2

        if sorted.count % 2 == 0 {
            return (
                sorted[middle - 1] + sorted[middle]
            ) / 2
        }

        return sorted[middle]
    }

    private func finishTarget() {
        guard samples.count >= 12 else {
            retries += 1

            if retries <= 2 {
                print(
                    "Too few samples; retrying point",
                    targetIndex + 1
                )
                showTarget()
                return
            }

            cancelCalibration(
                "Insufficient valid gaze samples at " +
                "point \(targetIndex + 1). " +
                "Please adjust your sitting position."
            )
            return
        }

        retries = 0

        let x = median(samples.map { Double($0.x) })
        let y = median(samples.map { Double($0.y) })

        let t = targets[targetIndex]

        observations.append(
            Observation(
                x: x,
                y: y,
                tx: Double(t.x),
                ty: Double(t.y)
            )
        )

        print(
            "Point \(targetIndex + 1):",
            "measured=(\(x), \(y))",
            "target=(\(t.x), \(t.y))",
            "samples=\(samples.count)"
        )

        targetIndex += 1

        if targetIndex >= targets.count {
            finishCalibration()
        } else {
            showTarget()
        }
    }

    // Solve a 3x3 linear system using Gaussian elimination
    // with partial pivoting.
    private func solve(
        _ matrix: [[Double]],
        _ rhs: [Double]
    ) -> [Double]? {
        var a = matrix
        var b = rhs

        for k in 0..<3 {
            var pivot = k

            for r in k..<3 {
                if abs(a[r][k]) > abs(a[pivot][k]) {
                    pivot = r
                }
            }

            if abs(a[pivot][k]) < 1e-10 {
                return nil
            }

            a.swapAt(k, pivot)
            b.swapAt(k, pivot)

            let divisor = a[k][k]

            for j in k..<3 {
                a[k][j] /= divisor
            }
            b[k] /= divisor

            for r in 0..<3 where r != k {
                let factor = a[r][k]

                for j in k..<3 {
                    a[r][j] -= factor * a[k][j]
                }

                b[r] -= factor * b[k]
            }
        }

        return b
    }

    private func fitCalibration() -> CalibrationData? {
        guard observations.count == 9 else {
            return nil
        }

        var ata = Array(
            repeating: Array(repeating: 0.0, count: 3),
            count: 3
        )

        var atx = [0.0, 0.0, 0.0]
        var aty = [0.0, 0.0, 0.0]

        for p in observations {
            let v = [1.0, p.x, p.y]

            for i in 0..<3 {
                atx[i] += v[i] * p.tx
                aty[i] += v[i] * p.ty

                for j in 0..<3 {
                    ata[i][j] += v[i] * v[j]
                }
            }
        }

        guard let a = solve(ata, atx),
              let b = solve(ata, aty) else {
            return nil
        }

        let width = Double(gazeView.bounds.width)
        let height = Double(gazeView.bounds.height)

        var squaredError = 0.0

        for p in observations {
            let px = a[0] + a[1] * p.x + a[2] * p.y
            let py = b[0] + b[1] * p.x + b[2] * p.y

            let dx = (px - p.tx) * width
            let dy = (py - p.ty) * height

            squaredError += dx * dx + dy * dy
        }

        let rms = sqrt(
            squaredError / Double(observations.count)
        )

        guard a.allSatisfy({ $0.isFinite }),
              b.allSatisfy({ $0.isFinite }),
              rms.isFinite else {
            return nil
        }

        return CalibrationData(
            xCoefficients: a,
            yCoefficients: b,
            rmsPoints: rms
        )
    }

    private func finishCalibration() {
        calibrating = false
        gazeView.target = nil
        gazeView.instruction = ""

        calibrationItem.isEnabled = true
        calibrationItem.title = "Calibrate (9 points)"

        guard let candidate = fitCalibration() else {
            showAlert(
                "Calibration failed",
                "Unable to fit a valid coordinate transform."
            )
            return
        }

        print("Calibration X:", candidate.xCoefficients)
        print("Calibration Y:", candidate.yCoefficients)
        print("Calibration RMS:", candidate.rmsPoints)

        let alert = NSAlert()
        alert.messageText = "Nine-point calibration complete"

        alert.informativeText = String(
            format:
                "Fitted RMS error: %.1f screen points.\n\n" +
                "Apply this software calibration?\n\n" +
                "The Tobii hardware calibration will not be changed.",
            candidate.rmsPoints
        )

        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Discard")

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try saveCalibration(candidate)
                calibration = candidate

                filteredPoint = nil
                gazeView.point = nil

                print(
                    "Saved:",
                    calibrationPath.path
                )
            } catch {
                showAlert(
                    "Could not save calibration",
                    error.localizedDescription
                )
            }
        }
    }

    private func cancelCalibration(_ message: String) {
        calibrating = false

        gazeView.target = nil
        gazeView.instruction = ""

        calibrationItem.isEnabled = true
        calibrationItem.title = "Calibrate (9 points)"

        showAlert("Calibration stopped", message)
    }

    private func showAlert(
        _ title: String,
        _ message: String
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func resetCalibration() {
        guard !calibrating else { return }

        do {
            let path = calibrationPath

            if FileManager.default.fileExists(
                atPath: path.path
            ) {
                try FileManager.default.removeItem(
                    at: path
                )
            }

            calibration = nil
            filteredPoint = nil
            gazeView.point = nil

            showAlert(
                "Software calibration reset",
                "TobiiBridge now uses raw gaze coordinates."
            )
        } catch {
            showAlert(
                "Reset failed",
                error.localizedDescription
            )
        }
    }

    @objc private func togglePause() {
        guard !calibrating else { return }

        paused.toggle()
        if paused { resetPresence("paused") }
        else { presenceLastSeen = Date() }
        filteredPoint = nil
        gazeView.point = nil

        pauseItem.title = paused
            ? "Resume tracking"
            : "Pause tracking"

        setIndicator(paused ? .paused : .connected)
    }


    // MARK: - USB recovery

    private func scheduleRetry() {
        guard !retryScheduled,
              !shuttingDown,
              !sleeping else {
            return
        }

        retryScheduled = true

        DispatchQueue.main.asyncAfter(
            deadline: .now() + reconnectDelay
        ) { [weak self] in
            guard let self else { return }

            self.retryScheduled = false

            guard !self.shuttingDown,
                  !self.sleeping,
                  self.nativeToken == nil else {
                return
            }

            self.startTracker()
        }
    }

    private func checkStreamHealth() {
        guard !restarting, let token = nativeToken,
              !token.isStopped, let last = lastFrameAt else { return }
        let silence = Date().timeIntervalSince(last)
        guard silence >= streamTimeout else { return }
        restarting = true
        abortCalibrationForDisconnect()
        NativeLogger.shared.write("No gaze frames for \(silence)s; stopping USB worker")
        setIndicator(.reconnecting)
        filteredPoint = nil
        gazeView.point = nil
        stopNativeTracker()
        // The worker completion is the ONLY place that can start a retry.
    }

    @objc private func willSleep(
        _ notification: Notification
    ) {
        print("System preparing to sleep")

        sleeping = true
        resetPresence("sleeping")

        // Do not save a partially completed calibration.
        // Existing calibration.json stays untouched.
        if calibrating {
            calibrating = false
            samples.removeAll()
            observations.removeAll()

            gazeView.target = nil
            gazeView.instruction = ""

            calibrationItem.isEnabled = true
            calibrationItem.title = "Calibrate (9 points)"
        }

        filteredPoint = nil
        gazeView.point = nil

        setIndicator(.sleeping)

        restarting = true
        stopNativeTracker()
    }

    @objc private func didWake(
        _ notification: Notification
    ) {
        print("System woke up")

        sleeping = false

        setIndicator(.reconnecting)

        if nativeToken != nil {
            restarting = true
            stopNativeTracker()
        } else {
            scheduleRetry()
        }
    }

    private func refreshStreamStats() {
        let now = Date()
        let elapsed = now.timeIntervalSince(statsStart)

        guard elapsed >= 1.0 else {
            return
        }

        let fps = Double(framesInWindow) / elapsed

        let validPercent = framesInWindow > 0
            ? Double(validFramesInWindow) /
              Double(framesInWindow) * 100.0
            : 0.0

        if framesInWindow == 0 {
            statsItem.title = "Stream: no gaze frames"
        } else {
            statsItem.title = String(
                format: "Stream: %.0f Hz · valid %.0f%%",
                fps,
                validPercent
            )
        }

        framesInWindow = 0
        validFramesInWindow = 0
        statsStart = now
    }

    @objc private func toggleGazeDot() {
        guard !calibrating else {
            return
        }

        dotVisible.toggle()
        preferences.set(dotVisible, forKey: "showGazeDot")
        dotItem.state = dotVisible ? .on : .off

        if dotVisible && !paused &&
           Date().timeIntervalSince(lastValidTime) < 0.35 {
            gazeView.point = filteredPoint
        } else {
            gazeView.point = nil
        }
    }

    @objc private func reconnectNow() {
        guard !shuttingDown, !sleeping, !calibrating else { return }
        NativeLogger.shared.write("Manual reconnect requested")
        resetPresence("reconnecting")
        filteredPoint = nil
        gazeView.point = nil
        lastFrameAt = nil
        abortCalibrationForDisconnect()
        setIndicator(.reconnecting)
        if nativeToken != nil {
            restarting = true
            stopNativeTracker()
        } else {
            startTracker()
        }
    }

    @objc private func openLog() {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Logs/TobiiBridge-Native.log"
            )

        guard FileManager.default.fileExists(
            atPath: url.path
        ) else {
            showAlert(
                "No log file",
                "The diagnostic log has not been created yet."
            )
            return
        }

        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        shuttingDown = true
        hardware.restore()
        if nativeToken != nil {
            exitReplyPending = true
            stopNativeTracker()
            // A stuck USB call must not prevent quitting indefinitely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
                guard let self, self.exitReplyPending else { return }
                NativeLogger.shared.write("USB worker stop timed out on quit")
                self.exitReplyPending = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(
        _ notification: Notification
    ) {
        shuttingDown = true
        hardware.restore()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

}

let app = NSApplication.shared
let delegate = BridgeApp()
app.delegate = delegate
app.run()
