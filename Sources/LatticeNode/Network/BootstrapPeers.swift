import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [
        PeerEndpoint(publicKey: "dcdd3d6a1bebe130635ba49de9a35e9f0398f43f1a4fca2d44b55f6dc731d7e6104186e008364a4562c8f2342210ae90c8868ac5ab509a879722de07a88ee39d", host: "137.66.46.104", port: 4001),
        PeerEndpoint(publicKey: "c90a666d1ed0e45df629257fad836d1a5c29a7a8af3fc46327e2131f046955293d774a4f3a1daa912359348a9abed75554a3ac4cc6d174260a410a460128d9d8", host: "169.155.61.117", port: 4001),
        PeerEndpoint(publicKey: "b031da1bc8175aaec0437512faccb2aa63a87591fd8e1dcbe6b467881c07b8a149457b2f37e6f70508c66dbbc86ae12bc1cf5b17057d0e4b6f6710887a2f15b8", host: "213.188.217.62", port: 4001),
    ]

    public static let maxPeerConnections: Int = 128
    public static let maxPeerConnectionsDiscovery: Int = 512
}
