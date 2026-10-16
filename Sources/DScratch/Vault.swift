import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Password-based encryption for locked pages.
/// Key: PBKDF2-HMAC-SHA256 (310k rounds, 16-byte random salt). Cipher: AES-256-GCM.
enum Vault {
    static let rounds: UInt32 = 310_000

    static func randomSalt() -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return salt
    }

    static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        var derived = Data(count: 32)
        let passwordLength = password.utf8.count
        derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, passwordLength,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                    out.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        return SymmetricKey(data: derived)
    }

    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.seal(data, using: key).combined!
    }

    /// Throws if the key is wrong (GCM authentication fails).
    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}
