import ArgumentParser
import Foundation
import Lattice
import cashew

struct SendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send tokens to an address"
    )

    @Argument(help: "Recipient address")
    var to: String

    @Argument(help: "Amount to send")
    var amount: UInt64

    @Option(help: "Path to sender key JSON file")
    var key: String

    @Option(help: "RPC endpoint")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Transaction fee")
    var fee: UInt64 = 1

    func run() async throws {
        let keyData = try Data(contentsOf: URL(filePath: key))
        guard let keyJSON = try JSONSerialization.jsonObject(with: keyData) as? [String: String],
              let publicKey = keyJSON["publicKey"],
              let privateKey = keyJSON["privateKey"] else {
            printError("Invalid key file. Expected: {publicKey, privateKey}")
            throw ExitCode.failure
        }

        let senderAddress = CryptoUtils.createAddress(from: publicKey)

        printHeader("Sending \(amount) tokens")
        printKeyValue("From", senderAddress)
        printKeyValue("To", to)
        printKeyValue("Amount", "\(amount)")
        printKeyValue("Fee", "\(fee)")

        let balanceURL = URL(string: "\(rpc)/api/balance/\(senderAddress)")!
        let (balanceData, _) = try await URLSession.shared.data(from: balanceURL)
        guard let balanceJSON = try? JSONSerialization.jsonObject(with: balanceData) as? [String: Any],
              let balance = balanceJSON["balance"] as? UInt64 else {
            printError("Could not fetch sender balance")
            throw ExitCode.failure
        }

        let (totalCost, costOverflow) = amount.addingReportingOverflow(fee)
        guard !costOverflow else {
            printError("Amount + fee overflows UInt64")
            throw ExitCode.failure
        }
        guard balance >= totalCost else {
            printError("Insufficient balance: have \(balance), need \(totalCost)")
            throw ExitCode.failure
        }

        let nonceURL = URL(string: "\(rpc)/api/nonce/\(senderAddress)")!
        let (nonceData, _) = try await URLSession.shared.data(from: nonceURL)
        guard let nonceJSON = try? JSONSerialization.jsonObject(with: nonceData) as? [String: Any],
              let nonce = nonceJSON["nonce"] as? UInt64 else {
            printError("Could not fetch sender nonce")
            throw ExitCode.failure
        }

        let heightURL = URL(string: "\(rpc)/api/chain/info")!
        let (heightData, _) = try await URLSession.shared.data(from: heightURL)
        guard let chainJSON = try? JSONSerialization.jsonObject(with: heightData) as? [String: Any],
              let chains = chainJSON["chains"] as? [[String: Any]],
              let nexus = chains.first,
              let height = nexus["height"] as? UInt64 else {
            printError("Could not fetch chain height")
            throw ExitCode.failure
        }

        let recipientBalanceURL = URL(string: "\(rpc)/api/balance/\(to)")!
        let (recipientData, _) = try await URLSession.shared.data(from: recipientBalanceURL)
        let recipientJSON = (try? JSONSerialization.jsonObject(with: recipientData) as? [String: Any]) ?? [:]
        let recipientBalance = recipientJSON["balance"] as? UInt64 ?? 0

        let senderAction = AccountAction(
            owner: senderAddress,
            oldBalance: balance,
            newBalance: balance - totalCost
        )
        let (recipientNew, recipientOverflow) = recipientBalance.addingReportingOverflow(amount)
        guard !recipientOverflow else {
            printError("Recipient balance would overflow UInt64")
            throw ExitCode.failure
        }
        let recipientAction = AccountAction(
            owner: to,
            oldBalance: recipientBalance,
            newBalance: recipientNew
        )

        let body = TransactionBody(
            accountActions: [senderAction, recipientAction],
            actions: [],
            swapActions: [],
            swapClaimActions: [],
            genesisActions: [],
            peerActions: [],
            settleActions: [],
            signers: [senderAddress],
            fee: fee,
            nonce: height
        )

        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        guard let signature = CryptoUtils.sign(message: bodyHeader.rawCID, privateKeyHex: privateKey) else {
            printError("Signing failed")
            throw ExitCode.failure
        }

        guard let bodyData = body.toData() else {
            printError("Serialization failed")
            throw ExitCode.failure
        }

        let txPayload: [String: Any] = [
            "signatures": [publicKey: signature],
            "bodyCID": bodyHeader.rawCID,
            "bodyData": bodyData.map { String(format: "%02x", $0) }.joined()
        ]

        let txJSON = try JSONSerialization.data(withJSONObject: txPayload)
        var request = URLRequest(url: URL(string: "\(rpc)/api/transaction")!)
        request.httpMethod = "POST"
        request.httpBody = txJSON
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (responseData, _) = try await URLSession.shared.data(for: request)
        if let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            if response["accepted"] as? Bool == true {
                let txCID = response["txCID"] as? String ?? ""
                printSuccess("Transaction submitted: \(String(txCID.prefix(32)))...")
            } else {
                let error = response["error"] as? String ?? "Unknown error"
                printError("Transaction rejected: \(error)")
                throw ExitCode.failure
            }
        }
    }
}
