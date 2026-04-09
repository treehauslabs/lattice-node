import ArgumentParser
import Foundation

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new Lattice project"
    )

    @Argument(help: "Project name")
    var name: String

    @Option(help: "Template: basic, token, or multi-chain")
    var template: String = "basic"

    func run() throws {
        printLogo()
        printHeader("Creating project: \(name)")

        let fm = FileManager.default
        let projectDir = fm.currentDirectoryPath + "/\(name)"

        guard !fm.fileExists(atPath: projectDir) else {
            printError("Directory '\(name)' already exists")
            throw ExitCode.failure
        }

        let sourcesDir = projectDir + "/Sources/\(name)"
        try fm.createDirectory(atPath: sourcesDir, withIntermediateDirectories: true)

        try packageSwift.write(toFile: projectDir + "/Package.swift", atomically: true, encoding: .utf8)
        printSuccess("Package.swift")

        let main = mainSwift(template: template)
        try main.write(toFile: sourcesDir + "/main.swift", atomically: true, encoding: .utf8)
        printSuccess("Sources/\(name)/main.swift (\(template) template)")

        let readme = """
        # \(name)

        A Lattice blockchain project.

        ## Build & Run

        ```bash
        swift build
        swift run
        ```
        """
        try readme.write(toFile: projectDir + "/README.md", atomically: true, encoding: .utf8)
        printSuccess("README.md")

        print("")
        printSuccess("Project '\(name)' created!")
        print("")
        print("  \(Style.dim)cd \(name)\(Style.reset)")
        print("  \(Style.dim)swift build\(Style.reset)")
        print("  \(Style.dim)swift run\(Style.reset)")
    }

    var packageSwift: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            platforms: [.macOS(.v15)],
            dependencies: [
                .package(url: "https://github.com/treehauslabs/lattice.git", branch: "master"),
                .package(url: "https://github.com/treehauslabs/AcornMemoryWorker.git", branch: "master"),
                .package(url: "https://github.com/treehauslabs/AcornDiskWorker.git", branch: "master"),
            ],
            targets: [
                .executableTarget(
                    name: "\(name)",
                    dependencies: [
                        .product(name: "Lattice", package: "lattice"),
                        .product(name: "AcornMemoryWorker", package: "AcornMemoryWorker"),
                        .product(name: "AcornDiskWorker", package: "AcornDiskWorker"),
                    ]),
            ]
        )
        """
    }

    func mainSwift(template: String) -> String {
        switch template {
        case "token": return tokenTemplate
        case "multi-chain": return multiChainTemplate
        default: return basicTemplate
        }
    }

    var basicTemplate: String {
        """
        import Lattice
        import AcornMemoryWorker
        import Acorn
        import Foundation
        import UInt256

        struct InMemoryFetcher: Fetcher {
            let worker: MemoryCASWorker
            func fetch(rawCid: String) async throws -> Data {
                guard let data = await worker.getLocal(cid: ContentIdentifier(rawValue: rawCid)) else {
                    throw NSError(domain: "NotFound", code: 404)
                }
                return data
            }
        }

        let memory = MemoryCASWorker(capacity: 100_000)
        let fetcher = InMemoryFetcher(worker: memory)

        let spec = ChainSpec(
            directory: "Nexus",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 210_000
        )

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            difficulty: UInt256(1000),
            fetcher: fetcher
        )
        let genesisHeader = VolumeImpl<Block>(node: genesis)
        let chain = ChainState.fromGenesis(block: genesis)

        print("Lattice node started")
        print("  Genesis: \\(String(genesisHeader.rawCID.prefix(24)))...")
        print("  Reward: \\(spec.initialReward) tokens/block")
        print("  Block time: \\(spec.targetBlockTime)ms")
        print("")

        var prev = genesis
        var ts = Int64(Date().timeIntervalSince1970 * 1000)
        for i in 1...10 {
            ts += Int64(spec.targetBlockTime)
            let block = try await BlockBuilder.buildBlock(
                previous: prev,
                timestamp: ts,
                difficulty: UInt256(1000),
                nonce: UInt64(i),
                fetcher: fetcher
            )
            let header = VolumeImpl<Block>(node: block)
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: header,
                block: block
            )
            print("  Block \\(i): \\(String(header.rawCID.prefix(16)))... extends=\\(result.extendsMainChain)")
            prev = block
        }

        let height = await chain.getHighestBlockIndex()
        print("")
        print("  Chain height: \\(height)")
        """
    }

    var tokenTemplate: String {
        """
        import Lattice
        import AcornMemoryWorker
        import Acorn
        import Foundation
        import UInt256

        struct InMemoryFetcher: Fetcher {
            let worker: MemoryCASWorker
            func fetch(rawCid: String) async throws -> Data {
                guard let data = await worker.getLocal(cid: ContentIdentifier(rawValue: rawCid)) else {
                    throw NSError(domain: "NotFound", code: 404)
                }
                return data
            }
        }

        let keyPair = CryptoUtils.generateKeyPair()
        let address = CryptoUtils.createAddress(from: keyPair.publicKey)

        print("Token Chain")
        print("  Address: \\(address)")
        print("  Public Key: \\(String(keyPair.publicKey.prefix(16)))...")
        print("")

        let memory = MemoryCASWorker(capacity: 100_000)
        let fetcher = InMemoryFetcher(worker: memory)

        let spec = ChainSpec(
            directory: "TokenChain",
            maxNumberOfTransactionsPerBlock: 1000,
            maxStateGrowth: 500_000,
            premine: 0,
            targetBlockTime: 5_000,
            initialReward: 262_144,
            halvingInterval: 210_000
        )

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            difficulty: UInt256(1000),
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let genesisHeader = VolumeImpl<Block>(node: genesis)
        print("  Genesis: \\(String(genesisHeader.rawCID.prefix(24)))...")
        print("  Initial reward: \\(spec.initialReward) tokens")
        print("  Halving every: \\(spec.halvingInterval) blocks")
        """
    }

    var multiChainTemplate: String {
        """
        import Lattice
        import AcornMemoryWorker
        import Acorn
        import Foundation
        import UInt256

        struct InMemoryFetcher: Fetcher {
            let worker: MemoryCASWorker
            func fetch(rawCid: String) async throws -> Data {
                guard let data = await worker.getLocal(cid: ContentIdentifier(rawValue: rawCid)) else {
                    throw NSError(domain: "NotFound", code: 404)
                }
                return data
            }
        }

        let memory = MemoryCASWorker(capacity: 100_000)
        let fetcher = InMemoryFetcher(worker: memory)

        let nexusSpec = ChainSpec(
            directory: "Nexus",
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 210_000
        )

        let childSpec = ChainSpec(
            directory: "AppChain",
            maxNumberOfTransactionsPerBlock: 1000,
            maxStateGrowth: 500_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 262_144,
            halvingInterval: 210_000
        )

        print("Multi-Chain Lattice")
        print("  Nexus: \\(nexusSpec.directory) (\\(nexusSpec.targetBlockTime)ms blocks)")
        print("  Child:  \\(childSpec.directory) (\\(childSpec.targetBlockTime)ms blocks)")
        print("")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            difficulty: UInt256(1000),
            fetcher: fetcher
        )
        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let nexusHeader = VolumeImpl<Block>(node: nexusGenesis)
        print("  Nexus genesis: \\(String(nexusHeader.rawCID.prefix(24)))...")

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            difficulty: UInt256(1000),
            fetcher: fetcher
        )
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childHeader = VolumeImpl<Block>(node: childGenesis)
        print("  Child genesis:  \\(String(childHeader.rawCID.prefix(24)))...")

        let nexusLevel = ChainLevel(chain: nexusChain, children: [:])
        let _ = Lattice(nexus: nexusLevel)
        print("")
        print("  Lattice initialized with nexus + child chain")
        """
    }
}
