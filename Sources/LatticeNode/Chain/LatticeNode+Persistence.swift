import Lattice
import Foundation
import cashew

extension LatticeNode {

    func persistChainState(directory: String) async {
        guard let persister = persisters[directory],
              let chainState = await chain(for: directory) else { return }
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
            await runStateExpiry(directory: directory)
        }
    }

    private func runStateExpiry(directory: String) async {
        guard let store = stateStores[directory],
              let chain = await chain(for: directory) else { return }
        let currentHeight = await chain.getHighestBlockIndex()
        let expiry = StateExpiry(store: store)
        let expired = await expiry.findExpiredAccounts(currentHeight: currentHeight)
        if !expired.isEmpty {
            await expiry.expireAccounts(expired, atHeight: currentHeight)
            let log = NodeLogger("expiry")
            log.info("\(directory): expired \(expired.count) inactive account(s)")
        }
    }

    // MARK: - Mempool Persistence

    func persistMempool(directory: String, network: ChainNetwork) async {
        let persistence = MempoolPersistence(dataDir: config.storagePath.appendingPathComponent(directory))
        let txs = await network.allMempoolTransactions()
        do {
            try persistence.save(transactions: txs)
        } catch {
            let log = NodeLogger("persistence")
            log.error("Failed to persist mempool for \(directory): \(error)")
        }
    }

    func restoreMempool(directory: String, network: ChainNetwork, fetcher: Fetcher) async {
        let persistence = MempoolPersistence(dataDir: config.storagePath.appendingPathComponent(directory))
        let serialized = persistence.load()
        guard !serialized.isEmpty else { return }
        var restored = 0
        for stx in serialized {
            let bodyHeader = HeaderImpl<TransactionBody>(rawCID: stx.bodyCID)
            guard let body = try? await bodyHeader.resolve(fetcher: fetcher).node else { continue }
            let tx = Transaction(signatures: stx.signatures, body: bodyHeader)
            if await network.submitTransaction(tx) {
                restored += 1
            }
        }
        if restored > 0 {
            let log = NodeLogger("persistence")
            log.info("\(directory): restored \(restored) mempool transaction(s)")
        }
        persistence.delete()
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
