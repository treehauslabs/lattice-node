import Foundation
import Ivy

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DNSSeeds: Sendable {
    public static let hostnames: [String] = [
        "seeds.lattice-node.net",
        "dnsseed.lattice.treehauslabs.com",
    ]

    private static let digTimeout: TimeInterval = 5

    public static func resolve() async -> [PeerEndpoint] {
        var peers: [PeerEndpoint] = []
        for hostname in hostnames {
            let resolved = await resolveTXT(hostname: hostname)
            if resolved.isEmpty {
                let fallback = resolveA(hostname: hostname)
                peers.append(contentsOf: fallback)
            } else {
                peers.append(contentsOf: resolved)
            }
        }
        var seen = Set<String>()
        return peers.filter {
            let key = "\($0.host):\($0.port)"
            return seen.insert(key).inserted
        }
    }

    private static func resolveTXT(hostname: String) async -> [PeerEndpoint] {
        guard let output = await runDig(type: "TXT", hostname: hostname) else {
            return []
        }
        var peers: [PeerEndpoint] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let peer = parsePeerRecord(trimmed) {
                peers.append(peer)
            }
        }
        return peers
    }

    /// Resolve A records using POSIX getaddrinfo instead of shelling out to dig.
    static func resolveA(hostname: String) -> [PeerEndpoint] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        guard status == 0, let firstResult = result else { return [] }
        defer { freeaddrinfo(firstResult) }

        var peers: [PeerEndpoint] = []
        var seen = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = firstResult

        while let info = current {
            if info.pointee.ai_family == AF_INET,
               let addr = info.pointee.ai_addr {
                addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockAddr in
                    var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var inAddr = sockAddr.pointee.sin_addr
                    if let ipStr = inet_ntop(AF_INET, &inAddr, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) {
                        let ip = String(cString: ipStr)
                        if seen.insert(ip).inserted {
                            peers.append(PeerEndpoint(publicKey: "", host: ip, port: 4001))
                        }
                    }
                }
            }
            current = info.pointee.ai_next
        }
        return peers
    }

    static func parsePeerRecord(_ record: String) -> PeerEndpoint? {
        let parts = record.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let pubKey = String(parts[0])
        let hostPort = parts[1].split(separator: ":", maxSplits: 1)
        guard hostPort.count == 2, let port = UInt16(hostPort[1]) else { return nil }
        return PeerEndpoint(publicKey: pubKey, host: String(hostPort[0]), port: port)
    }

    /// Run dig with a timeout. Returns nil if dig is not available or times out.
    private static func runDig(type: String, hostname: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let digPath = "/usr/bin/dig"
                guard FileManager.default.isExecutableFile(atPath: digPath) else {
                    continuation.resume(returning: nil)
                    return
                }

                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: digPath)
                process.arguments = ["+short", "+time=3", "+tries=1", hostname, type]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                // Kill after timeout
                let deadline = DispatchTime.now() + digTimeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning { process.terminate() }
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
