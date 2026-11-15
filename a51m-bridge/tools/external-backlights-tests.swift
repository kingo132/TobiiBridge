import Foundation

// State-machine tests suppress file logging and use no physical displays.
final class NativeLogger {
    static let shared = NativeLogger()
    func write(_ message: String) {}
}

final class TestBrightness: ExternalBrightnessEndpoint {
    let identity: String
    let name: String
    var generation: UInt64 = 1
    let quantum: Float = 0.01
    var value: Float
    var readable = true
    var writable = true
    var writes: [Float] = []
    init(_ identity: String, _ value: Float) { self.identity = identity; name = identity; self.value = value }
    func read() -> Float? { readable ? value : nil }
    func write(_ level: Float) -> Bool {
        guard writable else { return false }
        value = (level * 100).rounded() / 100
        writes.append(value)
        return true
    }
}

@main struct ExternalBacklightsTests {
    static func main() {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            passed += 1
            print("PASS: \(label)")
        }
        func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.011 }
        func reply(_ current: UInt16, _ maximum: UInt16) -> [UInt8] {
            var data: [UInt8] = [0x6e, 0x88, 2, 0, 0x10, 0, UInt8(maximum >> 8), UInt8(maximum & 255), UInt8(current >> 8), UInt8(current & 255)]
            data.append(data.reduce(UInt8(0x50), ^))
            return data
        }
        check(BrightnessPacket.get().reduce(UInt8(0x6e), ^) == 0, "DDC brightness query checksum")
        check(BrightnessPacket.set(513) == [0x51,0x84,3,0x10,2,1,0xab], "DDC write preserves high and low value bytes")
        check(BrightnessPacket.parse(reply(0,100))?.current == 0, "DDC zero brightness is supported")
        check(BrightnessPacket.parse(reply(513,1023))?.current == 513, "DDC reply values do not overflow at 255")
        var corrupt = reply(10,100); corrupt[10] ^= 1
        check(BrightnessPacket.parse(corrupt) == nil, "corrupt DDC reply rejected")
        check(BrightnessPacket.parse(reply(0,0)) == nil, "zero DDC maximum rejected")
        check(BrightnessPacket.parse(reply(101,100)) == nil, "out-of-range DDC current rejected")
        check(BrightnessPacket.parse(Array(reply(10,100).prefix(10))) == nil, "truncated DDC reply rejected")

        let low = TestBrightness("minimum", 0)
        let minimum = ExternalDimState(low)
        minimum.dim(to: 0.1, duration: 0, now: 0)
        minimum.restore(duration: 0, now: 1)
        check(low.writes.isEmpty && low.value == 0, "minimum screen is never brightened to the target")
        let below = TestBrightness("below", 0.06)
        ExternalDimState(below).dim(to: 0.1, duration: 0, now: 0)
        check(below.writes.isEmpty, "below-target screen receives no brightness writes")

        let a = TestBrightness("A", 0.8), b = TestBrightness("B", 0.3)
        let first = ExternalDimState(a), second = ExternalDimState(b)
        first.dim(to: 0.1, duration: 0, now: 0)
        second.dim(to: 0.1, duration: 0, now: 0)
        check(close(a.value,0.1) && close(b.value,0.1), "multiple screens dim to the absolute target")
        first.restore(duration: 0, now: 1); second.restore(duration: 0, now: 1)
        check(close(a.value,0.8) && close(b.value,0.3), "each screen restores its own baseline")
        first.dim(to: 0.1, duration: 0, now: 2)
        check(close(a.value,0.1), "a second absence cycle can dim again")
        first.restore(duration: 0, now: 3)
        check(close(a.value,0.8), "second cycle retains the correct baseline")

        let fadeIO = TestBrightness("fade",0.8)
        let transition = ExternalDimState(fadeIO)
        transition.dim(to: 0.1, duration: 2, now: 0)
        transition.advance(now: 1)
        check(close(fadeIO.value,0.45), "smooth dim progresses between endpoints")
        transition.restore(duration: 0.5, now: 1)
        transition.advance(now: 1.5)
        check(close(fadeIO.value,0.8) && !transition.active, "gaze return reverses an unfinished dim fade")
        transition.dim(to:0.1,duration:0,now:2)
        fadeIO.value = 0
        let beforeOverride = fadeIO.writes.count
        transition.advance(now: 2.2)
        transition.restore(duration: 0, now: 2.5)
        check(fadeIO.value == 0 && fadeIO.writes.count == beforeOverride, "manual zero override is preserved during restore")

        let badIO = TestBrightness("failure",0.8), goodIO = TestBrightness("healthy",0.6)
        badIO.writable = false
        let bad = ExternalDimState(badIO), good = ExternalDimState(goodIO)
        bad.dim(to:0.1,duration:0,now:0); good.dim(to:0.1,duration:0,now:0)
        check(close(goodIO.value,0.1) && close(badIO.value,0.8), "one screen's write failure does not affect another screen")
        badIO.writable = true; bad.advance(now:2)
        check(close(badIO.value,0.8) && !bad.active, "failed dim safely clears ownership after baseline confirmation")
        goodIO.readable = false; good.restore(duration:0,now:1)
        check(good.active, "temporary restore read failure retains the original brightness")
        goodIO.readable = true; good.advance(now:3)
        check(close(goodIO.value,0.6) && !good.active, "pending restoration completes when reads recover")

        let old = TestBrightness("stable-id",0.7)
        let replacement = ExternalDimState(old)
        replacement.dim(to:0.1,duration:0,now:0)
        let new = TestBrightness("stable-id",0.1); new.generation = 2
        replacement.rebind(new)
        replacement.restore(duration:0,now:1)
        check(close(new.value,0.7), "replacement endpoint preserves its screen's restoration baseline")
        print("\(passed) external backlight checks passed")
    }
}
