import Foundation
import Ivy

public enum DNSSeeds: Sendable {
    public static let hostnames: [String] = [
        "seeds.lattice-node.net",
        "dnsseed.lattice.treehauslabs.com",
    ]

    public static func resolve() async -> [PeerEndpoint] {
        var peers: [PeerEndpoint] = []
        for hostname in hostnames {
            let resolved = await resolveTXT(hostname: hostname)
            if resolved.isEmpty {
                let fallback = await resolveA(hostname: hostname)
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

    private static func resolveA(hostname: String) async -> [PeerEndpoint] {
        guard let output = await runDig(type: "A", hostname: hostname) else {
            return []
        }
        var peers: [PeerEndpoint] = []
        for line in output.split(separator: "\n") {
            let ip = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty, ip.first?.isNumber == true else { continue }
            peers.append(PeerEndpoint(publicKey: "", host: ip, port: 4001))
        }
        return peers
    }

    private static func parsePeerRecord(_ record: String) -> PeerEndpoint? {
        let parts = record.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let pubKey = String(parts[0])
        let hostPort = parts[1].split(separator: ":", maxSplits: 1)
        guard hostPort.count == 2, let port = UInt16(hostPort[1]) else { return nil }
        return PeerEndpoint(publicKey: pubKey, host: String(hostPort[0]), port: port)
    }

    private static func runDig(type: String, hostname: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
                process.arguments = ["+short", hostname, type]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
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
