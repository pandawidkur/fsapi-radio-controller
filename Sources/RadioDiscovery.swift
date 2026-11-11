import Foundation

/// A Frontier Silicon (FSAPI / UNDOK-compatible) radio found on the local network.
struct DiscoveredRadio: Identifiable, Equatable {
    var id: String { ip }
    let ip: String
    let name: String        // friendly name (needs the right PIN) or the descriptor's name
    let module: String      // Frontier module from the firmware string, e.g. "FS2340"
    let firmware: String
    let pinOK: Bool
}

/// Finds FSAPI radios: probes `http://<ip>/device` (no PIN needed) on the Mac's /24 subnet(s),
/// then reads the friendly name with the PIN to check that it is correct.
enum RadioDiscovery {
    /// IPv4 /24 prefixes of the Mac's active interfaces, e.g. ["192.168.0"].
    static func localSubnets() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254"), !ip.hasPrefix("100.") else { continue }   // link-local, CGNAT/VPN
            let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
            if !result.contains(prefix) { result.append(prefix) }
        }
        return result
    }

    /// Checks one address; nil when no FSAPI radio answers there.
    static func probe(_ ip: String, pin: String, timeout: TimeInterval = 1.5) async -> DiscoveredRadio? {
        guard let url = URL(string: "http://\(ip)/device") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        guard xml.contains("webfsapi") || xml.contains("netRemote") else { return nil }
        let firmware = tag("version", in: xml) ?? ""
        let module = firmware.range(of: #"FS\d{4}"#, options: .regularExpression).map { String(firmware[$0]) } ?? "FSAPI"
        // Friendly name with the PIN: 403 means a wrong PIN.
        var name = tag("friendlyName", in: xml) ?? ip
        var pinOK = false
        if let nameURL = URL(string: "http://\(ip)/fsapi/GET/netRemote.sys.info.friendlyName?pin=\(pin)") {
            var r = URLRequest(url: nameURL)
            r.timeoutInterval = timeout + 1
            if let (d, rs) = try? await URLSession.shared.data(for: r), (rs as? HTTPURLResponse)?.statusCode == 200 {
                let body = String(decoding: d, as: UTF8.self)
                if body.contains("FS_OK") {
                    pinOK = true
                    if let n = body.range(of: #"(?<=<c8_array>).*?(?=</c8_array>)"#, options: .regularExpression) {
                        name = String(body[n])
                    }
                }
            }
        }
        return DiscoveredRadio(ip: ip, name: name, module: module, firmware: firmware, pinOK: pinOK)
    }

    /// Scans the local /24 subnet(s); calls `found` for each radio as soon as it answers.
    static func scan(pin: String, found: @escaping (DiscoveredRadio) -> Void) async {
        await withTaskGroup(of: DiscoveredRadio?.self) { group in
            for prefix in localSubnets() {
                for i in 1...254 {
                    group.addTask { await probe("\(prefix).\(i)", pin: pin) }
                }
            }
            for await radio in group {
                if let r = radio { await MainActor.run { found(r) } }
            }
        }
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let r = xml.range(of: "(?<=<\(name)>).*?(?=</\(name)>)", options: .regularExpression) else { return nil }
        return String(xml[r])
    }
}
