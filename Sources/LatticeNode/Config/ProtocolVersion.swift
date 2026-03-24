import Foundation

public enum LatticeProtocol {
    public static let version: UInt16 = 1
    public static let minSupportedVersion: UInt16 = 1
    public static let nodeVersion = "0.1.0"

    public struct ForkActivation: Sendable {
        public let name: String
        public let version: UInt16
        public let activationHeight: UInt64?
        public let description: String
    }

    public static let forks: [ForkActivation] = [
        ForkActivation(
            name: "genesis",
            version: 1,
            activationHeight: 0,
            description: "Initial protocol with PoW consensus, merged mining, CAS storage"
        ),
    ]

    public static func isCompatible(peerVersion: UInt16) -> Bool {
        peerVersion >= minSupportedVersion && peerVersion <= version
    }

    public static func activeForks(atHeight height: UInt64) -> [ForkActivation] {
        forks.filter { fork in
            guard let activation = fork.activationHeight else { return false }
            return height >= activation
        }
    }
}
