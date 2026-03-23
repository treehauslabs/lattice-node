import Foundation
import Lattice

public struct LightClientProof: Codable, Sendable {
    public let blockHash: String
    public let blockHeight: UInt64
    public let stateRoot: String
    public let address: String
    public let balance: UInt64
    public let nonce: UInt64
    public let proofPath: [ProofNode]
    public let timestamp: Int64

    public struct ProofNode: Codable, Sendable {
        public let hash: String
        public let direction: String
    }
}

public struct ChainHeader: Codable, Sendable {
    public let hash: String
    public let height: UInt64
    public let previousHash: String?
    public let stateRoot: String
    public let difficulty: String
    public let timestamp: Int64
    public let cumulativeWork: String
}

public enum LightClientProtocol {
    public static func buildAccountProof(
        address: String,
        stateStore: StateStore,
        blockHash: String,
        blockHeight: UInt64,
        stateRoot: String,
        timestamp: Int64
    ) async -> LightClientProof {
        let account = await stateStore.getAccount(address: address)
        return LightClientProof(
            blockHash: blockHash,
            blockHeight: blockHeight,
            stateRoot: stateRoot,
            address: address,
            balance: account?.balance ?? 0,
            nonce: account?.nonce ?? 0,
            proofPath: [],
            timestamp: timestamp
        )
    }

    public static func buildChainHeaders(
        stateStore: StateStore,
        fromHeight: UInt64,
        toHeight: UInt64
    ) async -> [ChainHeader] {
        var headers: [ChainHeader] = []
        for h in fromHeight...min(toHeight, fromHeight + 1000) {
            guard let hash = await stateStore.getBlockHash(atHeight: h) else { continue }
            let block = await stateStore.getLatestBlock()
            headers.append(ChainHeader(
                hash: hash,
                height: h,
                previousHash: h > 0 ? await stateStore.getBlockHash(atHeight: h - 1) : nil,
                stateRoot: "",
                difficulty: block?.difficulty ?? "0",
                timestamp: block?.timestamp ?? 0,
                cumulativeWork: "0"
            ))
        }
        return headers
    }
}
