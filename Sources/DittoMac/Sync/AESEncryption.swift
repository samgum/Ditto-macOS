import CryptoKit
import Foundation

/// AES-256-GCM encryption for LAN-sync payloads, keyed by a password.
///
/// The Windows original uses its own AES-256-CBC + SHA-256 key-stretching
/// scheme (see EncryptDecrypt/); on macOS we use CryptoKit's GCM, which gives
/// authenticated encryption in a single call. The wire format is therefore
/// macOS-to-macOS only, but provides the same guarantee: clips on the wire
/// are confidential and tamper-evident.
enum AESEncryption {
    private static let salt = "Ditto-macOS-network-sync-v1"

    static func encrypt(_ data: Data, password: String) throws -> Data {
        let key = deriveKey(password: password)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw AESError.combinationFailed
        }
        return combined
    }

    static func decrypt(_ data: Data, password: String) throws -> Data {
        let key = deriveKey(password: password)
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    private static func deriveKey(password: String) -> SymmetricKey {
        let passwordData = Data((password + salt).utf8)
        // HKDF over SHA-256 to derive a 256-bit key.
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: passwordData),
            salt: Data(salt.utf8),
            info: Data("ditto-lan-sync".utf8),
            outputByteCount: 32
        )
        return derived
    }

    enum AESError: Error {
        case combinationFailed
    }
}
