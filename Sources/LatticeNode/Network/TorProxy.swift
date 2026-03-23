import Foundation

public struct ProxyConfig: Sendable {
    public let type: ProxyType
    public let host: String
    public let port: UInt16

    public enum ProxyType: String, Sendable {
        case socks5
        case tor
    }

    public static let defaultTor = ProxyConfig(type: .tor, host: "127.0.0.1", port: 9050)

    public static func parse(_ urlString: String) -> ProxyConfig? {
        let parts = urlString.split(separator: "://", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let scheme = String(parts[0]).lowercased()
        guard let proxyType = ProxyType(rawValue: scheme) else { return nil }

        let hostPort = parts[1].split(separator: ":", maxSplits: 1)
        guard !hostPort.isEmpty else { return nil }

        let host = String(hostPort[0])
        let port: UInt16
        if hostPort.count > 1, let p = UInt16(hostPort[1]) {
            port = p
        } else {
            port = proxyType == .tor ? 9050 : 1080
        }

        return ProxyConfig(type: proxyType, host: host, port: port)
    }
}

public enum SOCKS5 {

    public enum AuthMethod: UInt8 {
        case noAuth = 0x00
        case usernamePassword = 0x02
        case noAcceptable = 0xFF
    }

    public enum Command: UInt8 {
        case connect = 0x01
        case bind = 0x02
        case udpAssociate = 0x03
    }

    public enum AddressType: UInt8 {
        case ipv4 = 0x01
        case domainName = 0x03
        case ipv6 = 0x04
    }

    public static func buildGreeting(methods: [AuthMethod] = [.noAuth]) -> Data {
        var data = Data()
        data.append(0x05)
        data.append(UInt8(methods.count))
        for method in methods {
            data.append(method.rawValue)
        }
        return data
    }

    public static func parseGreetingResponse(_ data: Data) -> AuthMethod? {
        guard data.count >= 2, data[0] == 0x05 else { return nil }
        return AuthMethod(rawValue: data[1])
    }

    public static func buildConnectRequest(host: String, port: UInt16) -> Data {
        var data = Data()
        data.append(0x05)
        data.append(Command.connect.rawValue)
        data.append(0x00)

        if let ipv4 = parseIPv4(host) {
            data.append(AddressType.ipv4.rawValue)
            data.append(contentsOf: ipv4)
        } else {
            data.append(AddressType.domainName.rawValue)
            let hostBytes = Array(host.utf8)
            data.append(UInt8(hostBytes.count))
            data.append(contentsOf: hostBytes)
        }

        data.append(UInt8(port >> 8))
        data.append(UInt8(port & 0xFF))
        return data
    }

    public static func parseConnectResponse(_ data: Data) -> Bool {
        guard data.count >= 4, data[0] == 0x05 else { return false }
        return data[1] == 0x00
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return parts
    }
}
