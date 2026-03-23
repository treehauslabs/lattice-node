import Lattice
import Foundation
import Ivy

extension LatticeNode {

    func startPeerRefresh() async {
        let nexusDir = genesisConfig.spec.directory
        guard let network = networks[nexusDir] else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { break }

            let randomTarget = UUID().uuidString
            let _ = await network.ivy.findNode(target: randomTarget)

            let connected = await network.ivy.directPeerCount
            if connected < 6 {
                let known = await network.ivy.router.allPeers()
                for entry in known.prefix(3) {
                    try? await network.ivy.connect(to: entry.endpoint)
                }
            }
        }
    }
}
