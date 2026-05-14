import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [
    public static let nexus: [PeerEndpoint] = [
    public static let nexus: [PeerEndpoint] = [
    ]

    public static let testnet: [PeerEndpoint] = [
        PeerEndpoint(publicKey: "b9ce59eb6e970d5c83113bf05c68ed2cb18a46e96622d91cec71e13f45ac7289", host: "109.105.221.182", port: 4001),
        PeerEndpoint(publicKey: "d530324f746121ca7875796cf8293086e8039e664cc58da2edf8f935d3bb88a4", host: "149.248.210.113", port: 4001),
        PeerEndpoint(publicKey: "dff9281501aa0453eb0157118a185df6f845eff83f1b60f3d3eab9fa53f0726e", host: "137.66.12.15", port: 4001),
    ]

    public static let maxPeerConnections: Int = 128
    public static let maxPeerConnectionsDiscovery: Int = 512
}
