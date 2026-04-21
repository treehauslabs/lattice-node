import Lattice
import Foundation
import Hummingbird
import HTTPTypes
import cashew
import UInt256
import Logging
import Synchronization
import ServiceLifecycle

public final class RPCServer: Sendable {
    private let app: Application<RouterResponder<BasicRequestContext>>
    private let _serviceGroup: Mutex<ServiceGroup?>

    public init(node: LatticeNode, port: UInt16 = 8080, bindAddress: String = "127.0.0.1", allowedOrigin: String = "http://127.0.0.1", auth: CookieAuth? = nil) {
        let router = RPCRoutes.build(node: node)
        router.add(middleware: CORSMiddleware(allowedOrigin: allowedOrigin))
        if auth != nil {
            router.add(middleware: RPCAuthMiddleware<BasicRequestContext>(auth: auth))
        }
        self.app = Application(router: router, configuration: .init(address: .hostname(bindAddress, port: Int(port))))
        self._serviceGroup = Mutex(nil)
    }

    public func run() async throws {
        let group = ServiceGroup(
            configuration: .init(services: [app], logger: .init(label: "lattice.rpc"))
        )
        _serviceGroup.withLock { $0 = group }
        try await group.run()
    }

    public func shutdown() async {
        let group = _serviceGroup.withLock { $0 }
        await group?.triggerGracefulShutdown()
    }
}

// MARK: - CORS Middleware

struct CORSMiddleware<Context: RequestContext>: RouterMiddleware {
    let allowedOrigin: String

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let requestOrigin = request.headers[.init("Origin")!]
        let effectiveOrigin: String
        if let requestOrigin, requestOrigin == allowedOrigin {
            effectiveOrigin = allowedOrigin
        } else {
            effectiveOrigin = ""
        }

        if request.method == .options {
            guard !effectiveOrigin.isEmpty else {
                return Response(status: .forbidden)
            }
            var headers = HTTPFields()
            headers.append(HTTPField(name: .init("Access-Control-Allow-Origin")!, value: effectiveOrigin))
            headers.append(HTTPField(name: .init("Access-Control-Allow-Methods")!, value: "GET, POST, OPTIONS"))
            headers.append(HTTPField(name: .init("Access-Control-Allow-Headers")!, value: "Content-Type, Authorization"))
            return Response(status: .noContent, headers: headers)
        }
        var response = try await next(request, context)
        if !effectiveOrigin.isEmpty {
            response.headers.append(HTTPField(name: .init("Access-Control-Allow-Origin")!, value: effectiveOrigin))
            response.headers.append(HTTPField(name: .init("Access-Control-Allow-Methods")!, value: "GET, POST, OPTIONS"))
            response.headers.append(HTTPField(name: .init("Access-Control-Allow-Headers")!, value: "Content-Type, Authorization"))
        }
        return response
    }
}

// MARK: - Routes

enum RPCRoutes {
    private static let log = Logger(label: "lattice.rpc")

    static func build(node: LatticeNode) -> Router<BasicRequestContext> {
        let router = Router()
        let api = router.group("api")

        api.get("chain/info") { _, _ in try await chainInfo(node: node) }
        api.get("chain/spec") { req, _ in try await chainSpec(node: node, request: req) }
        api.get("balance/{address}") { req, ctx in try await getBalance(node: node, address: ctx.parameters.require("address"), request: req) }
        api.get("block/latest") { req, _ in try await latestBlock(node: node, request: req) }
        api.get("block/{id}") { req, ctx in try await getBlock(node: node, id: ctx.parameters.require("id"), request: req) }
        api.get("block/{id}/transactions") { req, ctx in try await getBlockTransactions(node: node, id: ctx.parameters.require("id"), request: req) }
        api.get("block/{id}/children") { req, ctx in try await getBlockChildren(node: node, id: ctx.parameters.require("id"), request: req) }
        api.post("transaction") { req, _ in try await submitTransaction(node: node, request: req) }
        api.post("transaction/prepare") { req, _ in try await prepareTransaction(node: node, request: req) }
        api.get("mempool") { req, _ in try await mempool(node: node, request: req) }
        api.get("proof/{address}") { req, ctx in try await balanceProof(node: node, address: ctx.parameters.require("address"), request: req) }
        api.get("peers") { req, _ in try await getPeers(node: node, request: req) }

        api.get("fee/estimate") { req, _ in try await feeEstimate(node: node, request: req) }
        api.get("fee/histogram") { req, _ in try await feeHistogram(node: node, request: req) }
        api.get("nonce/{address}") { req, ctx in try await getNonce(node: node, address: ctx.parameters.require("address"), request: req) }

        api.get("receipt/{txCID}") { req, ctx in try await getReceipt(node: node, txCID: ctx.parameters.require("txCID"), request: req) }
        api.get("transaction/{txCID}") { req, ctx in try await getTransaction(node: node, txCID: ctx.parameters.require("txCID"), request: req) }
        api.get("transactions/{address}") { req, ctx in try await getTransactionHistory(node: node, address: ctx.parameters.require("address"), request: req) }
        api.get("finality/{height}") { req, ctx in try await getFinality(node: node, height: ctx.parameters.require("height"), request: req) }
        api.get("finality/config") { _, _ in try await getFinalityConfig(node: node) }
        api.get("block/{id}/state") { req, ctx in try await getBlockState(node: node, blockId: ctx.parameters.require("id"), request: req) }
        api.get("block/{id}/state/account/{address}") { req, ctx in try await getBlockAccountState(node: node, blockId: ctx.parameters.require("id"), address: ctx.parameters.require("address"), request: req) }
        let light = api.group("light")
        light.get("headers") { req, _ in try await lightHeaders(node: node, request: req) }
        light.get("proof/{address}") { req, ctx in try await lightProof(node: node, address: ctx.parameters.require("address"), request: req) }

        api.post("mining/start") { req, _ in try await startMining(node: node, request: req) }
        api.post("mining/stop") { req, _ in try await stopMining(node: node, request: req) }

        api.post("chain/deploy") { req, _ in try await deployChain(node: node, request: req) }

        // State explorer
        api.get("state/account/{address}") { req, ctx in try await getAccountState(node: node, address: ctx.parameters.require("address"), request: req) }
        api.get("state/summary") { req, _ in try await getStateSummary(node: node, request: req) }

        // Swap state queries
        api.get("deposit") { req, _ in try await getDepositState(node: node, request: req) }
        api.get("deposits") { req, _ in try await listDeposits(node: node, request: req) }
        api.get("receipt-state") { req, _ in try await getReceiptState(node: node, request: req) }

        // Health check
        router.get("health") { _, _ in try await healthCheck(node: node) }

        // Serve static files for the web UI (if dist/ exists next to the binary)
        router.get("") { _, _ in
            return Response(status: .temporaryRedirect, headers: HTTPFields([HTTPField(name: .location, value: "/app/")]))
        }

        router.get("metrics") { _, _ in try await metricsEndpoint(node: node) }

        router.get("ws") { req, _ in try await wsUpgrade(node: node, request: req) }

        return router
    }

    // MARK: - JSON Helpers

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let jsonDecoder = JSONDecoder()

    static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? jsonEncoder.encode(value)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: status, headers: headers, body: .init(byteBuffer: .init(data: data)))
    }

    static func jsonError(_ message: String, status: HTTPResponse.Status = .badRequest) -> Response {
        struct E: Encodable { let error: String }
        log.warning("RPC error: \(message)")
        return json(E(error: message), status: status)
    }

    // MARK: - Query Parameter Helpers

    private static func chainParam(_ request: Request) -> String? {
        request.uri.queryParameters["chain"].map(String.init)
    }

    private static func resolveChain(node: LatticeNode, request: Request) -> String {
        chainParam(request) ?? node.genesisConfig.spec.directory
    }

    // MARK: - Chain

    static func chainInfo(node: LatticeNode) async throws -> Response {
        let statuses = await node.chainStatus()
        struct R: Encodable { let chains: [C]; let genesisHash: String; let nexus: String }
        struct C: Encodable { let directory: String; let height: UInt64; let tip: String; let mining: Bool; let mempoolCount: Int; let syncing: Bool }
        let chains = statuses.map { C(directory: $0.directory, height: $0.height, tip: $0.tip, mining: $0.mining, mempoolCount: $0.mempoolCount, syncing: $0.syncing) }
        return json(R(chains: chains, genesisHash: node.genesisResult.blockHash, nexus: node.genesisConfig.spec.directory))
    }

    static func chainSpec(node: LatticeNode, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        let s: ChainSpec
        if dir == node.genesisConfig.spec.directory {
            s = node.genesisConfig.spec
        } else if let chainState = await node.chain(for: dir),
                  let snapshot = await chainState.tipSnapshot,
                  let network = await node.network(for: dir),
                  let resolved = try? await HeaderImpl<ChainSpec>(rawCID: snapshot.specCID).resolve(fetcher: network.ivyFetcher).node {
            s = resolved
        } else {
            return jsonError("Chain not found: \(dir)", status: .notFound)
        }
        struct R: Encodable { let directory: String; let targetBlockTime: UInt64; let initialReward: UInt64; let halvingInterval: UInt64; let maxTransactionsPerBlock: UInt64; let maxStateGrowth: Int; let maxBlockSize: Int; let premine: UInt64; let premineAmount: UInt64 }
        return json(R(directory: s.directory, targetBlockTime: s.targetBlockTime, initialReward: s.initialReward, halvingInterval: s.halvingInterval, maxTransactionsPerBlock: s.maxNumberOfTransactionsPerBlock, maxStateGrowth: s.maxStateGrowth, maxBlockSize: s.maxBlockSize, premine: s.premine, premineAmount: s.premineAmount()))
    }

    // MARK: - Balance & Blocks

    static func getBalance(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let dir = chainParam(request)
        do {
            let balance = try await node.getBalance(address: address, directory: dir)
            struct R: Encodable { let address: String; let balance: UInt64; let chain: String }
            return json(R(address: address, balance: balance, chain: dir ?? node.genesisConfig.spec.directory))
        } catch {
            log.error("Balance query failed for \(address): \(error)")
            return jsonError("Failed to query balance: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    static func latestBlock(node: LatticeNode, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        let isNexus = dir == node.genesisConfig.spec.directory
        let chain = isNexus
            ? await node.lattice.nexus.chain
            : await node.lattice.nexus.children[dir]?.chain
        guard let chain else { return jsonError("Unknown chain: \(dir)", status: .notFound) }
        let tip = await chain.getMainChainTip()
        let s = await chain.tipSnapshot
        struct R: Encodable { let hash: String; let index: UInt64?; let timestamp: Int64?; let difficulty: String?; let chain: String }
        return json(R(hash: tip, index: s?.index, timestamp: s?.timestamp, difficulty: s?.difficulty.toHexString(), chain: dir))
    }

    static func getBlock(node: LatticeNode, id: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let network = await node.network(for: dir) else { return jsonError("Unknown chain: \(dir)", status: .notFound) }
        var h = id
        if let i = UInt64(id) {
            let isNexus = dir == node.genesisConfig.spec.directory
            let chain = isNexus
                ? await node.lattice.nexus.chain
                : await node.lattice.nexus.children[dir]?.chain
            guard let chain else { return jsonError("Unknown chain: \(dir)", status: .notFound) }
            var found = await chain.getMainChainBlockHash(atIndex: i)
            if found == nil {
                found = await node.stateStore(for: dir)?.getBlockHash(atHeight: i)
            }
            guard let found else { return jsonError("Block not found at index \(i)", status: .notFound) }
            h = found
        }
        let header = VolumeImpl<Block>(rawCID: h)
        guard let b = try? await header.resolve(fetcher: network.fetcher).node else { return jsonError("Block not found", status: .notFound) }
        let txCount: Int
        if let txNode = try? await b.transactions.resolveRecursive(fetcher: network.fetcher).node {
            txCount = txNode.count
        } else {
            txCount = 0
        }
        let childCount: Int
        if let cbNode = try? await b.childBlocks.resolveRecursive(fetcher: network.fetcher).node {
            childCount = cbNode.count
        } else {
            childCount = 0
        }
        struct R: Encodable {
            let hash: String; let index: UInt64; let timestamp: Int64
            let previousBlock: String?; let difficulty: String; let nextDifficulty: String
            let nonce: UInt64; let version: UInt16
            let transactionsCID: String; let homesteadCID: String; let frontierCID: String
            let parentHomesteadCID: String; let specCID: String; let childBlocksCID: String
            let transactionCount: Int; let childBlockCount: Int
            let chain: String
        }
        return json(R(
            hash: h, index: b.index, timestamp: b.timestamp,
            previousBlock: b.previousBlock?.rawCID,
            difficulty: b.difficulty.toHexString(), nextDifficulty: b.nextDifficulty.toHexString(),
            nonce: b.nonce, version: b.version,
            transactionsCID: b.transactions.rawCID, homesteadCID: b.homestead.rawCID,
            frontierCID: b.frontier.rawCID, parentHomesteadCID: b.parentHomestead.rawCID,
            specCID: b.spec.rawCID, childBlocksCID: b.childBlocks.rawCID,
            transactionCount: txCount, childBlockCount: childCount,
            chain: dir
        ))
    }

    // MARK: - Block Detail Endpoints

    static func getBlockTransactions(node: LatticeNode, id: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let network = await node.network(for: dir) else { return jsonError("Unknown chain: \(dir)", status: .notFound) }
        let block = try await resolveBlock(id: id, dir: dir, node: node, fetcher: network.fetcher)
        guard let b = block else { return jsonError("Block not found", status: .notFound) }
        guard let txNode = try? await b.transactions.resolveRecursive(fetcher: network.fetcher).node else {
            return jsonError("Failed to resolve transactions", status: .internalServerError)
        }
        guard let entries = try? txNode.sortedKeysAndValues() else {
            return jsonError("Failed to enumerate transactions", status: .internalServerError)
        }
        struct TxSummary: Encodable {
            let txCID: String; let bodyCID: String; let fee: UInt64; let nonce: UInt64
            let signers: [String]; let accountActionCount: Int
            let depositActionCount: Int; let receiptActionCount: Int; let withdrawalActionCount: Int
        }
        var txs: [TxSummary] = []
        for (_, txHeader) in entries {
            guard let tx = txHeader.node else { continue }
            let body = tx.body.node
            txs.append(TxSummary(
                txCID: txHeader.rawCID, bodyCID: tx.body.rawCID,
                fee: body?.fee ?? 0, nonce: body?.nonce ?? 0,
                signers: body?.signers ?? [],
                accountActionCount: body?.accountActions.count ?? 0,
                depositActionCount: body?.depositActions.count ?? 0,
                receiptActionCount: body?.receiptActions.count ?? 0,
                withdrawalActionCount: body?.withdrawalActions.count ?? 0
            ))
        }
        struct R: Encodable { let transactions: [TxSummary]; let count: Int; let blockHash: String }
        return json(R(transactions: txs, count: txs.count, blockHash: id))
    }

    static func getBlockChildren(node: LatticeNode, id: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let network = await node.network(for: dir) else { return jsonError("Unknown chain: \(dir)", status: .notFound) }
        let block = try await resolveBlock(id: id, dir: dir, node: node, fetcher: network.fetcher)
        guard let b = block else { return jsonError("Block not found", status: .notFound) }
        guard let cbNode = try? await b.childBlocks.resolveRecursive(fetcher: network.fetcher).node else {
            struct R: Encodable { let children: [String]; let count: Int }
            return json(R(children: [], count: 0))
        }
        guard let entries = try? cbNode.sortedKeysAndValues() else {
            struct R: Encodable { let children: [String]; let count: Int }
            return json(R(children: [], count: 0))
        }
        struct ChildEntry: Encodable {
            let directory: String; let blockHash: String; let index: UInt64; let timestamp: Int64
            let difficulty: String; let transactionCount: Int
        }
        var children: [ChildEntry] = []
        for (key, blockHeader) in entries {
            guard let childBlock = blockHeader.node else { continue }
            let txCount: Int
            if let txNode = try? await childBlock.transactions.resolveRecursive(fetcher: network.fetcher).node {
                txCount = txNode.count
            } else {
                txCount = 0
            }
            children.append(ChildEntry(
                directory: key, blockHash: blockHeader.rawCID,
                index: childBlock.index, timestamp: childBlock.timestamp,
                difficulty: childBlock.difficulty.toHexString(),
                transactionCount: txCount
            ))
        }
        struct R: Encodable { let children: [ChildEntry]; let count: Int }
        return json(R(children: children, count: children.count))
    }

    private static func resolveBlock(id: String, dir: String, node: LatticeNode, fetcher: any Fetcher) async throws -> Block? {
        var h = id
        if let i = UInt64(id) {
            let isNexus = dir == node.genesisConfig.spec.directory
            let chain = isNexus
                ? await node.lattice.nexus.chain
                : await node.lattice.nexus.children[dir]?.chain
            guard let chain else { return nil }
            guard let found = await chain.getMainChainBlockHash(atIndex: i) else { return nil }
            h = found
        }
        let header = VolumeImpl<Block>(rawCID: h)
        return try? await header.resolve(fetcher: fetcher).node
    }

    // MARK: - Transactions

    static func submitTransaction(node: LatticeNode, request: Request) async throws -> Response {
        struct Sub: Decodable { let signatures: [String: String]; let bodyCID: String; let bodyData: String?; let chain: String? }
        guard let sub = try? await jsonDecoder.decode(Sub.self, from: request.body.collect(upTo: 1_048_576)) else {
            return jsonError("Invalid transaction format. Expected: {signatures, bodyCID, bodyData}")
        }
        let dir = sub.chain ?? node.genesisConfig.spec.directory
        guard let net = await node.network(for: dir) else { return jsonError("Unknown chain: \(dir)", status: .notFound) }
        if let hex = sub.bodyData, let raw = Data(hex: hex) {
            guard let parsed = TransactionBody(data: raw) else {
                return jsonError("Invalid bodyData: cannot deserialize")
            }
            let computedCID = HeaderImpl<TransactionBody>(node: parsed).rawCID
            guard computedCID == sub.bodyCID else {
                return jsonError("CID mismatch: bodyData hashes to \(computedCID), not \(sub.bodyCID)")
            }
            await net.storeLocally(cid: sub.bodyCID, data: raw)
        }
        guard let body = try? await HeaderImpl<TransactionBody>(rawCID: sub.bodyCID).resolve(fetcher: net.fetcher).node else {
            return jsonError("Transaction body not found. Provide bodyData or ensure bodyCID is in the CAS.")
        }
        let tx = Transaction(signatures: sub.signatures, body: HeaderImpl<TransactionBody>(node: body))
        let result = await node.submitTransactionWithReason(directory: dir, transaction: tx)
        struct R: Encodable { let accepted: Bool; let txCID: String; let error: String? }
        switch result {
        case .success: return json(R(accepted: true, txCID: sub.bodyCID, error: nil))
        case .failure(let r):
            log.info("Transaction rejected (\(sub.bodyCID)): \(r)")
            return json(R(accepted: false, txCID: sub.bodyCID, error: r), status: .badRequest)
        }
    }

    // MARK: - Transaction Preparation

    static func prepareTransaction(node: LatticeNode, request: Request) async throws -> Response {
        struct AccountActionInput: Decodable { let owner: String; let delta: Int64 }
        struct DepositInput: Decodable { let nonce: String; let demander: String; let amountDemanded: UInt64; let amountDeposited: UInt64 }
        struct ReceiptInput: Decodable { let withdrawer: String; let nonce: String; let demander: String; let amountDemanded: UInt64; let directory: String }
        struct WithdrawalInput: Decodable { let withdrawer: String; let nonce: String; let demander: String; let amountDemanded: UInt64; let amountWithdrawn: UInt64 }
        struct Body: Decodable {
            let nonce: UInt64
            let signers: [String]
            let fee: UInt64
            let accountActions: [AccountActionInput]
            let depositActions: [DepositInput]?
            let receiptActions: [ReceiptInput]?
            let withdrawalActions: [WithdrawalInput]?
            let chainPath: [String]?
        }

        guard let body = try? await jsonDecoder.decode(Body.self, from: request.body.collect(upTo: 1_048_576)) else {
            return jsonError("Invalid request body")
        }

        let accountActions = body.accountActions.map { AccountAction(owner: $0.owner, delta: $0.delta) }
        var depositActions: [DepositAction] = []
        for d in (body.depositActions ?? []) {
            guard let nonce = UInt128(d.nonce, radix: 16) else { return jsonError("Invalid deposit nonce hex: \(d.nonce)") }
            depositActions.append(DepositAction(nonce: nonce, demander: d.demander, amountDemanded: d.amountDemanded, amountDeposited: d.amountDeposited))
        }
        var receiptActions: [ReceiptAction] = []
        for r in (body.receiptActions ?? []) {
            guard let nonce = UInt128(r.nonce, radix: 16) else { return jsonError("Invalid receipt nonce hex: \(r.nonce)") }
            receiptActions.append(ReceiptAction(withdrawer: r.withdrawer, nonce: nonce, demander: r.demander, amountDemanded: r.amountDemanded, directory: r.directory))
        }
        var withdrawalActions: [WithdrawalAction] = []
        for w in (body.withdrawalActions ?? []) {
            guard let nonce = UInt128(w.nonce, radix: 16) else { return jsonError("Invalid withdrawal nonce hex: \(w.nonce)") }
            withdrawalActions.append(WithdrawalAction(withdrawer: w.withdrawer, nonce: nonce, demander: w.demander, amountDemanded: w.amountDemanded, amountWithdrawn: w.amountWithdrawn))
        }

        let txBody = TransactionBody(
            accountActions: accountActions,
            actions: [],
            depositActions: depositActions,
            genesisActions: [],
            peerActions: [],
            receiptActions: receiptActions,
            withdrawalActions: withdrawalActions,
            signers: body.signers,
            fee: body.fee,
            nonce: body.nonce,
            chainPath: body.chainPath ?? []
        )

        let header = HeaderImpl<TransactionBody>(node: txBody)
        guard let data = txBody.toData() else {
            return jsonError("Failed to serialize transaction body", status: .internalServerError)
        }

        struct R: Encodable { let bodyCID: String; let bodyData: String }
        return json(R(bodyCID: header.rawCID, bodyData: data.map { String(format: "%02x", $0) }.joined()))
    }

    // MARK: - Mining Control

    static func startMining(node: LatticeNode, request: Request) async throws -> Response {
        struct Body: Decodable {
            let chain: String
            let publicKey: String?
            let privateKey: String?
        }
        guard let body = try? await jsonDecoder.decode(Body.self, from: request.body.collect(upTo: 65536)) else {
            return jsonError("Expected: {chain: \"Nexus\", publicKey?: hex, privateKey?: hex}")
        }
        let identity: MinerIdentity?
        switch (body.publicKey, body.privateKey) {
        case let (pk?, sk?):
            identity = MinerIdentity(publicKeyHex: pk, privateKeyHex: sk)
        case (nil, nil):
            identity = nil
        default:
            return jsonError("publicKey and privateKey must be provided together")
        }
        await node.startMining(directory: body.chain, identity: identity)
        struct R: Encodable { let started: Bool; let chain: String }
        return json(R(started: true, chain: body.chain))
    }

    static func stopMining(node: LatticeNode, request: Request) async throws -> Response {
        struct Body: Decodable { let chain: String }
        guard let body = try? await jsonDecoder.decode(Body.self, from: request.body.collect(upTo: 65536)) else {
            return jsonError("Expected: {chain: \"Nexus\"}")
        }
        await node.stopMining(directory: body.chain)
        struct R: Encodable { let stopped: Bool; let chain: String }
        return json(R(stopped: true, chain: body.chain))
    }

    // MARK: - Chain Deployment

    static func deployChain(node: LatticeNode, request: Request) async throws -> Response {
        struct Body: Decodable {
            let directory: String
            let parentDirectory: String
            let targetBlockTime: UInt64
            let initialReward: UInt64
            let halvingInterval: UInt64
            let premine: UInt64
            let maxTransactionsPerBlock: UInt64
            let maxStateGrowth: Int
            let maxBlockSize: Int
            let difficultyAdjustmentWindow: UInt64
            let transactionFilters: [String]?
            let actionFilters: [String]?
            let premineRecipient: String?
            let startMining: Bool?
            let minerPublicKey: String?
            let minerPrivateKey: String?
        }
        guard let body = try? await jsonDecoder.decode(Body.self, from: request.body.collect(upTo: 131_072)) else {
            return jsonError("Invalid deploy request body")
        }

        let dir = body.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if dir.isEmpty { return jsonError("Directory cannot be empty") }
        if dir.contains(where: { $0.isWhitespace || $0 == "/" }) {
            return jsonError("Directory cannot contain whitespace or '/'")
        }
        if dir == node.genesisConfig.spec.directory {
            return jsonError("Directory '\(dir)' conflicts with nexus")
        }
        if await node.network(for: dir) != nil {
            return jsonError("Chain '\(dir)' already exists")
        }
        let storageDir = await node.config.storagePath.appendingPathComponent(dir)
        if FileManager.default.fileExists(atPath: storageDir.path) {
            return jsonError("Chain directory '\(dir)' already has data on disk from a prior deploy. Remove \(storageDir.path) before redeploying.", status: .conflict)
        }
        if body.parentDirectory != node.genesisConfig.spec.directory {
            return jsonError("Only '\(node.genesisConfig.spec.directory)' is supported as parent; nested child chains are not yet supported")
        }
        guard let parentNetwork = await node.network(for: body.parentDirectory) else {
            return jsonError("Parent chain not found: \(body.parentDirectory)", status: .notFound)
        }

        let spec = ChainSpec(
            directory: dir,
            maxNumberOfTransactionsPerBlock: body.maxTransactionsPerBlock,
            maxStateGrowth: body.maxStateGrowth,
            maxBlockSize: body.maxBlockSize,
            premine: body.premine,
            targetBlockTime: body.targetBlockTime,
            initialReward: body.initialReward,
            halvingInterval: body.halvingInterval,
            difficultyAdjustmentWindow: body.difficultyAdjustmentWindow,
            transactionFilters: body.transactionFilters ?? [],
            actionFilters: body.actionFilters ?? []
        )
        guard spec.isValid else { return jsonError("Invalid chain spec (check premine < halvingInterval, non-zero fields)") }

        var genesisTransactions: [Transaction] = []
        if spec.premineAmount() > 0 {
            guard let recipient = body.premineRecipient, !recipient.isEmpty else {
                return jsonError("premineRecipient is required when premine > 0")
            }
            let dummy = CryptoUtils.generateKeyPair()
            let dummyAddress = CryptoUtils.createAddress(from: dummy.publicKey)
            let premineBody = TransactionBody(
                accountActions: [AccountAction(owner: recipient, delta: Int64(spec.premineAmount()))],
                actions: [], depositActions: [], genesisActions: [], peerActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [dummyAddress], fee: 0, nonce: 0
            )
            let bodyHeader = HeaderImpl<TransactionBody>(node: premineBody)
            genesisTransactions.append(Transaction(
                signatures: [dummy.publicKey: "genesis"],
                body: bodyHeader
            ))
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let genesisBlock: Block
        do {
            genesisBlock = try await BlockBuilder.buildGenesis(
                spec: spec,
                transactions: genesisTransactions,
                timestamp: timestamp,
                difficulty: UInt256.max,
                fetcher: parentNetwork.ivyFetcher
            )
        } catch {
            log.error("deployChain: buildGenesis failed: \(error)")
            return jsonError("Failed to build genesis block: \(error.localizedDescription)", status: .internalServerError)
        }

        do {
            try await node.deployChildChain(directory: dir, genesisBlock: genesisBlock)
        } catch {
            log.error("deployChain: deployChildChain failed: \(error)")
            return jsonError("Failed to deploy chain: \(error.localizedDescription)", status: .internalServerError)
        }

        var mining = false
        if body.startMining == true {
            let identity: MinerIdentity?
            switch (body.minerPublicKey, body.minerPrivateKey) {
            case let (pk?, sk?):
                identity = MinerIdentity(publicKeyHex: pk, privateKeyHex: sk)
            case (nil, nil):
                identity = nil
            default:
                return jsonError("minerPublicKey and minerPrivateKey must be provided together")
            }
            await node.startMining(directory: dir, identity: identity)
            mining = await node.isMining(directory: dir)
        }

        let genesisHash = VolumeImpl<Block>(node: genesisBlock).rawCID
        struct R: Encodable {
            let directory: String
            let parentDirectory: String
            let genesisHash: String
            let mining: Bool
        }
        return json(R(
            directory: dir,
            parentDirectory: body.parentDirectory,
            genesisHash: genesisHash,
            mining: mining
        ))
    }

    // MARK: - Mempool, Proof, Peers

    static func mempool(node: LatticeNode, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let net = await node.network(for: dir) else { return jsonError("Unknown chain: \(dir)", status: .notFound) }
        struct R: Encodable { let count: Int; let totalFees: UInt64; let chain: String }
        return json(R(count: await net.nodeMempool.count, totalFees: await net.nodeMempool.totalFees(), chain: dir))
    }

    static func balanceProof(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let dir = chainParam(request)
        guard let proof = try await node.getBalanceProof(address: address, directory: dir) else {
            return jsonError("Proof generation failed", status: .internalServerError)
        }
        var headers = HTTPFields()
        headers.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: .init(data: proof)))
    }

    static func getPeers(node: LatticeNode, request: Request) async throws -> Response {
        let dir = chainParam(request)
        let peers = await node.connectedPeerEndpoints(directory: dir)
        struct P: Encodable { let publicKey: String; let host: String; let port: UInt16 }
        struct R: Encodable { let count: Int; let peers: [P] }
        return json(R(count: peers.count, peers: peers.map { P(publicKey: String($0.publicKey.prefix(16)) + "...", host: $0.host, port: $0.port) }))
    }

    // MARK: - Fee Estimation

    static func feeEstimate(node: LatticeNode, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        let targetStr = request.uri.queryParameters["target"].map(String.init) ?? "5"
        let target = Int(targetStr) ?? 5
        let estimator = await node.feeEstimator(for: dir)
        let fee = await estimator.estimate(confirmationTarget: target)
        struct R: Encodable { let fee: UInt64; let target: Int; let chain: String }
        return json(R(fee: fee, target: target, chain: dir))
    }

    static func feeHistogram(node: LatticeNode, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        let estimator = await node.feeEstimator(for: dir)
        let histogram = await estimator.histogram()
        struct Bucket: Encodable { let range: String; let count: Int }
        struct R: Encodable { let buckets: [Bucket]; let blockCount: Int; let chain: String }
        let blockCount = await estimator.blockCount
        return json(R(buckets: histogram.map { Bucket(range: $0.range, count: $0.count) }, blockCount: blockCount, chain: dir))
    }

    // MARK: - Nonce

    static func getNonce(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        let nonce: UInt64
        if let store = await node.stateStore(for: dir) {
            nonce = store.getNonce(address: address) ?? 0
        } else {
            nonce = 0
        }
        struct R: Encodable { let address: String; let nonce: UInt64; let chain: String }
        return json(R(address: address, nonce: nonce, chain: dir))
    }

    // MARK: - Light Client

    static func lightHeaders(node: LatticeNode, request: Request) async throws -> Response {
        let fromStr = request.uri.queryParameters["from"].map(String.init) ?? "0"
        let toStr = request.uri.queryParameters["to"].map(String.init) ?? "100"
        let from = UInt64(fromStr) ?? 0
        let maxRange: UInt64 = 500
        let to = min(UInt64(toStr) ?? 100, from + maxRange)

        let dir = resolveChain(node: node, request: request)
        guard let store = await node.stateStore(for: dir) else {
            return jsonError("State store not available", status: .internalServerError)
        }

        let headers = await LightClientProtocol.buildChainHeaders(
            stateStore: store,
            fromHeight: from,
            toHeight: to
        )
        struct R: Encodable { let headers: [ChainHeader]; let count: Int }
        return json(R(headers: headers, count: headers.count))
    }

    static func lightProof(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let store = await node.stateStore(for: dir) else {
            return jsonError("State store not available", status: .internalServerError)
        }

        guard let chain = await node.chain(for: dir) else {
            return jsonError("Chain not found: \(dir)", status: .notFound)
        }
        let height = await chain.getHighestBlockIndex()
        let tip = await chain.getMainChainTip()
        let stateRoot = store.getChainTip() ?? ""

        let proof = await LightClientProtocol.buildAccountProof(
            address: address,
            stateStore: store,
            blockHash: tip,
            blockHeight: height,
            stateRoot: stateRoot,
            timestamp: 0
        )
        return json(proof)
    }

    // MARK: - Transaction Receipts

    static func getReceipt(node: LatticeNode, txCID: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let store = await node.stateStore(for: dir),
              let network = await node.network(for: dir) else {
            return jsonError("State store not available", status: .internalServerError)
        }
        let receiptStore = await TransactionReceiptStore(store: store, fetcher: network.fetcher)
        guard let receipt = await receiptStore.getReceipt(txCID: txCID) else {
            return jsonError("Receipt not found", status: .notFound)
        }
        return json(receipt)
    }

    // MARK: - Transaction Detail

    static func getTransaction(node: LatticeNode, txCID: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let network = await node.network(for: dir) else {
            return jsonError("Unknown chain: \(dir)", status: .notFound)
        }

        // Determine block hash: prefer explicit ?blockHash param, fall back to receipt index
        let blockHash: String
        let blockHeight: UInt64
        let blockTimestamp: Int64
        if let explicitHash = request.uri.queryParameters["blockHash"].map(String.init) {
            guard let data = try? await network.fetcher.fetch(rawCid: explicitHash),
                  let b = Block(data: data) else {
                return jsonError("Block not found", status: .notFound)
            }
            blockHash = explicitHash
            blockHeight = b.index
            blockTimestamp = b.timestamp
        } else {
            guard let store = await node.stateStore(for: dir) else {
                return jsonError("State store not available", status: .internalServerError)
            }
            let receiptStore = await TransactionReceiptStore(store: store, fetcher: network.fetcher)
            guard let receipt = await receiptStore.getReceipt(txCID: txCID) else {
                return jsonError("Transaction not found", status: .notFound)
            }
            blockHash = receipt.blockHash
            blockHeight = receipt.blockHeight
            blockTimestamp = receipt.timestamp
        }

        // Resolve the full transaction body from the block.
        // Transaction dict keys are sequential indices ("0","1",...), not CIDs,
        // so we resolve all entries and match by rawCID.
        guard let blockData = try? await network.fetcher.fetch(rawCid: blockHash),
              let block = Block(data: blockData) else {
            return jsonError("Block not found", status: .notFound)
        }
        guard let txDict = try? await block.transactions.resolveRecursive(fetcher: network.fetcher).node,
              let entries = try? txDict.allKeysAndValues() else {
            return jsonError("Transaction not found in block", status: .notFound)
        }
        var matchedTx: Transaction?
        for (_, txHeader) in entries {
            guard txHeader.rawCID == txCID else { continue }
            if let n = txHeader.node {
                matchedTx = n
            } else {
                matchedTx = try? await txHeader.resolve(fetcher: network.fetcher).node
            }
            break
        }
        guard let tx = matchedTx else {
            return jsonError("Transaction not found in block", status: .notFound)
        }
        let body: TransactionBody
        if let n = tx.body.node {
            body = n
        } else if let resolved = try? await tx.body.resolve(fetcher: network.fetcher).node {
            body = resolved
        } else {
            return jsonError("Failed to resolve transaction body", status: .internalServerError)
        }

        struct AccountActionJSON: Encodable { let owner: String; let delta: Int64 }
        struct DepositActionJSON: Encodable { let nonce: String; let demander: String; let amountDemanded: UInt64; let amountDeposited: UInt64 }
        struct ReceiptActionJSON: Encodable { let withdrawer: String; let nonce: String; let demander: String; let amountDemanded: UInt64; let directory: String }
        struct WithdrawalActionJSON: Encodable { let withdrawer: String; let nonce: String; let demander: String; let amountDemanded: UInt64; let amountWithdrawn: UInt64 }
        struct R: Encodable {
            let txCID: String; let bodyCID: String
            let blockHash: String; let blockHeight: UInt64; let timestamp: Int64
            let fee: UInt64; let nonce: UInt64
            let signers: [String]; let chainPath: [String]
            let signatures: [String: String]
            let accountActions: [AccountActionJSON]
            let depositActions: [DepositActionJSON]
            let receiptActions: [ReceiptActionJSON]
            let withdrawalActions: [WithdrawalActionJSON]
            let chain: String
        }
        return json(R(
            txCID: txCID, bodyCID: tx.body.rawCID,
            blockHash: blockHash, blockHeight: blockHeight, timestamp: blockTimestamp,
            fee: body.fee, nonce: body.nonce,
            signers: body.signers, chainPath: body.chainPath,
            signatures: tx.signatures,
            accountActions: body.accountActions.map { AccountActionJSON(owner: $0.owner, delta: $0.delta) },
            depositActions: body.depositActions.map { DepositActionJSON(nonce: String($0.nonce, radix: 16), demander: $0.demander, amountDemanded: $0.amountDemanded, amountDeposited: $0.amountDeposited) },
            receiptActions: body.receiptActions.map { ReceiptActionJSON(withdrawer: $0.withdrawer, nonce: String($0.nonce, radix: 16), demander: $0.demander, amountDemanded: $0.amountDemanded, directory: $0.directory) },
            withdrawalActions: body.withdrawalActions.map { WithdrawalActionJSON(withdrawer: $0.withdrawer, nonce: String($0.nonce, radix: 16), demander: $0.demander, amountDemanded: $0.amountDemanded, amountWithdrawn: $0.amountWithdrawn) },
            chain: dir
        ))
    }

    // MARK: - Transaction History

    static func getTransactionHistory(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let store = await node.stateStore(for: dir) else {
            return jsonError("State store not available", status: .internalServerError)
        }
        let history = store.getTransactionHistory(address: address)
        struct Entry: Encodable { let txCID: String; let blockHash: String; let height: UInt64 }
        struct R: Encodable { let address: String; let transactions: [Entry]; let count: Int }
        return json(R(
            address: address,
            transactions: history.map { Entry(txCID: $0.txCID, blockHash: $0.blockHash, height: $0.height) },
            count: history.count
        ))
    }

    // MARK: - Finality

    static func getFinality(node: LatticeNode, height: String, request: Request) async throws -> Response {
        guard let blockHeight = UInt64(height) else {
            return jsonError("Invalid height", status: .badRequest)
        }
        let dir = resolveChain(node: node, request: request)
        guard let chainState = await node.chain(for: dir) else {
            return jsonError("Chain not found: \(dir)", status: .notFound)
        }
        let currentHeight = await chainState.getHighestBlockIndex()
        let finality = await node.config.finality
        let isFinal = finality.isFinal(chain: dir, blockHeight: blockHeight, currentHeight: currentHeight)
        let confirmations = currentHeight >= blockHeight ? currentHeight - blockHeight : 0
        let required = finality.confirmations(for: dir)

        struct R: Encodable {
            let height: UInt64; let currentHeight: UInt64
            let confirmations: UInt64; let required: UInt64
            let isFinal: Bool; let chain: String
        }
        return json(R(
            height: blockHeight, currentHeight: currentHeight,
            confirmations: confirmations, required: required,
            isFinal: isFinal, chain: dir
        ))
    }

    static func getFinalityConfig(node: LatticeNode) async throws -> Response {
        let finality = await node.config.finality
        let chains = await node.chainStatus()
        struct ChainFinality: Encodable {
            let chain: String; let confirmations: UInt64; let currentHeight: UInt64
        }
        let configs = chains.map {
            ChainFinality(chain: $0.directory, confirmations: finality.confirmations(for: $0.directory), currentHeight: $0.height)
        }
        struct R: Encodable { let chains: [ChainFinality]; let defaultConfirmations: UInt64 }
        return json(R(chains: configs, defaultConfirmations: finality.defaultConfirmations))
    }

    // MARK: - State Explorer

    static func getAccountState(node: LatticeNode, address: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let store = await node.stateStore(for: dir) else {
            return jsonError("State store not available", status: .internalServerError)
        }
        let account = store.getAccount(address: address)
        let history = store.getTransactionHistory(address: address)
        struct TxEntry: Encodable { let txCID: String; let blockHash: String; let height: UInt64 }
        struct R: Encodable {
            let address: String; let chain: String
            let balance: UInt64; let nonce: UInt64; let exists: Bool
            let recentTransactions: [TxEntry]; let transactionCount: Int
        }
        return json(R(
            address: address, chain: dir,
            balance: account?.balance ?? 0, nonce: account?.nonce ?? 0,
            exists: account != nil,
            recentTransactions: history.prefix(50).map { TxEntry(txCID: $0.txCID, blockHash: $0.blockHash, height: $0.height) },
            transactionCount: history.count
        ))
    }

    static func getStateSummary(node: LatticeNode, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let store = await node.stateStore(for: dir) else {
            return jsonError("State store not available", status: .internalServerError)
        }
        guard let chainState = await node.chain(for: dir) else {
            return jsonError("Chain not found", status: .notFound)
        }
        let height = await chainState.getHighestBlockIndex()
        let tip = await chainState.getMainChainTip()
        let stateRoot = store.getChainTip() ?? ""
        struct R: Encodable {
            let chain: String; let height: UInt64; let tip: String; let stateRoot: String
        }
        return json(R(chain: dir, height: height, tip: tip, stateRoot: stateRoot))
    }

    // MARK: - Block State

    static func getBlockState(node: LatticeNode, blockId: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let network = await node.network(for: dir) else { return jsonError("Unknown chain: \(dir)", status: .notFound) }
        guard let block = try await resolveBlock(id: blockId, dir: dir, node: node, fetcher: network.fetcher) else {
            return jsonError("Block not found", status: .notFound)
        }

        // Resolve the frontier (post-block state) to get sub-tree CIDs
        let state = try? await block.frontier.resolve(fetcher: network.fetcher).node

        struct StateSection: Encodable { let name: String; let cid: String }
        var sections: [StateSection] = []
        if let state {
            sections = [
                StateSection(name: "accountState", cid: state.accountState.rawCID),
                StateSection(name: "depositState", cid: state.depositState.rawCID),
                StateSection(name: "receiptState", cid: state.receiptState.rawCID),
                StateSection(name: "peerState", cid: state.peerState.rawCID),
                StateSection(name: "genesisState", cid: state.genesisState.rawCID),
                StateSection(name: "generalState", cid: state.generalState.rawCID),
            ]
        }

        struct R: Encodable {
            let blockHash: String; let blockHeight: UInt64
            let homesteadCID: String; let frontierCID: String
            let sections: [StateSection]; let chain: String
        }
        return json(R(
            blockHash: VolumeImpl<Block>(node: block).rawCID,
            blockHeight: block.index,
            homesteadCID: block.homestead.rawCID,
            frontierCID: block.frontier.rawCID,
            sections: sections,
            chain: dir
        ))
    }

    static func getBlockAccountState(node: LatticeNode, blockId: String, address: String, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        guard let network = await node.network(for: dir) else { return jsonError("Unknown chain: \(dir)", status: .notFound) }
        guard let block = try await resolveBlock(id: blockId, dir: dir, node: node, fetcher: network.fetcher) else {
            return jsonError("Block not found", status: .notFound)
        }

        // Resolve the frontier's account state with targeted path for this address
        guard let state = try? await block.frontier.resolve(fetcher: network.fetcher).node else {
            return jsonError("Failed to resolve block state", status: .internalServerError)
        }
        let resolved = try? await state.accountState.resolve(paths: [[address]: .targeted], fetcher: network.fetcher)
        let balance: UInt64 = resolved?.node.flatMap({ try? $0.get(key: address) }) ?? 0

        struct R: Encodable {
            let address: String; let balance: UInt64; let exists: Bool
            let blockHeight: UInt64; let chain: String
        }
        return json(R(
            address: address, balance: balance, exists: balance > 0,
            blockHeight: block.index, chain: dir
        ))
    }

    // MARK: - Deposit & Receipt State Queries

    static func getDepositState(node: LatticeNode, request: Request) async throws -> Response {
        guard let demander = request.uri.queryParameters["demander"].map(String.init),
              let amountStr = request.uri.queryParameters["amount"].map(String.init),
              let amount = UInt64(amountStr),
              let nonceHex = request.uri.queryParameters["nonce"].map(String.init),
              let nonce = UInt128(nonceHex, radix: 16),
              let chain = request.uri.queryParameters["chain"].map(String.init) else {
            return jsonError("Required: ?demander=&amount=&nonce=<hex>&chain=")
        }
        do {
            let deposited = try await node.getDeposit(demander: demander, amountDemanded: amount, nonce: nonce, directory: chain)
            struct R: Encodable { let exists: Bool; let amountDeposited: UInt64?; let chain: String; let key: String }
            let key = DepositKey(nonce: nonce, demander: demander, amountDemanded: amount).description
            return json(R(exists: deposited != nil, amountDeposited: deposited, chain: chain, key: key))
        } catch {
            log.error("Deposit state query failed: \(error)")
            return jsonError("Failed to query deposit state: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    static func getReceiptState(node: LatticeNode, request: Request) async throws -> Response {
        guard let demander = request.uri.queryParameters["demander"].map(String.init),
              let amountStr = request.uri.queryParameters["amount"].map(String.init),
              let amount = UInt64(amountStr),
              let nonceHex = request.uri.queryParameters["nonce"].map(String.init),
              let nonce = UInt128(nonceHex, radix: 16),
              let directory = request.uri.queryParameters["directory"].map(String.init) else {
            return jsonError("Required: ?demander=&amount=&nonce=<hex>&directory=<childChain>")
        }
        do {
            let withdrawer = try await node.getReceipt(demander: demander, amountDemanded: amount, nonce: nonce, directory: directory)
            struct R: Encodable { let exists: Bool; let withdrawer: String?; let directory: String; let key: String }
            let key = ReceiptKey(receiptAction: ReceiptAction(withdrawer: "", nonce: nonce, demander: demander, amountDemanded: amount, directory: directory)).description
            return json(R(exists: withdrawer != nil, withdrawer: withdrawer, directory: directory, key: key))
        } catch {
            log.error("Receipt state query failed: \(error)")
            return jsonError("Failed to query receipt state: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    static func listDeposits(node: LatticeNode, request: Request) async throws -> Response {
        let dir = resolveChain(node: node, request: request)
        let limitStr = request.uri.queryParameters["limit"].map(String.init)
        let limit = min(limitStr.flatMap(Int.init) ?? 100, 1000)
        let after = request.uri.queryParameters["after"].map(String.init)
        do {
            let entries = try await node.listDeposits(directory: dir, limit: limit, after: after)
            struct DepositEntry: Encodable {
                let key: String
                let demander: String
                let amountDemanded: UInt64
                let nonce: String
                let amountDeposited: UInt64
            }
            let deposits = entries.compactMap { entry -> DepositEntry? in
                guard let dk = DepositKey(entry.key) else { return nil }
                return DepositEntry(
                    key: entry.key,
                    demander: dk.demander,
                    amountDemanded: dk.amountDemanded,
                    nonce: String(dk.nonce, radix: 16),
                    amountDeposited: entry.amountDeposited
                )
            }
            struct R: Encodable { let deposits: [DepositEntry]; let count: Int; let chain: String }
            return json(R(deposits: deposits, count: deposits.count, chain: dir))
        } catch {
            log.error("List deposits failed: \(error)")
            return jsonError("Failed to list deposits: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    // MARK: - Health Check

    static func healthCheck(node: LatticeNode) async throws -> Response {
        let statuses = await node.chainStatus()
        let nexus = statuses.first { $0.directory == node.genesisConfig.spec.directory }
        let peerCount = await node.connectedPeerEndpoints().count
        let uptime = ProcessInfo.processInfo.systemUptime

        struct R: Encodable {
            let status: String
            let chainHeight: UInt64
            let peerCount: Int
            let syncing: Bool
            let chains: Int
            let uptimeSeconds: Int
        }
        let syncing = statuses.contains { $0.syncing }
        let status = peerCount > 0 ? "ok" : "degraded"
        return json(R(
            status: status,
            chainHeight: nexus?.height ?? 0,
            peerCount: peerCount,
            syncing: syncing,
            chains: statuses.count,
            uptimeSeconds: Int(uptime)
        ))
    }

    // MARK: - Prometheus Metrics

    static func metricsEndpoint(node: LatticeNode) async throws -> Response {
        let statuses = await node.chainStatus()
        let metrics = node.metrics
        for s in statuses {
            metrics.set("lattice_chain_height{chain=\"\(s.directory)\"}", value: Double(s.height))
            metrics.set("lattice_mempool_size{chain=\"\(s.directory)\"}", value: Double(s.mempoolCount))
            metrics.set("lattice_mining_active{chain=\"\(s.directory)\"}", value: s.mining ? 1 : 0)
        }
        let text = metrics.prometheus()
        var headers = HTTPFields()
        headers.append(HTTPField(name: .contentType, value: "text/plain; version=0.0.4; charset=utf-8"))
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: .init(string: text)))
    }

    // MARK: - WebSocket (SSE fallback)

    static func wsUpgrade(node: LatticeNode, request: Request) async throws -> Response {
        // SSE (Server-Sent Events) endpoint since Hummingbird WebSocket requires a separate module.
        // Clients connect via EventSource and receive JSON event frames.
        let eventsParam = request.uri.queryParameters["events"].map(String.init) ?? "newBlock,newTransaction"
        let eventTypes = Set(eventsParam.split(separator: ",").compactMap { SubscriptionEventType(rawValue: String($0)) })
        if eventTypes.isEmpty {
            return jsonError("No valid event types. Available: newBlock, newTransaction, chainReorg, syncStatus")
        }

        var headers = HTTPFields()
        headers.append(HTTPField(name: .contentType, value: "text/event-stream"))
        headers.append(HTTPField(name: .init("Cache-Control")!, value: "no-cache"))
        headers.append(HTTPField(name: .init("Connection")!, value: "keep-alive"))

        let subscriptions = node.subscriptions
        let (stream, continuation) = AsyncStream<String>.makeStream()

        let subId = await subscriptions.subscribe(events: eventTypes) { json in
            continuation.yield("data: \(json)\n\n")
        }

        let body = ResponseBody(asyncSequence: stream.map { ByteBuffer(string: $0) })
        continuation.onTermination = { _ in
            Task { await subscriptions.unsubscribe(id: subId) }
        }

        return Response(status: .ok, headers: headers, body: body)
    }
}
