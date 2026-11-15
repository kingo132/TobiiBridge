import Foundation
import AppKit
import CoreGraphics
import IOKit
import IOKit.graphics
import IOKit.i2c

// DDC/CI brightness only (VCP 0x10). No power/input/reset commands and no gamma.
// Packet format cross-checked against MonitorControl's IntelDDC implementation.
enum BrightnessPacket {
    static func get() -> [UInt8] { [0x51, 0x82, 0x01, 0x10, 0xac] }
    static func set(_ value: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0x51, 0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 255)]
        bytes.append(bytes.reduce(UInt8(0x6e), ^))
        return bytes
    }
    static func parse(_ bytes: [UInt8]) -> (current: UInt16, maximum: UInt16)? {
        guard bytes.count == 11, bytes[0] == 0x6e, bytes[1] == 0x88,
              bytes[2] == 2, bytes[3] == 0, bytes[4] == 0x10,
              bytes.reduce(UInt8(0x50), ^) == 0 else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }
}

protocol ExternalBrightnessEndpoint: AnyObject {
    var identity: String { get }
    var name: String { get }
    var generation: UInt64 { get }
    var quantum: Float { get }
    func read() -> Float?
    func write(_ level: Float) -> Bool
}

final class FramebufferBrightnessEndpoint: ExternalBrightnessEndpoint {
    let identity: String
    let name: String
    let framebuffer: io_service_t
    let ddc: Bool
    let generation: UInt64
    private var bus: IOOptionBits?
    private var replyType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
    private var maximum: UInt16 = 100
    var quantum: Float { ddc ? 1 / Float(maximum) : 1 / 1024 }

    // Takes ownership of an already-retained framebuffer.
    init(framebuffer: io_service_t, identity: String, name: String, ddc: Bool) {
        self.framebuffer = framebuffer
        self.identity = identity
        self.name = name
        self.ddc = ddc
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(framebuffer, &registryID)
        generation = registryID
    }
    deinit { IOObjectRelease(framebuffer) }

    private func transact(_ payload: [UInt8], reading: Bool) -> [UInt8]? {
        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS else { return nil }
        let candidates = bus.map { [$0] } ?? Array(0..<busCount)
        for candidate in candidates {
            var interface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(framebuffer, candidate, &interface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(interface) }
            let types = (IORegistryEntryCreateCFProperty(interface, kIOI2CTransactionTypesKey as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint32Value ?? 0
            let replies: [IOOptionBits] = bus != nil ? [replyType] :
                [IOOptionBits(kIOI2CDDCciReplyTransactionType), IOOptionBits(kIOI2CSimpleTransactionType)]
                    .filter { types & (1 << $0) != 0 }
            var connection: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, 0, &connection) == KERN_SUCCESS else { continue }
            defer { IOI2CInterfaceClose(connection, 0) }
            for reply in reading ? replies : [IOOptionBits(kIOI2CNoTransactionType)] {
                var tx = payload
                var rx = [UInt8](repeating: 0, count: reading ? 11 : 1)
                var request = IOI2CRequest()
                request.sendAddress = 0x6e
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendBytes = UInt32(tx.count)
                request.replyAddress = 0x6f
                request.replySubAddress = 0x51
                request.replyTransactionType = reply
                request.replyBytes = reading ? 11 : 0
                var timebase = mach_timebase_info_data_t()
                mach_timebase_info(&timebase)
                request.minReplyDelay = 40_000_000 * UInt64(timebase.denom) / UInt64(timebase.numer)
                let sent = tx.withUnsafeMutableBytes { send in
                    rx.withUnsafeMutableBytes { receive in
                        request.sendBuffer = vm_address_t(UInt(bitPattern: send.baseAddress!))
                        request.replyBuffer = vm_address_t(UInt(bitPattern: receive.baseAddress!))
                        return IOI2CSendRequest(connection, 0, &request)
                    }
                }
                guard sent == KERN_SUCCESS, request.result == KERN_SUCCESS else { continue }
                if reading && (request.replyBytes != 11 || BrightnessPacket.parse(rx) == nil) { continue }
                if reading { bus = candidate; replyType = reply }
                return reading ? rx : []
            }
        }
        return nil
    }

    func read() -> Float? {
        if ddc {
            var response = transact(BrightnessPacket.get(), reading: true)
            if response == nil {
                // A busy monitor or a changed bus must not strand a cached bus.
                bus = nil
                Thread.sleep(forTimeInterval: 0.04)
                response = transact(BrightnessPacket.get(), reading: true)
            }
            guard let reply = response,
                  let result = BrightnessPacket.parse(reply) else { return nil }
            maximum = result.maximum
            return Float(result.current) / Float(result.maximum)
        }
        var value: Float = -1
        guard IODisplayGetFloatParameter(framebuffer, 0, "brightness" as CFString, &value) == KERN_SUCCESS,
              value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
    func write(_ level: Float) -> Bool {
        guard level.isFinite, (0...1).contains(level) else { return false }
        if ddc {
            let value = UInt16((level * Float(maximum)).rounded())
            let sent = transact(BrightnessPacket.set(value), reading: false) != nil
            if !sent { bus = nil }
            return sent
        }
        return IODisplaySetFloatParameter(framebuffer, 0, "brightness" as CFString, level) == KERN_SUCCESS
    }

    static func discover() -> [ExternalBrightnessEndpoint] {
        var online = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &online, &count) == .success else { return [] }
        let external = online.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [ExternalBrightnessEndpoint] = []
        while true {
            let fb = IOIteratorNext(iterator)
            if fb == 0 { break }
            guard let ref = IODisplayCreateInfoDictionary(fb, IOOptionBits(kIODisplayOnlyPreferredName)) else { IOObjectRelease(fb); continue }
            let info = ref.takeRetainedValue() as NSDictionary
            let vendor = (info[kDisplayVendorID] as? NSNumber)?.uint32Value
            let model = (info[kDisplayProductID] as? NSNumber)?.uint32Value
            let serial = (info[kDisplaySerialNumber] as? NSNumber)?.uint32Value ?? 0
            let matches = external.filter {
                CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == model && CGDisplaySerialNumber($0) == serial
            }
            // An ambiguous match must not target a different screen.
            guard matches.count == 1 else { IOObjectRelease(fb); continue }
            let names = info[kDisplayProductName] as? [String: String]
            let name = names?["en_US"] ?? names?.values.first ?? "External display"
            var nativeValue: Float = -1
            let native = IODisplayGetFloatParameter(fb, 0, "brightness" as CFString, &nativeValue) == KERN_SUCCESS
                && nativeValue.isFinite && (0...1).contains(nativeValue)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(matches[0]) else { IOObjectRelease(fb); continue }
            let identity = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
            let endpoint = FramebufferBrightnessEndpoint(framebuffer: fb, identity: identity, name: name, ddc: !native)
            if endpoint.read() != nil { found.append(endpoint) }
        }
        return found
    }
}

// Per-screen state machine, isolated from IOKit so restoration and ownership can
// be tested without changing a physical display. Used only on the worker queue.
final class ExternalDimState {
    private(set) var endpoint: ExternalBrightnessEndpoint
    private(set) var baseline: Float?
    private var expected: Float?
    private var fade: (from: Float, to: Float, start: TimeInterval, duration: TimeInterval, restoring: Bool)?
    private var retryAt: TimeInterval = 0
    private var failed = false
    var active: Bool { baseline != nil }
    init(_ endpoint: ExternalBrightnessEndpoint) { self.endpoint = endpoint }
    func rebind(_ endpoint: ExternalBrightnessEndpoint) {
        self.endpoint = endpoint
        retryAt = 0
    }
    private var tolerance: Float { max(0.005, endpoint.quantum * 1.1) }

    func dim(to level: Float, duration: TimeInterval, now: TimeInterval) {
        guard !failed else { return }
        guard let current = endpoint.read() else { return }
        if baseline == nil {
            // An absolute target is a ceiling, never a request to brighten.
            guard current > level + endpoint.quantum / 2 else { return }
            baseline = current
            expected = current
        }
        guard let baseline else { return }
        fade = (current, min(level, baseline), now, duration, false)
        advance(now: now)
    }
    func restore(duration: TimeInterval, now: TimeInterval) {
        guard let baseline else { failed = false; return }
        guard let current = endpoint.read() else {
            failed = false
            fade = (expected ?? baseline, baseline, now, duration, true)
            retryAt = now + 1
            return
        }
        if let expected, abs(current - expected) > tolerance { relinquish(); return }
        failed = false
        fade = (current, baseline, now, duration, true)
        retryAt = 0
        advance(now: now)
    }
    func advance(now: TimeInterval) {
        guard baseline != nil, !failed, now >= retryAt else { return }
        guard let current = endpoint.read() else { retryAt = now + 1; return }
        if let expected, abs(current - expected) > tolerance {
            NativeLogger.shared.write("External smart dim released after brightness change/readback mismatch: \(endpoint.name)")
            relinquish()
            return
        }
        guard let fade else { return }
        let t = fade.duration <= 0 ? 1 : min(1, max(0, (now - fade.start) / fade.duration))
        let eased = Float(t * t * (3 - 2 * t))
        let target = fade.from + (fade.to - fade.from) * eased
        if abs(current - target) >= endpoint.quantum / 2 {
            guard endpoint.write(target) else {
                retryAt = now + 1
                if !fade.restoring {
                    // Stop dimming on failure; retain the baseline for restore.
                    self.fade = (current, baseline!, now, 0, true)
                }
                return
            }
            expected = (target / endpoint.quantum).rounded() * endpoint.quantum
        }
        if t >= 1 {
            guard let readback = endpoint.read(), abs(readback - target) <= tolerance else { retryAt = now + 0.25; return }
            self.fade = nil
            if fade.restoring {
                NativeLogger.shared.write("External brightness restored: \(endpoint.name) to \(Int(readback * 100))%")
                relinquish(suppress: false)
            }
        }
    }
    private func relinquish(suppress: Bool = true) {
        baseline = nil; expected = nil; fade = nil; failed = suppress
    }
}

// I2C is comparatively slow. Discovery, fades and verification never run on
// AppKit's thread, and duplicate gaze/timer commands never build up a queue.
final class ExternalBacklights: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.tobiibridge.external-backlights", qos: .utility)
    private let lock = NSLock()
    private var names: [String] = []
    private var devices: [String: ExternalDimState] = [:] // worker only
    private var timer: DispatchSourceTimer?
    private var lastDiscovery: TimeInterval = 0
    private var desired: (Float, TimeInterval)? // AppKit only
    private var workerDesired: (Float, TimeInterval)? // worker only
    private let enabled: Bool
    var displayNames: [String] { lock.lock(); defer { lock.unlock() }; return names }

    init(enabled: Bool = true) {
        self.enabled = enabled
        guard enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }
    deinit { timer?.cancel() }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDiscovery >= 15 { discover(now: now) }
        for device in devices.values { device.advance(now: now) }
    }
    private func discover(now: TimeInterval) {
        lastDiscovery = now
        let next = FramebufferBrightnessEndpoint.discover()
        let ids = Set(next.map { $0.identity })
        for (id, device) in devices where !ids.contains(id) {
            device.restore(duration: 0, now: now)
            // Keep a pending restoration until a readable endpoint returns.
            if !device.active { devices.removeValue(forKey: id) }
        }
        for endpoint in next {
            if let existing = devices[endpoint.identity] {
                if existing.endpoint.generation != endpoint.generation { existing.rebind(endpoint) }
            } else {
                let state = ExternalDimState(endpoint)
                devices[endpoint.identity] = state
                if let intent = workerDesired { state.dim(to: intent.0, duration: intent.1, now: now) }
                NativeLogger.shared.write("External smart dim ready: \(endpoint.name)")
            }
        }
        lock.lock(); names = next.map { $0.name }.sorted(); lock.unlock()
    }
    func refresh() {
        guard enabled else { return }
        queue.async { [weak self] in self?.discover(now: ProcessInfo.processInfo.systemUptime) }
    }
    func dim(to level: Float, duration: TimeInterval) {
        guard enabled else { return }
        if let desired, desired.0 == level && desired.1 == duration { return }
        desired = (level, duration)
        queue.async { [weak self] in
            guard let self else { return }
            self.workerDesired = (level, duration)
            let now = ProcessInfo.processInfo.systemUptime
            for device in self.devices.values { device.dim(to: level, duration: duration, now: now) }
        }
    }
    func restore(duration: TimeInterval = 0) {
        guard enabled, desired != nil else { return }
        desired = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.workerDesired = nil
            let now = ProcessInfo.processInfo.systemUptime
            for device in self.devices.values { device.restore(duration: duration, now: now) }
        }
    }
    func restoreBeforeTransition() {
        guard enabled else { return }
        desired = nil
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            workerDesired = nil
            let now = ProcessInfo.processInfo.systemUptime
            for device in devices.values { device.restore(duration: 0, now: now) }
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            NativeLogger.shared.write("External brightness restoration still pending after 2s")
        }
    }
}
