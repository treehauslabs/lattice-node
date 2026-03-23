import Lattice
import Foundation

extension LatticeNode {

    func persistChainState(directory: String) async {
        guard let persister = persisters[directory] else { return }
        let chainState: ChainState
        if directory == genesisConfig.spec.directory {
            chainState = await lattice.nexus.chain
        } else if let childLevel = await lattice.nexus.children[directory] {
            chainState = await childLevel.chain
        } else {
            return
        }
        let persisted = await chainState.persist()
        do {
            try await persister.save(persisted)
        } catch {
            let log = NodeLogger("persistence")
            log.error("Failed to persist chain state for \(directory): \(error)")
        }
        blocksSinceLastPersist[directory] = 0
    }

    func maybePersist(directory: String) async {
        let count = (blocksSinceLastPersist[directory] ?? 0) + 1
        blocksSinceLastPersist[directory] = count
        if count >= config.persistInterval {
            await persistChainState(directory: directory)
        }
    }

    public func restoreChildChains() async throws {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: config.storagePath,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        let nexusDir = genesisConfig.spec.directory
        for dir in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let dirName = dir.lastPathComponent
            guard dirName != nexusDir else { continue }
            let stateFile = dir.appendingPathComponent("chain_state.json")
            guard fm.fileExists(atPath: stateFile.path) else { continue }
            let persister = ChainStatePersister(storagePath: config.storagePath, directory: dirName)
            guard let persisted = try? await persister.load() else { continue }
            let childChain = ChainState.restore(
                from: persisted,
                retentionDepth: config.retentionDepth
            )
            let childLevel = ChainLevel(chain: childChain, children: [:])
            await lattice.nexus.restoreChildChain(directory: dirName, level: childLevel)
            persisters[dirName] = persister
        }
    }
}
