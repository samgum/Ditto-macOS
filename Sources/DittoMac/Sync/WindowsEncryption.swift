import CommonCrypto
import CryptoKit
import Foundation

/// Faithful port of the Windows Ditto `CEncryption` (EncryptDecrypt/) so this
/// app can exchange encrypted clips with a real Windows Ditto peer.
///
/// Algorithm (KeePass-style AES-KDF + AES-256-CBC), reproduced exactly from
/// Encryption.cpp / Encryption.h:
///
///   masterKey     = SHA-256(password)
///   transformedKey = AES-256-ECB(masterKey) repeated dwKeyEncRounds times,
///                    keyed by aMasterSeed2 (both 16-byte halves per round)
///   finalKey      = SHA-256(aMasterSeed || transformedKey)
///   ciphertext    = AES-256-CBC(plaintext, finalKey, aEncryptionIV)  [PKCS#7]
///
/// Wire layout (TD_TLHEADER, 140 bytes, naturally packed):
///   [0]   aHeaderHash[32]   SHA-256 of bytes [32..140)
///   [32]  dwSignature1      0x139C5AFE
///   [36]  dwSignature2      0xBF3562DA
///   [40]  aMasterSeed[16]
///   [56]  aEncryptionIV[16]
///   [72]  aContentsHash[32] SHA-256(plaintext)
///   [104] aMasterSeed2[32]
///   [136] dwKeyEncRounds    100000
enum WindowsEncryption {
    static let signature1: UInt32 = 0x139C5AFE
    static let signature2: UInt32 = 0xBF3562DA
    static let keyEncRounds: UInt32 = 100_000
    static let headerSize = 140

    enum Error: Swift.Error {
        case invalidHeader
        case signatureMismatch
        case integrityFailed
        case cryptoFailed(Int32)
    }

    // MARK: - Encrypt

    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        let masterSeed = randomBytes(16)
        let iv = randomBytes(16)
        let masterSeed2 = randomBytes(32) // AES-256 key for the transform rounds

        let masterKey = sha256(Data(password.utf8))
        let transformedKey = transformKey(masterKey: masterKey, seed2: masterSeed2)
        let finalKey = sha256(masterSeed + transformedKey)

        let contentsHash = sha256(plaintext)
        let ciphertext = try aesCBC(plaintext, key: finalKey, iv: iv, encrypt: true)

        var header = Data()
        header.append(Data(repeating: 0, count: 32))            // aHeaderHash placeholder
        header.append(uint32LE: signature1)                      // dwSignature1
        header.append(uint32LE: signature2)                      // dwSignature2
        header.append(masterSeed)                                // aMasterSeed[16]
        header.append(iv)                                        // aEncryptionIV[16]
        header.append(contentsHash)                              // aContentsHash[32]
        header.append(masterSeed2)                               // aMasterSeed2[32] — but see note
        header.append(uint32LE: keyEncRounds)                    // dwKeyEncRounds

        // aMasterSeed2 is 32 bytes in the struct; the AES transform key uses
        // 32 bytes (AES-256). Match the struct: 32-byte seed2.
        precondition(header.count == headerSize)

        // aHeaderHash = SHA-256(header[32..<140])
        let headerHash = sha256(header.subdata(in: 32..<headerSize))
        header.replaceSubrange(0..<32, with: headerHash)

        var output = Data()
        output.append(header)
        output.append(ciphertext)
        return output
    }

    // MARK: - Decrypt

    static func decrypt(_ input: Data, password: String) throws -> Data {
        guard input.count > headerSize else { throw Error.invalidHeader }
        let header = input.subdata(in: 0..<headerSize)

        let storedHeaderHash = header.subdata(in: 0..<32)
        let computedHeaderHash = sha256(header.subdata(in: 32..<headerSize))
        guard computedHeaderHash == storedHeaderHash else { throw Error.integrityFailed }

        let sig1 = header.subdata(in: 32..<36).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let sig2 = header.subdata(in: 36..<40).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard sig1 == signature1, sig2 == signature2 else { throw Error.signatureMismatch }

        let masterSeed = header.subdata(in: 40..<56)
        let iv = header.subdata(in: 56..<72)
        let contentsHash = header.subdata(in: 72..<104)
        let masterSeed2 = header.subdata(in: 104..<136)
        // dwKeyEncRounds at 136..<140 — we use the fixed default for the transform.

        let masterKey = sha256(Data(password.utf8))
        let transformedKey = transformKey(masterKey: masterKey, seed2: masterSeed2)
        let finalKey = sha256(masterSeed + transformedKey)

        let ciphertext = input.subdata(in: headerSize..<input.count)
        let plaintext = try aesCBC(ciphertext, key: finalKey, iv: iv, encrypt: false)

        guard sha256(plaintext) == contentsHash else { throw Error.integrityFailed }
        return plaintext
    }

    // MARK: - Primitives

    /// KeePass AES-KDF transform: 100,000 rounds of AES-ECB over the 32-byte
    /// master key, keyed by seed2 (AES-256, both 16-byte halves per round).
    private static func transformKey(masterKey: Data, seed2: Data) -> Data {
        var current = masterKey
        for _ in 0..<keyEncRounds {
            current = aesECB(current, key: seed2, encrypt: true)
        }
        return current
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func aesECB(_ input: Data, key: Data, encrypt: Bool) -> Data {
        let outputSize = input.count
        var output = Data(count: outputSize)
        var moved: Int = 0
        var status: Int32 = -1
        input.withUnsafeBytes { inBytes in
            key.withUnsafeBytes { keyBytes in
                output.withUnsafeMutableBytes { outBytes in
                    status = CCCrypt(
                        encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count,
                        nil,
                        inBytes.baseAddress, input.count,
                        outBytes.baseAddress, outputSize,
                        &moved
                    )
                }
            }
        }
        return status == kCCSuccess ? output : input
    }

    private static func aesCBC(_ input: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        let bufferSize = input.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var moved: Int = 0
        var status: Int32 = -1
        input.withUnsafeBytes { inBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    buffer.withUnsafeMutableBytes { outBytes in
                        status = CCCrypt(
                            encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, input.count,
                            outBytes.baseAddress, bufferSize,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Error.cryptoFailed(status) }
        return buffer.prefix(moved)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        return data
    }
}

private extension Data {
    mutating func append(uint32LE value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<UInt32>.size))
    }
}
