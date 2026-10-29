import CommonCrypto
import CryptoKit
import Foundation

/// The password of locked notes, as Samsung's clients keep it: not the password but a
/// verifier of it, one for the whole account, kept in the service's settings so that every
/// device asks for the same password. A locked note itself is not encrypted with it: the
/// service delivers the note like any other, marked as locked, and each client asks for the
/// password before it shows it.
///
/// The verifier is PBKDF2 with HMAC-SHA1 over the password's UTF-8 bytes: a salt of 32 random
/// bytes, 4000 rounds, 32 bytes out; salt and result are written in lowercase hex.
public struct Passcode: Codable, Sendable, Equatable {
    public var hash: String
    public var salt: String
    /// When it was set, in milliseconds since 1970: the newer of two wins.
    public var time: Int64

    public static let minimumLength = 4

    public init(hash: String, salt: String, time: Int64) {
        self.hash = hash; self.salt = salt; self.time = time
    }

    static func derive(_ password: String, salt: Data) -> String? {
        let secret = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.map { Int8(bitPattern: $0) }, secret.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 4000, &out, out.count)
        }
        return status == kCCSuccess ? out.map { String(format: "%02x", $0) }.joined() : nil
    }

    /// True when this is the password the verifier was made from.
    public func verify(_ password: String) -> Bool {
        guard let bytes = AccountCrypto.data(hex: salt), !bytes.isEmpty, let made = Passcode.derive(password, salt: bytes) else { return false }
        // Compared without stopping at the first difference.
        let a = Array(made.utf8), b = Array(hash.lowercased().utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// A verifier for a new password, with a salt of its own.
    public static func make(_ password: String, now: Date = Date()) -> Passcode? {
        guard password.count >= minimumLength else { return nil }
        var salt = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess, let hash = derive(password, salt: Data(salt)) else { return nil }
        return Passcode(hash: hash, salt: salt.map { String(format: "%02x", $0) }.joined(), time: Int64(now.timeIntervalSince1970 * 1000))
    }

    /// Read from the service's settings: `<passcode syncModifiedTime="…">hash,salt</passcode>`.
    /// An empty element is an account without a password.
    init?(settings root: XMLNode) {
        guard let node = root.name == "passcode" ? root : root.descendant("passcode") else { return nil }
        let parts = (node.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        hash = String(parts[0]); salt = String(parts[1])
        time = Int64(node["syncModifiedTime"] ?? "") ?? 0
    }

    var settingsXML: String { "<Settings><passcode syncModifiedTime=\"\(time)\">\(hash.escapedXML),\(salt.escapedXML)</passcode></Settings>" }

    /// The mark a locked note carries for whose it is: SHA-256 of the account's user id, in hex.
    public static func owner(userID: String) -> String { SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined() }
}
