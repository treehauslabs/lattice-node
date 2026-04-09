import Lattice
import Foundation
import Ivy

extension LatticeNode {

    func startPeerRefresh() async {
        let nexusDir = genesisConfig.spec.directory
        guard let network = networks[nexusDir] else { return }

        let savedAnchors = await anchorPeers.load()
        for anchor in savedAnchors {
            try? await network.ivy.connect(to: anchor)
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { break }

            let randomTarget = UUID().uuidString
            let _ = await network.ivy.findNode(target: randomTarget)

            let allKnown = await network.ivy.router.allPeers()
            let connectedPeers = allKnown.map { $0.endpoint }
            let connected = connectedPeers.count
            let connectedKeys = Set(connectedPeers.map { $0.publicKey })

            if connected < PeerDiversity.targetOutbound {
                let candidates = connectedPeers
                let diverse = PeerDiversity.selectDiversePeers(
                    from: candidates,
                    existing: connectedPeers,
                    maxNew: PeerDiversity.targetOutbound - connected
                )
                for peer in diverse {
                    try? await network.ivy.connect(to: peer)
                }
            }

            let overrepresented = PeerDiversity.findOverrepresentedPeers(peers: connectedPeers)
            if !overrepresented.isEmpty {
                let candidates = connectedPeers
                    .filter { !connectedKeys.contains($0.publicKey) }
                let replacements = PeerDiversity.selectDiversePeers(
                    from: candidates,
                    existing: connectedPeers,
                    maxNew: min(overrepresented.count, 2)
                )
                for peer in replacements {
                    try? await network.ivy.connect(to: peer)
                }
            }

            if connected >= 2 {
                let bestPeers = Array(connectedPeers.prefix(2))
                await anchorPeers.update(peers: bestPeers)
            }
        }
    }
}
