import Foundation
import Ivy

public struct PeerDiversity: Sendable {

    public enum ConnectionType: String, Sendable {
        case inbound
        case outbound
        case blockRelayOnly
    }

    public static let maxPerSubnet: Int = 2
    public static let targetOutbound: Int = 8
    public static let targetBlockRelayOnly: Int = 2

    public static func subnet(_ ip: String) -> String {
        let parts = ip.split(separator: ".")
        guard parts.count >= 2 else { return ip }
        return "\(parts[0]).\(parts[1])"
    }

    public static func shouldConnect(
        to peer: PeerEndpoint,
        existingPeers: [PeerEndpoint]
    ) -> Bool {
        let targetSubnet = subnet(peer.host)
        let sameSubnet = existingPeers.filter { subnet($0.host) == targetSubnet }
        return sameSubnet.count < maxPerSubnet
    }

    public static func selectDiversePeers(
        from candidates: [PeerEndpoint],
        existing: [PeerEndpoint],
        maxNew: Int
    ) -> [PeerEndpoint] {
        var selected: [PeerEndpoint] = []
        var subnetCounts: [String: Int] = [:]

        for peer in existing {
            let s = subnet(peer.host)
            subnetCounts[s, default: 0] += 1
        }

        for candidate in candidates.shuffled() {
            guard selected.count < maxNew else { break }
            let s = subnet(candidate.host)
            let currentCount = subnetCounts[s, default: 0]
            if currentCount < maxPerSubnet {
                selected.append(candidate)
                subnetCounts[s, default: 0] += 1
            }
        }

        return selected
    }

    public static func findOverrepresentedPeers(
        peers: [PeerEndpoint]
    ) -> [PeerEndpoint] {
        var subnetGroups: [String: [PeerEndpoint]] = [:]
        for peer in peers {
            let s = subnet(peer.host)
            subnetGroups[s, default: []].append(peer)
        }

        var toDisconnect: [PeerEndpoint] = []
        for (_, group) in subnetGroups {
            if group.count > maxPerSubnet {
                toDisconnect.append(contentsOf: group.dropFirst(maxPerSubnet))
            }
        }
        return toDisconnect
    }
}
