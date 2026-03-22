import Lattice
import Foundation
import Network
import cashew
import UInt256

public final class RPCServer: @unchecked Sendable {
    private let node: LatticeNode
    private let port: UInt16
    private let allowedOrigin: String
    private var listener: NWListener?
    private let queue: DispatchQueue
    public init(node: LatticeNode, port: UInt16 = 8080, allowedOrigin: String = "http://127.0.0.1") {
        self.node = node
        self.port = port
        self.allowedOrigin = allowedOrigin
        self.queue = DispatchQueue(label: "lattice.rpc", attributes: .concurrent)
    }

    public func start() throws {
        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RPCError.invalidPort
        }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        l.start(queue: queue)
        self.listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)

        let remoteIP: String
        if let endpoint = conn.currentPath?.remoteEndpoint,
           case .hostPort(let host, _) = endpoint {
            remoteIP = "\(host)"
        } else {
            remoteIP = "unknown"
        }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil else {
                conn.cancel()
                return
            }

            guard let raw = String(data: data, encoding: .utf8) else {
                self.sendResponse(conn, status: 400, body: self.jsonError("Invalid request encoding"))
                return
            }

            let parsed = self.parseHTTP(raw)

            if parsed.method == "OPTIONS" {
                self.sendCORSPreflight(conn)
                return
            }

            Task {
                let (status, body) = await self.route(method: parsed.method, path: parsed.path, body: parsed.body)
                self.sendResponse(conn, status: status, body: body)
            }
        }
    }

    // MARK: - HTTP Parsing

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: String?
    }

    private func parseHTTP(_ raw: String) -> HTTPRequest {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return HTTPRequest(method: "GET", path: "/", body: nil)
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            return HTTPRequest(method: "GET", path: "/", body: nil)
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var body: String? = nil
        if let idx = lines.firstIndex(of: "") {
            let rest = lines[(idx + 1)...].joined(separator: "\r\n")
            if !rest.isEmpty { body = rest }
        }
        return HTTPRequest(method: method, path: path, body: body)
    }

    // MARK: - Response Helpers

    private func sendResponse(_ conn: NWConnection, status: Int, body: Data) {
        let statusText: String = switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        default: "Error"
        }
        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: \(self.allowedOrigin)\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Content-Type\r\n"
        header += "\r\n"
        var responseData = Data(header.utf8)
        responseData.append(body)
        conn.send(content: responseData, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func sendCORSPreflight(_ conn: NWConnection) {
        var header = "HTTP/1.1 204 No Content\r\n"
        header += "Access-Control-Allow-Origin: \(self.allowedOrigin)\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Content-Type\r\n"
        header += "Content-Length: 0\r\n"
        header += "\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func jsonError(_ message: String) -> Data {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        return Data("{\"error\":\"\(escaped)\"}".utf8)
    }

    private func jsonEncode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    // MARK: - Routing

    private func route(method: String, path: String, body: String?) async -> (Int, Data) {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count >= 2, segments[0] == "api" else {
            return (404, jsonError("Not found"))
        }

        if method == "GET" && segments.count == 3 && segments[1] == "chain" && segments[2] == "info" {
            return await handleChainInfo()
        }
        if method == "GET" && segments.count == 3 && segments[1] == "chain" && segments[2] == "spec" {
            return await handleChainSpec()
        }
        if method == "GET" && segments.count == 3 && segments[1] == "balance" {
            return await handleGetBalance(address: segments[2])
        }
        if method == "GET" && segments.count == 3 && segments[1] == "block" && segments[2] == "latest" {
            return await handleLatestBlock()
        }
        if method == "GET" && segments.count == 3 && segments[1] == "block" {
            return await handleGetBlock(id: segments[2])
        }
        if method == "POST" && segments.count == 2 && segments[1] == "transaction" {
            return await handleSubmitTransaction(body: body)
        }
        if method == "GET" && segments.count == 2 && segments[1] == "mempool" {
            return await handleMempool()
        }
        if method == "GET" && segments.count == 2 && segments[1] == "orders" {
            return await handleGetOrders()
        }
        if method == "POST" && segments.count == 2 && segments[1] == "orders" {
            return await handlePlaceOrder(body: body)
        }
        if method == "GET" && segments.count == 3 && segments[1] == "proof" {
            return await handleBalanceProof(address: segments[2])
        }
        if method == "GET" && segments.count == 2 && segments[1] == "peers" {
            return await handleGetPeers()
        }
        return (404, jsonError("Not found"))
    }

    // MARK: - Chain Info

    private func handleChainInfo() async -> (Int, Data) {
        let statuses = await node.chainStatus()

        struct ChainInfoResponse: Encodable {
            let chains: [ChainEntry]
            let genesisHash: String
        }
        struct ChainEntry: Encodable {
            let directory: String
            let height: UInt64
            let tip: String
            let mining: Bool
            let mempoolCount: Int
            let syncing: Bool
        }

        let chains = statuses.map { s in
            ChainEntry(
                directory: s.directory, height: s.height, tip: s.tip,
                mining: s.mining, mempoolCount: s.mempoolCount, syncing: s.syncing
            )
        }
        let response = ChainInfoResponse(
            chains: chains,
            genesisHash: node.genesisResult.blockHash
        )
        return (200, jsonEncode(response))
    }

    private func handleChainSpec() async -> (Int, Data) {
        let spec = node.genesisConfig.spec

        struct SpecResponse: Encodable {
            let directory: String
            let targetBlockTime: UInt64
            let initialReward: UInt64
            let halvingInterval: UInt64
            let maxTransactionsPerBlock: UInt64
            let maxStateGrowth: Int
            let maxBlockSize: Int
            let premine: UInt64
            let premineAmount: UInt64
        }

        let response = SpecResponse(
            directory: spec.directory,
            targetBlockTime: spec.targetBlockTime,
            initialReward: spec.initialReward,
            halvingInterval: spec.halvingInterval,
            maxTransactionsPerBlock: spec.maxNumberOfTransactionsPerBlock,
            maxStateGrowth: spec.maxStateGrowth,
            maxBlockSize: spec.maxBlockSize,
            premine: spec.premine,
            premineAmount: spec.premineAmount()
        )
        return (200, jsonEncode(response))
    }

    // MARK: - Balance

    private func handleGetBalance(address: String) async -> (Int, Data) {
        do {
            let balance = try await node.getBalance(address: address)
            struct BalanceResponse: Encodable {
                let address: String
                let balance: UInt64
            }
            return (200, jsonEncode(BalanceResponse(address: address, balance: balance)))
        } catch {
            return (500, jsonError("Failed to query balance: \(error)"))
        }
    }

    // MARK: - Blocks

    private func handleLatestBlock() async -> (Int, Data) {
        let tip = await node.lattice.nexus.chain.getMainChainTip()
        let snapshot = await node.lattice.nexus.chain.tipSnapshot
        struct BlockResponse: Encodable {
            let hash: String
            let index: UInt64?
            let timestamp: Int64?
            let difficulty: String?
        }
        let response = BlockResponse(
            hash: tip,
            index: snapshot?.index,
            timestamp: snapshot?.timestamp,
            difficulty: snapshot?.difficulty.toHexString()
        )
        return (200, jsonEncode(response))
    }

    private func handleGetBlock(id: String) async -> (Int, Data) {
        var blockHash = id
        if let index = UInt64(id) {
            guard let hash = await node.getBlockHash(atIndex: index) else {
                return (404, jsonError("Block not found at index \(index)"))
            }
            blockHash = hash
        }

        do {
            guard let block = try await node.getBlock(hash: blockHash) else {
                return (404, jsonError("Block not found"))
            }
            struct BlockDetailResponse: Encodable {
                let hash: String
                let index: UInt64
                let timestamp: Int64
                let previousBlock: String?
                let difficulty: String
                let nonce: UInt64
                let transactionsCID: String
                let homesteadCID: String
                let frontierCID: String
            }
            let response = BlockDetailResponse(
                hash: blockHash,
                index: block.index,
                timestamp: block.timestamp,
                previousBlock: block.previousBlock?.rawCID,
                difficulty: block.difficulty.toHexString(),
                nonce: block.nonce,
                transactionsCID: block.transactions.rawCID,
                homesteadCID: block.homestead.rawCID,
                frontierCID: block.frontier.rawCID
            )
            return (200, jsonEncode(response))
        } catch {
            return (500, jsonError("Failed to fetch block: \(error)"))
        }
    }

    // MARK: - Transactions

    private func handleSubmitTransaction(body: String?) async -> (Int, Data) {
        guard let body, let bodyData = body.data(using: .utf8) else {
            return (400, jsonError("Missing request body"))
        }

        struct TxSubmission: Decodable {
            let signatures: [String: String]
            let bodyCID: String
            let bodyData: String?
        }

        guard let submission = try? JSONDecoder().decode(TxSubmission.self, from: bodyData) else {
            return (400, jsonError("Invalid transaction format. Expected: {signatures, bodyCID, bodyData}"))
        }

        let directory = node.genesisConfig.spec.directory
        guard let network = await node.network(for: directory) else {
            return (500, jsonError("Network not available"))
        }

        if let bodyHex = submission.bodyData, let rawBody = Data(hex: bodyHex) {
            await network.fetcher.store(rawCid: submission.bodyCID, data: rawBody)
        }

        let txBody = HeaderImpl<TransactionBody>(rawCID: submission.bodyCID)
        let resolved = try? await txBody.resolve(fetcher: network.fetcher)
        guard let resolvedBody = resolved?.node else {
            return (400, jsonError("Transaction body not found. Provide bodyData (hex-encoded serialized TransactionBody) or ensure bodyCID is already in the CAS."))
        }

        let tx = Transaction(signatures: submission.signatures, body: HeaderImpl<TransactionBody>(node: resolvedBody))
        let result = await node.submitTransactionWithReason(directory: directory, transaction: tx)

        struct TxResponse: Encodable {
            let accepted: Bool
            let txCID: String
            let error: String?
        }
        switch result {
        case .success:
            return (200, jsonEncode(TxResponse(accepted: true, txCID: submission.bodyCID, error: nil)))
        case .failure(let reason):
            return (400, jsonEncode(TxResponse(accepted: false, txCID: submission.bodyCID, error: reason)))
        }
    }

    // MARK: - Mempool

    private func handleMempool() async -> (Int, Data) {
        let directory = node.genesisConfig.spec.directory
        guard let network = await node.network(for: directory) else {
            return (500, jsonError("Network not available"))
        }
        let count = await network.mempool.count
        let totalFees = await network.mempool.totalFees()

        struct MempoolResponse: Encodable {
            let count: Int
            let totalFees: UInt64
        }
        return (200, jsonEncode(MempoolResponse(count: count, totalFees: totalFees)))
    }

    // MARK: - Merkle Proof

    private func handleBalanceProof(address: String) async -> (Int, Data) {
        do {
            guard let proof = try await node.getBalanceProof(address: address) else {
                return (500, jsonError("Proof generation failed"))
            }
            return (200, proof)
        } catch {
            return (500, jsonError("Failed to generate proof: \(error)"))
        }
    }

    // MARK: - Peers

    private func handleGetPeers() async -> (Int, Data) {
        let peers = await node.connectedPeerEndpoints()
        struct PeerResponse: Encodable {
            let count: Int
            let peers: [PeerEntry]
        }
        struct PeerEntry: Encodable {
            let publicKey: String
            let host: String
            let port: UInt16
        }
        let entries = peers.map { PeerEntry(publicKey: String($0.publicKey.prefix(16)) + "...", host: $0.host, port: $0.port) }
        return (200, jsonEncode(PeerResponse(count: peers.count, peers: entries)))
    }

    // MARK: - DEX Orders

    private func handleGetOrders() async -> (Int, Data) {
        do {
            let orders = try await node.getOrders()
            struct OrdersResponse: Encodable {
                let orders: [OrderEntry]
            }
            struct OrderEntry: Encodable {
                let id: String
                let owner: String
                let side: String
                let price: UInt64
                let amount: UInt64
                let filled: UInt64
                let remaining: UInt64
            }
            let entries = orders.map { o in
                OrderEntry(
                    id: o.id, owner: o.owner, side: o.side.rawValue,
                    price: o.price, amount: o.amount,
                    filled: o.filled, remaining: o.remaining
                )
            }
            return (200, jsonEncode(OrdersResponse(orders: entries)))
        } catch {
            return (500, jsonError("Failed to query orders: \(error)"))
        }
    }

    private func handlePlaceOrder(body: String?) async -> (Int, Data) {
        guard let body, let bodyData = body.data(using: .utf8) else {
            return (400, jsonError("Missing request body"))
        }

        struct OrderSubmission: Decodable {
            let signatures: [String: String]
            let bodyCID: String
            let bodyData: String?
        }

        guard let submission = try? JSONDecoder().decode(OrderSubmission.self, from: bodyData) else {
            return (400, jsonError("Invalid order format. Expected: {signatures, bodyCID, bodyData} (sign client-side)"))
        }

        let directory = node.genesisConfig.spec.directory
        guard let network = await node.network(for: directory) else {
            return (500, jsonError("Network not available"))
        }

        if let bodyHex = submission.bodyData, let rawBody = Data(hex: bodyHex) {
            await network.fetcher.store(rawCid: submission.bodyCID, data: rawBody)
        }

        let txBody = HeaderImpl<TransactionBody>(rawCID: submission.bodyCID)
        let resolved = try? await txBody.resolve(fetcher: network.fetcher)
        guard let resolvedBody = resolved?.node else {
            return (400, jsonError("Transaction body not found. Provide bodyData (hex-encoded serialized TransactionBody)."))
        }

        let tx = Transaction(signatures: submission.signatures, body: HeaderImpl<TransactionBody>(node: resolvedBody))
        let result = await node.submitTransactionWithReason(directory: directory, transaction: tx)

        struct PlaceOrderResponse: Encodable {
            let accepted: Bool
            let txCID: String
            let error: String?
        }
        switch result {
        case .success:
            return (200, jsonEncode(PlaceOrderResponse(accepted: true, txCID: submission.bodyCID, error: nil)))
        case .failure(let reason):
            return (400, jsonEncode(PlaceOrderResponse(accepted: false, txCID: submission.bodyCID, error: reason)))
        }
    }
}

public enum RPCError: Error {
    case invalidPort
}
