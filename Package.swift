// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatticeNode",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/treehauslabs/Lattice.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "LatticeNode",
            dependencies: [
                .product(name: "Lattice", package: "Lattice"),
            ]),
        .testTarget(
            name: "LatticeNodeTests",
            dependencies: ["LatticeNode"]),
    ]
)
