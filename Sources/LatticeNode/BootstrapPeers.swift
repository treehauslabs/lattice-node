import Lattice
import Ivy

public enum BootstrapPeers {
    public static let nexus: [PeerEndpoint] = [
        // Bootstrap nodes will be populated after initial deployment.
        // Run `terraform output node_ips` to get the IPs, then
        // `ssh root@<ip> "docker logs lattice-miner 2>&1 | grep 'Public key'"` for keys.
        //
        // Format: PeerEndpoint(publicKey: "<64-char-hex>", host: "<ip>", port: 4001)
    ]

    public static let maxPeerConnections: Int = 128
}
