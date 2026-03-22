// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatticeNode",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/treehauslabs/Lattice.git", from: "3.1.0"),
        .package(url: "https://github.com/treehauslabs/Acorn.git", from: "1.0.0"),
        .package(url: "https://github.com/treehauslabs/AcornDiskWorker.git", branch: "master"),
        .package(url: "https://github.com/treehauslabs/AcornMemoryWorker.git", branch: "master"),
        .package(url: "https://github.com/treehauslabs/Tally.git", from: "1.0.0"),
        .package(url: "https://github.com/treehauslabs/Ivy.git", from: "2.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "LatticeNode",
            dependencies: [
                .product(name: "Lattice", package: "Lattice"),
                .product(name: "Acorn", package: "Acorn"),
                .product(name: "AcornDiskWorker", package: "AcornDiskWorker"),
                .product(name: "AcornMemoryWorker", package: "AcornMemoryWorker"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "Ivy", package: "Ivy"),
            ]),
        .testTarget(
            name: "LatticeNodeTests",
            dependencies: ["LatticeNode"]),
    ]
)
