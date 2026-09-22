import Foundation
import Network

final class Connection {
    var onInfo: (([String: Any]) -> Void)?
    var onVideo: ((Data, Bool) -> Void)?
    var onPong: ((UInt64) -> Void)?
    var onReady: (() -> Void)?
    var onFailed: ((String) -> Void)?

    private let conn: NWConnection
    private let queue = DispatchQueue(label: "rdesk.net", qos: .userInteractive)
    private let pin: String
    private var closed = false
    private var ready = false
    private(set) var bytesReceived: Int = 0

    init(host: String, port: UInt16, pin: String) {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 5
        }
        params.serviceClass = .interactiveVideo
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 47000, using: params)
        self.pin = pin
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.send(.hello, Proto.hello(pin: self.pin))
                self.readHeader()
                self.onReady?()
            case .failed(let err):
                self.fail("接続に失敗しました: \(err.localizedDescription)")
            case .waiting:
                self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, !self.ready else { return }
                    self.fail("接続できません。同じ Wi-Fi か、ローカルネットワークの許可を確認してください")
                }
            case .cancelled:
                self.fail("切断されました")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func close() {
        closed = true
        conn.cancel()
    }

    func send(_ type: MsgType, _ payload: Data = Data()) {
        if closed { return }
        conn.send(content: Proto.frame(type, payload), completion: .contentProcessed { _ in })
    }

    private func fail(_ msg: String) {
        if closed { return }
        closed = true
        conn.cancel()
        onFailed?(msg)
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.fail("受信エラー: \(error.localizedDescription)")
                return
            }
            guard let data, data.count == 5 else {
                self.fail("ホストとの接続が切れました")
                return
            }
            let type = data[data.startIndex]
            let len = data.withUnsafeBytes { raw -> UInt32 in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
            }
            if len == 0 {
                self.dispatch(type, Data())
                self.readHeader()
            } else if len > 32 * 1024 * 1024 {
                self.fail("不正なデータを受信しました")
            } else {
                self.readBody(type, Int(len))
            }
        }
    }

    private func readBody(_ type: UInt8, _ len: Int) {
        conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.fail("受信エラー: \(error.localizedDescription)")
                return
            }
            guard let data, data.count == len else {
                self.fail("ホストとの接続が切れました")
                return
            }
            self.bytesReceived += len + 5
            self.dispatch(type, data)
            self.readHeader()
        }
    }

    private func dispatch(_ type: UInt8, _ payload: Data) {
        switch MsgType(rawValue: type) {
        case .video:
            guard payload.count > 4 else { return }
            let flags = payload.withUnsafeBytes { raw -> UInt32 in
                UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
            }
            onVideo?(payload.subdata(in: (payload.startIndex + 4)..<payload.endIndex), flags & 1 != 0)
        case .pong:
            guard payload.count >= 8 else { return }
            let t = payload.withUnsafeBytes { raw -> UInt64 in
                UInt64(littleEndian: raw.loadUnaligned(as: UInt64.self))
            }
            onPong?(t)
        case .info:
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                if let err = obj["error"] as? String {
                    fail("ホストが接続を拒否しました: \(err)")
                } else {
                    onInfo?(obj)
                }
            }
        default:
            break
        }
    }
}
