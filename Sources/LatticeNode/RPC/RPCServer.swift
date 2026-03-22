import Lattice
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import cashew
import UInt256

public final class RPCServer: Sendable {
    private let node: LatticeNode
    private let port: UInt16
    private let allowedOrigin: String
    private let group: MultiThreadedEventLoopGroup
    nonisolated(unsafe) private var channel: Channel?

    public init(node: LatticeNode, port: UInt16 = 8080, allowedOrigin: String = "http://127.0.0.1") {
        self.node = node
        self.port = port
        self.allowedOrigin = allowedOrigin
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    public func start() throws {
        let node = self.node
        let allowedOrigin = self.allowedOrigin
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).flatMap {
                    channel.pipeline.addHandler(HTTPResponseEncoder())
                }.flatMap {
                    channel.pipeline.addHandler(RPCHandler(node: node, allowedOrigin: allowedOrigin))
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)

        channel = try bootstrap.bind(host: "0.0.0.0", port: Int(port)).wait()
    }

    public func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

public enum RPCError: Error {
    case invalidPort
}

// MARK: - NIO HTTP Handler

private final class RPCHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let node: LatticeNode
    private let allowedOrigin: String
    private var method: HTTPMethod = .GET
    private var uri: String = "/"
    private var body = ByteBuffer()

    init(node: LatticeNode, allowedOrigin: String) {
        self.node = node
        self.allowedOrigin = allowedOrigin
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            method = head.method
            uri = head.uri
            body.clear()

        case .body(var buf):
            body.writeBuffer(&buf)

        case .end:
            let reqMethod = method.rawValue
            let reqPath = uri
            let reqBody = body.readableBytes > 0 ? body.getString(at: body.readerIndex, length: body.readableBytes) : nil
            let origin = allowedOrigin

            if method == .OPTIONS {
                sendCORSPreflight(context: context, origin: origin)
                return
            }

            let channel = context.channel
            let eventLoop = channel.eventLoop
            let capturedNode = node
            Task { @Sendable in
                let (status, responseBody) = await RPCRouter.route(
                    node: capturedNode, method: reqMethod, path: reqPath, body: reqBody
                )
                eventLoop.execute {
                    RPCHandler.writeResponse(
                        channel: channel, status: status, body: responseBody, origin: origin
                    )
                }
            }
        }
    }

    static func writeResponse(channel: Channel, status: Int, body: Data, origin: String) {
        let httpStatus = HTTPResponseStatus(statusCode: status)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(body.count)")
        headers.add(name: "Access-Control-Allow-Origin", value: origin)
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type")

        let head = HTTPResponseHead(version: .http1_1, status: httpStatus, headers: headers)
        channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)

        var buf = channel.allocator.buffer(capacity: body.count)
        buf.writeBytes(body)
        channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)

        channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    private func sendCORSPreflight(context: ChannelHandlerContext, origin: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Access-Control-Allow-Origin", value: origin)
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type")
        headers.add(name: "Content-Length", value: "0")

        let head = HTTPResponseHead(version: .http1_1, status: .noContent, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - Router

enum RPCRouter {

    static func route(node: LatticeNode, method: String, path: String, body: String?) async -> (Int, Data) {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count >= 2, segments[0] == "api" else {
            return (404, jsonError("Not found"))
        }

        let route = Array(segments.dropFirst())

        if method == "GET" && route == ["chain", "info"] { return await handleChainInfo(node: node) }
        if method == "GET" && route == ["chain", "spec"] { return await handleChainSpec(node: node) }
        if method == "GET" && route.count == 2 && route[0] == "balance" { return await handleGetBalance(node: node, address: route[1]) }
        if method == "GET" && route == ["block", "latest"] { return await handleLatestBlock(node: node) }
        if method == "GET" && route.count == 2 && route[0] == "block" { return await handleGetBlock(node: node, id: route[1]) }
        if method == "POST" && route == ["transaction"] { return await handleSubmitTransaction(node: node, body: body) }
        if method == "GET" && route == ["mempool"] { return await handleMempool(node: node) }
        if method == "GET" && route == ["orders"] { return await handleGetOrders(node: node) }
        if method == "POST" && route == ["orders"] { return await handlePlaceOrder(node: node, body: body) }
        if method == "GET" && route.count == 2 && route[0] == "proof" { return await handleBalanceProof(node: node, address: route[1]) }
        if method == "GET" && route == ["peers"] { return await handleGetPeers(node: node) }
        return (404, jsonError("Not found"))
    }

    // MARK: - Helpers

    static func jsonError(_ message: String) -> Data {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        return Data("{\"error\":\"\(escaped)\"}".utf8)
    }

    static func jsonEncode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    // MARK: - Chain Info

    static func handleChainInfo(node: LatticeNode) async -> (Int, Data) {
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
        return (200, jsonEncode(ChainInfoResponse(chains: chains, genesisHash: node.genesisResult.blockHash)))
    }

    static func handleChainSpec(node: LatticeNode) async -> (Int, Data) {
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
        return (200, jsonEncode(SpecResponse(
            directory: spec.directory,
            targetBlockTime: spec.targetBlockTime,
            initialReward: spec.initialReward,
            halvingInterval: spec.halvingInterval,
            maxTransactionsPerBlock: spec.maxNumberOfTransactionsPerBlock,
            maxStateGrowth: spec.maxStateGrowth,
            maxBlockSize: spec.maxBlockSize,
            premine: spec.premine,
            premineAmount: spec.premineAmount()
        )))
    }

    // MARK: - Balance

    static func handleGetBalance(node: LatticeNode, address: String) async -> (Int, Data) {
        do {
            let balance = try await node.getBalance(address: address)
            struct R: Encodable { let address: String; let balance: UInt64 }
            return (200, jsonEncode(R(address: address, balance: balance)))
        } catch {
            return (500, jsonError("Failed to query balance: \(error)"))
        }
    }

    // MARK: - Blocks

    static func handleLatestBlock(node: LatticeNode) async -> (Int, Data) {
        let tip = await node.lattice.nexus.chain.getMainChainTip()
        let snapshot = await node.lattice.nexus.chain.tipSnapshot
        struct R: Encodable { let hash: String; let index: UInt64?; let timestamp: Int64?; let difficulty: String? }
        return (200, jsonEncode(R(
            hash: tip, index: snapshot?.index,
            timestamp: snapshot?.timestamp, difficulty: snapshot?.difficulty.toHexString()
        )))
    }

    static func handleGetBlock(node: LatticeNode, id: String) async -> (Int, Data) {
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
            struct R: Encodable {
                let hash: String; let index: UInt64; let timestamp: Int64
                let previousBlock: String?; let difficulty: String; let nonce: UInt64
                let transactionsCID: String; let homesteadCID: String; let frontierCID: String
            }
            return (200, jsonEncode(R(
                hash: blockHash, index: block.index, timestamp: block.timestamp,
                previousBlock: block.previousBlock?.rawCID,
                difficulty: block.difficulty.toHexString(), nonce: block.nonce,
                transactionsCID: block.transactions.rawCID,
                homesteadCID: block.homestead.rawCID, frontierCID: block.frontier.rawCID
            )))
        } catch {
            return (500, jsonError("Failed to fetch block: \(error)"))
        }
    }

    // MARK: - Transactions

    static func handleSubmitTransaction(node: LatticeNode, body: String?) async -> (Int, Data) {
        guard let body, let bodyData = body.data(using: .utf8) else {
            return (400, jsonError("Missing request body"))
        }
        struct Sub: Decodable { let signatures: [String: String]; let bodyCID: String; let bodyData: String? }
        guard let submission = try? JSONDecoder().decode(Sub.self, from: bodyData) else {
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
            return (400, jsonError("Transaction body not found. Provide bodyData or ensure bodyCID is in the CAS."))
        }
        let tx = Transaction(signatures: submission.signatures, body: HeaderImpl<TransactionBody>(node: resolvedBody))
        let result = await node.submitTransactionWithReason(directory: directory, transaction: tx)
        struct R: Encodable { let accepted: Bool; let txCID: String; let error: String? }
        switch result {
        case .success:
            return (200, jsonEncode(R(accepted: true, txCID: submission.bodyCID, error: nil)))
        case .failure(let reason):
            return (400, jsonEncode(R(accepted: false, txCID: submission.bodyCID, error: reason)))
        }
    }

    // MARK: - Mempool

    static func handleMempool(node: LatticeNode) async -> (Int, Data) {
        let directory = node.genesisConfig.spec.directory
        guard let network = await node.network(for: directory) else {
            return (500, jsonError("Network not available"))
        }
        let count = await network.mempool.count
        let totalFees = await network.mempool.totalFees()
        struct R: Encodable { let count: Int; let totalFees: UInt64 }
        return (200, jsonEncode(R(count: count, totalFees: totalFees)))
    }

    // MARK: - Merkle Proof

    static func handleBalanceProof(node: LatticeNode, address: String) async -> (Int, Data) {
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

    static func handleGetPeers(node: LatticeNode) async -> (Int, Data) {
        let peers = await node.connectedPeerEndpoints()
        struct PeerEntry: Encodable { let publicKey: String; let host: String; let port: UInt16 }
        struct R: Encodable { let count: Int; let peers: [PeerEntry] }
        let entries = peers.map { PeerEntry(publicKey: String($0.publicKey.prefix(16)) + "...", host: $0.host, port: $0.port) }
        return (200, jsonEncode(R(count: peers.count, peers: entries)))
    }

    // MARK: - DEX Orders

    static func handleGetOrders(node: LatticeNode) async -> (Int, Data) {
        do {
            let orders = try await node.getOrders()
            struct Entry: Encodable {
                let id: String; let owner: String; let side: String
                let price: UInt64; let amount: UInt64; let filled: UInt64; let remaining: UInt64
            }
            struct R: Encodable { let orders: [Entry] }
            let entries = orders.map { o in
                Entry(id: o.id, owner: o.owner, side: o.side.rawValue,
                      price: o.price, amount: o.amount, filled: o.filled, remaining: o.remaining)
            }
            return (200, jsonEncode(R(orders: entries)))
        } catch {
            return (500, jsonError("Failed to query orders: \(error)"))
        }
    }

    static func handlePlaceOrder(node: LatticeNode, body: String?) async -> (Int, Data) {
        guard let body, let bodyData = body.data(using: .utf8) else {
            return (400, jsonError("Missing request body"))
        }
        struct Sub: Decodable { let signatures: [String: String]; let bodyCID: String; let bodyData: String? }
        guard let submission = try? JSONDecoder().decode(Sub.self, from: bodyData) else {
            return (400, jsonError("Invalid order format. Expected: {signatures, bodyCID, bodyData}"))
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
            return (400, jsonError("Transaction body not found. Provide bodyData."))
        }
        let tx = Transaction(signatures: submission.signatures, body: HeaderImpl<TransactionBody>(node: resolvedBody))
        let result = await node.submitTransactionWithReason(directory: directory, transaction: tx)
        struct R: Encodable { let accepted: Bool; let txCID: String; let error: String? }
        switch result {
        case .success:
            return (200, jsonEncode(R(accepted: true, txCID: submission.bodyCID, error: nil)))
        case .failure(let reason):
            return (400, jsonEncode(R(accepted: false, txCID: submission.bodyCID, error: reason)))
        }
    }
}
