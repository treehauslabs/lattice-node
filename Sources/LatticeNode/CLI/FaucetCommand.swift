import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import Hummingbird

struct FaucetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "faucet",
        abstract: "Run a testnet faucet that drips tokens to requesting addresses"
    )

    @Option(help: "Faucet private key hex (or set LATTICE_FAUCET_KEY env var)")
    var faucetKey: String?

    @Option(help: "Testnet node RPC URL to submit transactions through")
    var nodeURL: String = "http://localhost:8080"

    @Option(help: "HTTP port for the faucet server")
    var port: UInt16 = 8090

    @Option(help: "Tokens to drip per request")
    var amount: UInt64 = 1_000_000

    @Option(help: "Cooldown in seconds before the same address can request again")
    var cooldown: UInt64 = 3600

    @Option(help: "Chain directory to drip on")
    var chain: String = "Nexus"

    func run() async throws {
        let keyHex = faucetKey ?? ProcessInfo.processInfo.environment["LATTICE_FAUCET_KEY"] ?? ""
        guard !keyHex.isEmpty else {
            printError("Provide --faucet-key or set LATTICE_FAUCET_KEY")
            throw ExitCode.failure
        }
        guard let wallet = Wallet.fromPrivateKey(keyHex) else {
            printError("Invalid faucet private key")
            throw ExitCode.failure
        }

        printLogo()
        printHeader("Lattice Testnet Faucet")
        printKeyValue("Address", wallet.address)
        printKeyValue("Node URL", nodeURL)
        printKeyValue("Port", "\(port)")
        printKeyValue("Drip amount", "\(amount) tokens")
        printKeyValue("Cooldown", "\(cooldown)s per address")
        printKeyValue("Chain", chain)

        let manager = await FaucetManager(
            wallet: wallet,
            nodeURL: nodeURL,
            amount: amount,
            cooldown: cooldown,
            chain: chain
        )

        if let balance = await manager.fetchBalance() {
            printKeyValue("Faucet balance", "\(balance) tokens")
        }
        printSuccess("Faucet ready at http://0.0.0.0:\(port)/faucet")

        let faucetManager = manager
        let router = Router(context: BasicRequestContext.self)

        router.post("faucet") { request, _ -> Response in
            struct Req: Decodable { let address: String }
            guard let req = try? await JSONDecoder().decode(Req.self, from: Data(buffer: request.body.collect(upTo: 65536))) else {
                return faucetResponse(error: "missing or invalid body: {\"address\":\"...\"}",  status: .badRequest)
            }
            let result = await faucetManager.drip(to: req.address)
            switch result {
            case .dripped(let txCID):
                let json = "{\"txCID\":\"\(txCID)\",\"amount\":\(faucetManager.amount),\"address\":\"\(req.address)\"}"
                return faucetResponse(body: json, status: .ok)
            case .cooldown(let remaining):
                return faucetResponse(error: "cooldown: \(remaining)s remaining", status: .tooManyRequests)
            case .failed(let msg):
                return faucetResponse(error: msg, status: .badRequest)
            }
        }

        router.get("health") { _, _ in
            faucetResponse(body: "{\"status\":\"ok\"}", status: .ok)
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: Int(port)))
        )

        let keepAlive = AsyncStream<Void> { continuation in
            let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            src.setEventHandler { continuation.finish() }
            src.resume()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.run() }
            group.addTask { for await _ in keepAlive {} }
            _ = try await group.next()
            group.cancelAll()
        }

        printSuccess("Faucet stopped")
    }
}

private func faucetResponse(body: String = "", error: String = "", status: HTTPResponse.Status) -> Response {
    let json = error.isEmpty ? body : "{\"error\":\"\(error)\"}"
    return Response(
        status: status,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: .init(byteBuffer: ByteBuffer(string: json))
    )
}

enum DripResult {
    case dripped(String)
    case cooldown(Int)
    case failed(String)
}

actor FaucetManager {
    private let wallet: Wallet
    private let nodeURL: String
    let amount: UInt64
    private let cooldown: UInt64
    private let chain: String
    private var nonce: UInt64?
    private var lastDrip: [String: Date] = [:]

    init(wallet: Wallet, nodeURL: String, amount: UInt64, cooldown: UInt64, chain: String) async {
        self.wallet = wallet
        self.nodeURL = nodeURL
        self.amount = amount
        self.cooldown = cooldown
        self.chain = chain
        self.nonce = await Self.fetchNonce(address: wallet.address, nodeURL: nodeURL, chain: chain)
    }

    func fetchBalance() async -> UInt64? {
        guard let url = URL(string: "\(nodeURL)/api/balance/\(wallet.address)?chain=\(chain)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let b = json["balance"] as? UInt64 { return b }
        if let b = json["balance"] as? Int { return UInt64(b) }
        return nil
    }

    private static func fetchNonce(address: String, nodeURL: String, chain: String) async -> UInt64? {
        guard let url = URL(string: "\(nodeURL)/api/nonce/\(address)?chain=\(chain)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        if let n = json["nonce"] as? UInt64 { return n + 1 }
        if let n = json["nonce"] as? Int { return UInt64(n) + 1 }
        return 0
    }

    func drip(to address: String) async -> DripResult {
        guard address.count == 40, address.allSatisfy({ $0.isHexDigit }) else {
            return .failed("invalid address: must be 40 hex characters")
        }

        if let last = lastDrip[address] {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < Double(cooldown) {
                return .cooldown(Int(Double(cooldown) - elapsed))
            }
        }

        if nonce == nil {
            nonce = await Self.fetchNonce(address: wallet.address, nodeURL: nodeURL, chain: chain)
        }
        let txNonce = nonce ?? 0

        // Retry with escalating fee to handle RBF rejections
        var fee: UInt64 = 2
        for _ in 0..<5 {
            guard let tx = wallet.buildTransfer(
                to: address, amount: amount, fee: fee, nonce: txNonce, chainPath: [chain]
            ) else { return .failed("failed to build transaction") }

            guard let bodyData = tx.body.node?.toData() else { return .failed("failed to serialize transaction body") }
            let bodyCID = tx.body.rawCID
            let bodyHex = bodyData.map { String(format: "%02x", $0) }.joined()

            struct Sub: Encodable { let signatures: [String: String]; let bodyCID: String; let bodyData: String; let chain: String }
            guard let payload = try? JSONEncoder().encode(Sub(signatures: tx.signatures, bodyCID: bodyCID, bodyData: bodyHex, chain: chain)),
                  let url = URL(string: "\(nodeURL)/api/transaction") else { return .failed("failed to encode submission") }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = payload

            guard let (data, response) = try? await URLSession.shared.data(for: req) else { return .failed("node unreachable") }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                nonce = txNonce + 1
                lastDrip[address] = Date()
                NodeLogger("faucet").info("Dripped \(amount) to \(address) nonce=\(txNonce) fee=\(fee) txCID=\(String(bodyCID.prefix(16)))…")
                return .dripped(bodyCID)
            }
            let errMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "submission failed (\(status))"
            // Parse "RBF fee too low: need at least N, got M" and retry with N
            if errMsg.contains("RBF fee too low"),
               let part = errMsg.components(separatedBy: "at least ").last,
               let needed = UInt64(part.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "") {
                fee = needed
                continue
            }
            return .failed(errMsg)
        }
        return .failed("RBF retry limit exceeded")
    }
}
