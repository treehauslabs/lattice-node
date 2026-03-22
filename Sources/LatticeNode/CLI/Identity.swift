import Lattice
import Foundation

struct IdentityFile: Codable {
    let publicKey: String
    let privateKey: String
}

func loadOrCreateIdentity(dataDir: URL) throws -> IdentityFile {
    let path = dataDir.appendingPathComponent("identity.json")
    if FileManager.default.fileExists(atPath: path.path) {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(IdentityFile.self, from: data)
    }
    let kp = CryptoUtils.generateKeyPair()
    let identity = IdentityFile(publicKey: kp.publicKey, privateKey: kp.privateKey)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(identity)
    try data.write(to: path)
    #if !os(Windows)
    chmod(path.path, 0o600)
    #endif
    return identity
}
