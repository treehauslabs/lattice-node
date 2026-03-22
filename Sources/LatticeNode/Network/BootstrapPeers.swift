import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [
        PeerEndpoint(publicKey: "c4e97e41a73e469606f2a07fa313d9883e60c6a58a8515f95bc8d95e0604a8db0fdafc43917891b34d7bb3508897d53787a7dcd4076bddde997c356e98ed9974", host: "66.241.125.125", port: 4001),
        PeerEndpoint(publicKey: "9c66bfe87fe7c4ea34c34ddd0e44115135bb715b08d983209fbc25186b48c4973b5442e9b94f059c9ddf225d87ce3d0148e055e66dd67f7b42fbd20ef561ecdf", host: "66.241.124.20", port: 4001),
        PeerEndpoint(publicKey: "a7a870a0c09e87986536686fef511b4dbe561c304253e7d1863f7bec5b3a6aeb3c84e908027ed522fe15f1e6c5abcd60bbb7213dcbf1fe43f6246ad4a886e1ed", host: "66.241.125.133", port: 4001),
    ]

    public static let maxPeerConnections: Int = 128
}
