import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [
        PeerEndpoint(publicKey: "0279900839025fb532aabfb39bc28c4e5a3c33cdf637f14b1cea52a28f2776a977", host: "137.66.29.137", port: 4001),
        PeerEndpoint(publicKey: "0287be1a9db23bc66d2598fdd9a607c66088f4316009289a7a60b2fc61333820e7", host: "137.66.56.69", port: 4001),
        PeerEndpoint(publicKey: "03fbc457b8db9c6156661b98b592ffb1de12eea677fb345430a9171fc0673d9716", host: "188.93.144.135", port: 4001),
    ]

    public static let maxPeerConnections: Int = 128
    public static let maxPeerConnectionsDiscovery: Int = 512
}
