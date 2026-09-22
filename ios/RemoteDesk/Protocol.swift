import Foundation

enum MsgType: UInt8 {
    case video = 1
    case pong = 2
    case info = 3
    case hello = 10
    case mouseAbs = 11
    case mouseRel = 12
    case button = 13
    case wheel = 14
    case key = 15
    case text = 16
    case ping = 17
}

enum Proto {
    static let defaultPort: UInt16 = 47000
    static let discoveryPort: UInt16 = 47001

    static func frame(_ type: MsgType, _ payload: Data) -> Data {
        var d = Data(capacity: payload.count + 5)
        d.append(type.rawValue)
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    static func mouseAbs(_ nx: Double, _ ny: Double) -> Data {
        let x = UInt16(max(0, min(65535, (nx * 65535).rounded())))
        let y = UInt16(max(0, min(65535, (ny * 65535).rounded())))
        var d = Data(capacity: 4)
        append(&d, x.littleEndian)
        append(&d, y.littleEndian)
        return d
    }

    static func mouseRel(_ dx: Int, _ dy: Int) -> Data {
        var d = Data(capacity: 4)
        append(&d, Int16(clamping: dx).littleEndian)
        append(&d, Int16(clamping: dy).littleEndian)
        return d
    }

    static func button(_ button: Int, down: Bool) -> Data {
        return Data([UInt8(clamping: button), down ? 1 : 0])
    }

    static func wheel(dy: Int, dx: Int) -> Data {
        var d = Data(capacity: 4)
        append(&d, Int16(clamping: dy).littleEndian)
        append(&d, Int16(clamping: dx).littleEndian)
        return d
    }

    static func key(_ vk: UInt16, down: Bool) -> Data {
        var d = Data(capacity: 3)
        append(&d, vk.littleEndian)
        d.append(down ? 1 : 0)
        return d
    }

    static func text(_ s: String) -> Data {
        return Data(s.utf8)
    }

    static func ping(_ t: UInt64) -> Data {
        var d = Data(capacity: 8)
        append(&d, t.littleEndian)
        return d
    }

    static func hello(pin: String) -> Data {
        let obj: [String: Any] = ["pin": pin, "client": "ios", "version": 1]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    private static func append<T: FixedWidthInteger>(_ d: inout Data, _ v: T) {
        var v = v
        withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
    }
}
