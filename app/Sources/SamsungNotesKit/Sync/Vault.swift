import CommonCrypto
import CryptoKit
import Foundation

/// The key that locked notes are encrypted with before they leave this Mac for a sync folder.
///
/// The key is 32 random bytes. It never leaves a Mac in the clear: beside the notes lies only
/// a copy of it locked with a password of the user's choosing (PBKDF2-HMAC-SHA256, then
/// ChaCha20-Poly1305), and each Mac keeps the key itself in its keychain once that password
/// has been typed there. Notes are sealed with ChaCha20-Poly1305, each under a nonce of its
/// own and bound to what it is (its note and version), so a sealed file cannot be passed off
/// as another.
public struct Vault: Sendable {
    public enum Failure: Error { case wrongPassword, damaged }

    let key: SymmetricKey

    /// A short name for the key, to tell whether a Mac holds the key the folder is locked with.
    public var keyID: String { Data(SHA256.hash(data: key.withUnsafeBytes { Data($0) })).prefix(6).map { String(format: "%02x", $0) }.joined() }

    public init() { key = SymmetricKey(size: .bits256) }

    init(key: SymmetricKey) { self.key = key }

    /// From what the keychain holds; nil when that is no key.
    public init?(stored: Data) {
        guard stored.count == 32 else { return nil }
        key = SymmetricKey(data: stored)
    }

    /// What the keychain is given to hold.
    public var stored: Data { key.withUnsafeBytes { Data($0) } }

    public func seal(_ data: Data, as what: String) throws -> Data {
        try ChaChaPoly.seal(data, using: key, authenticating: Data(what.utf8)).combined
    }

    public func open(_ sealed: Data, as what: String) throws -> Data {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed), let data = try? ChaChaPoly.open(box, using: key, authenticating: Data(what.utf8)) else { throw Failure.damaged }
        return data
    }

    // MARK: The copy that lies beside the notes

    /// The key locked with a password, as it is written into the sync folder.
    public struct Locked: Codable, Sendable, Equatable {
        public var format = 1
        public var keyID: String
        public var salt: String
        public var rounds: Int
        public var wrapped: String
        /// False once encrypting was switched off: the key still opens what was sealed with it.
        public var active = true

        /// True when the folder holds a copy of the key locked with a password. Without one the
        /// key travels another way: in the keychain that iCloud keeps the same on the user's Macs.
        public var hasPassword: Bool { !wrapped.isEmpty }

        /// Names a key without holding a copy of it.
        public init(keyOnly vault: Vault) {
            keyID = vault.keyID
            salt = ""
            rounds = 0
            wrapped = ""
        }

        init(keyID: String, salt: String, rounds: Int, wrapped: String) {
            self.keyID = keyID; self.salt = salt; self.rounds = rounds; self.wrapped = wrapped
        }
    }

    public static let rounds = 310_000

    private static func passwordKey(_ password: String, salt: Data, rounds: Int) -> SymmetricKey? {
        let secret = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.map { Int8(bitPattern: $0) }, secret.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(max(rounds, 1)), &out, out.count)
        }
        return status == kCCSuccess ? SymmetricKey(data: out) : nil
    }

    /// Locks the key with a password.
    public func locked(with password: String, rounds: Int = Vault.rounds) throws -> Locked {
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess, let wrapping = Vault.passwordKey(password, salt: Data(salt), rounds: rounds) else { throw Failure.damaged }
        let sealed = try ChaChaPoly.seal(stored, using: wrapping, authenticating: Data("snotes-vault-key".utf8)).combined
        return Locked(keyID: keyID, salt: Data(salt).base64EncodedString(), rounds: rounds, wrapped: sealed.base64EncodedString())
    }

    /// Opens the locked key with its password.
    public init(_ locked: Locked, password: String) throws {
        guard locked.hasPassword, let salt = Data(base64Encoded: locked.salt), let wrapped = Data(base64Encoded: locked.wrapped), let wrapping = Vault.passwordKey(password, salt: salt, rounds: locked.rounds),
              let box = try? ChaChaPoly.SealedBox(combined: wrapped) else { throw Failure.damaged }
        guard let raw = try? ChaChaPoly.open(box, using: wrapping, authenticating: Data("snotes-vault-key".utf8)), raw.count == 32 else { throw Failure.wrongPassword }
        key = SymmetricKey(data: raw)
    }
}
