import Lattice
import Foundation
import Ivy

extension LatticeNode {

    func startPeerRefresh() async {
        let nexusDir = genesisConfig.spec.directory
        guard let network = networks[nexusDir] else { return }

        // Discovery-only nodes maintain more outbound connections to
        // maximize the routing table they can share with joining peers.
        let targetOutbound = config.discoveryOnly
            ? max(config.maxPeerConnections / 4, PeerDiversity.targetOutbound)
            : PeerDiversity.targetOutbound
        let refreshInterval = config.discoveryOnly ? 30 : 60

        let savedAnchors = await anchorPeers.load()
        for anchor in savedAnchors {
            try? await network.ivy.connect(to: anchor)
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(refreshInterval))
            guard !Task.isCancelled else { break }

            // Discover new peers via DHT random walk
            let discovered = await network.ivy.findNode(target: UUID().uuidString)

            // Separate actually-connected peers from all known peers in the routing table
            let connectedIDs = Set(await network.ivy.connectedPeers.map { $0.publicKey })
            let allKnown = await network.ivy.router.allPeers()
            let connectedEndpoints = allKnown
                .filter { connectedIDs.contains($0.id.publicKey) }
                .map { $0.endpoint }
            let connected = connectedEndpoints.count

            if connected < targetOutbound {
                // Use discovered peers + known-but-not-connected peers as candidates
                let unconnectedKnown = allKnown
                    .filter { !connectedIDs.contains($0.id.publicKey) }
                    .map { $0.endpoint }
                let candidates = discovered + unconnectedKnown
                let diverse = PeerDiversity.selectDiversePeers(
                    from: candidates,
                    existing: connectedEndpoints,
                    maxNew: targetOutbound - connected
                )
                for peer in diverse {
                    try? await network.ivy.connect(to: peer)
                }

                // If still short, try DNS seeds as fallback
                if connected + diverse.count < targetOutbound {
                    let dnsSeeds = await DNSSeeds.resolve()
                    let dnsCandidates = dnsSeeds.filter { !connectedIDs.contains($0.publicKey) }
                    let dnsSelection = PeerDiversity.selectDiversePeers(
                        from: dnsCandidates,
                        existing: connectedEndpoints,
                        maxNew: targetOutbound - connected - diverse.count
                    )
                    for peer in dnsSelection {
                        try? await network.ivy.connect(to: peer)
                    }
                }
            }

            // Prune overrepresented subnets and replace with diverse peers
            let overrepresented = PeerDiversity.findOverrepresentedPeers(peers: connectedEndpoints)
            if !overrepresented.isEmpty {
                let unconnectedKnown = allKnown
                    .filter { !connectedIDs.contains($0.id.publicKey) }
                    .map { $0.endpoint }
                let replacements = PeerDiversity.selectDiversePeers(
                    from: discovered + unconnectedKnown,
                    existing: connectedEndpoints,
                    maxNew: min(overrepresented.count, 2)
                )
                for peer in replacements {
                    try? await network.ivy.connect(to: peer)
                }
            }

            if connected >= 2 {
                let bestPeers = Array(connectedEndpoints.prefix(6))
                await anchorPeers.update(peers: bestPeers)
            }
        }
    }
}
