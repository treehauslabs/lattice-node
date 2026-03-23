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

            let connectedPeers = await network.ivy.router.allPeers().map { $0.endpoint }
            let connected = connectedPeers.count

            if connected < PeerDiversity.targetOutbound {
                let known = await network.ivy.router.allPeers()
                let candidates = known.map { $0.endpoint }
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
                let known = await network.ivy.router.allPeers()
                let candidates = known.map { $0.endpoint }
                    .filter { peer in !connectedPeers.contains(where: { $0.publicKey == peer.publicKey }) }
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
