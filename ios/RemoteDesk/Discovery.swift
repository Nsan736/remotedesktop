import Foundation
import Darwin

struct DiscoveredHost: Identifiable, Hashable {
    let name: String
    let ip: String
    let port: UInt16
    var id: String { "\(ip):\(port)" }
}

enum Discovery {
    private static let magic = "RDESK_DISCOVER_V1"
    private static let replyPrefix = "RDESK_HERE_V1"

    static func search(timeout: TimeInterval = 1.5, completion: @escaping ([DiscoveredHost]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = searchSync(timeout: timeout)
            DispatchQueue.main.async { completion(found) }
        }
    }

    static func searchSync(timeout: TimeInterval) -> [DiscoveredHost] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(Proto.discoveryPort).bigEndian
        dest.sin_addr.s_addr = in_addr_t(0xFFFF_FFFF)

        let msg = Array(magic.utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &dest) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, msg, msg.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            usleep(50_000)
        }

        var results: [DiscoveredHost] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 2048)
        let prefixLen = replyPrefix.utf8.count

        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                }
            }
            if n <= prefixLen { continue }
            let data = Data(buf[0..<n])
            guard String(decoding: data.prefix(prefixLen), as: UTF8.self) == replyPrefix else { continue }
            let json = data.dropFirst(prefixLen)
            guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            let port = UInt16(clamping: (obj["port"] as? Int) ?? Int(Proto.defaultPort))
            let name = (obj["name"] as? String) ?? ip
            let host = DiscoveredHost(name: name, ip: ip, port: port)
            if !results.contains(host) { results.append(host) }
        }
        return results
    }
}
