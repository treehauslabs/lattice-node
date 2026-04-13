import Lattice
import Foundation
import Crypto

struct IdentityFile: Codable {
    let publicKey: String
    let privateKey: String?
    let encryptedPrivateKey: String?
    let salt: String?
}

enum IdentityError: Error {
    case decryptionFailed
    case missingPrivateKey
    case invalidKeyData
}

func loadOrCreateIdentity(dataDir: URL, password: String? = nil) throws -> IdentityFile {
    let path = dataDir.appendingPathComponent("identity.json")
    if FileManager.default.fileExists(atPath: path.path) {
        let data = try Data(contentsOf: path)
        let identity = try JSONDecoder().decode(IdentityFile.self, from: data)

        // If file has encrypted key but no plaintext, decrypt it
        if identity.privateKey == nil, let encrypted = identity.encryptedPrivateKey, let saltHex = identity.salt {
            guard let password else { throw IdentityError.missingPrivateKey }
            let decrypted = try decryptKey(encrypted: encrypted, saltHex: saltHex, password: password)
            return IdentityFile(publicKey: identity.publicKey, privateKey: decrypted, encryptedPrivateKey: encrypted, salt: saltHex)
        }

        // Migrate: if plaintext key exists and password provided, encrypt it
        if let privKey = identity.privateKey, let password, !password.isEmpty {
            let (encrypted, salt) = try encryptKey(privateKey: privKey, password: password)
            let upgraded = IdentityFile(publicKey: identity.publicKey, privateKey: nil, encryptedPrivateKey: encrypted, salt: salt)
            let encoded = try JSONEncoder().encode(upgraded)
            try encoded.write(to: path)
            #if !os(Windows)
            chmod(path.path, 0o600)
            #endif
            return IdentityFile(publicKey: identity.publicKey, privateKey: privKey, encryptedPrivateKey: encrypted, salt: salt)
        }

        return identity
    }

    let kp = CryptoUtils.generateKeyPair()

    let identity: IdentityFile
    if let password, !password.isEmpty {
        let (encrypted, salt) = try encryptKey(privateKey: kp.privateKey, password: password)
        identity = IdentityFile(publicKey: kp.publicKey, privateKey: nil, encryptedPrivateKey: encrypted, salt: salt)
    } else {
        identity = IdentityFile(publicKey: kp.publicKey, privateKey: kp.privateKey, encryptedPrivateKey: nil, salt: nil)
    }

    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(identity)
    try data.write(to: path)
    #if !os(Windows)
    chmod(path.path, 0o600)
    #endif
    return IdentityFile(publicKey: kp.publicKey, privateKey: kp.privateKey, encryptedPrivateKey: identity.encryptedPrivateKey, salt: identity.salt)
}

private func encryptKey(privateKey: String, password: String) throws -> (encrypted: String, salt: String) {
    var salt = [UInt8](repeating: 0, count: 16)
    #if canImport(Darwin)
    _ = salt.withUnsafeMutableBufferPointer { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    #else
    if let f = fopen("/dev/urandom", "r") { defer { fclose(f) }; _ = fread(&salt, 1, 16, f) }
    #endif

    let key = deriveKey(password: password, salt: salt)
    let nonce = try AES.GCM.Nonce(data: Data(salt.prefix(12)))
    let sealed = try AES.GCM.seal(Data(privateKey.utf8), using: key, nonce: nonce)
    guard let combined = sealed.combined else { throw IdentityError.invalidKeyData }
    return (combined.map { String(format: "%02x", $0) }.joined(), salt.map { String(format: "%02x", $0) }.joined())
}

private func decryptKey(encrypted: String, saltHex: String, password: String) throws -> String {
    guard let encData = Data(hex: encrypted), let salt = Data(hex: saltHex) else {
        throw IdentityError.invalidKeyData
    }
    let key = deriveKey(password: password, salt: Array(salt))
    let box = try AES.GCM.SealedBox(combined: encData)
    let decrypted = try AES.GCM.open(box, using: key)
    guard let result = String(data: decrypted, encoding: .utf8) else {
        throw IdentityError.decryptionFailed
    }
    return result
}

private func deriveKey(password: String, salt: [UInt8]) -> SymmetricKey {
    // HKDF key derivation from password + salt
    let inputKey = SymmetricKey(data: Data(password.utf8))
    let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKey, salt: Data(salt), info: Data("lattice-identity".utf8), outputByteCount: 32)
    return derived
}

// Data(hex:) is provided by the Lattice library via CryptoUtils
