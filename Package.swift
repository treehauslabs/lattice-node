// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatticeNode",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/treehauslabs/Lattice.git", from: "3.9.1"),
        .package(url: "https://github.com/treehauslabs/Acorn.git", from: "1.0.0"),
        .package(url: "https://github.com/treehauslabs/AcornDiskWorker.git", from: "1.0.1"),
        .package(url: "https://github.com/treehauslabs/AcornMemoryWorker.git", from: "1.0.0"),
        .package(url: "https://github.com/treehauslabs/Tally.git", from: "1.1.0"),
        .package(url: "https://github.com/treehauslabs/Ivy.git", from: "2.2.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "LatticeNode",
            dependencies: [
                "CSQLite",
                .product(name: "Lattice", package: "Lattice"),
                .product(name: "Acorn", package: "Acorn"),
                .product(name: "AcornDiskWorker", package: "AcornDiskWorker"),
                .product(name: "AcornMemoryWorker", package: "AcornMemoryWorker"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "Ivy", package: "Ivy"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(
            name: "LatticeNodeTests",
            dependencies: ["LatticeNode"]),
    ]
)
