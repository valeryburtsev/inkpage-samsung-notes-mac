import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The cryptography of Samsung account's web sign-in, as observed from the Windows client on
/// 2026-10-11 and cross-checked with the uTag wiki and samsung-re-find (MIT).
public enum AccountCrypto {
    public enum Failure: Error { case badPublicKey, encryptionFailed, decryptionFailed, badHex }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Letters and digits only: Samsung's state and verifier strings are plain alphanumerics.
    public static func randomAlphanumeric(_ count: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String(randomBytes(count).map { alphabet[Int($0) % alphabet.count] })
    }

    public static func randomHex(_ byteCount: Int) -> String {
        randomBytes(byteCount).map { String(format: "%02x", $0) }.joined()
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// PKCE S256 challenge for a verifier.
    public static func codeChallenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var derived = [UInt8](repeating: 0, count: keyLength)
        password.withUnsafeBytes { pw in
            salt.withUnsafeBytes { st in
                _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.bindMemory(to: Int8.self).baseAddress, password.count,
                                         st.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(max(1, iterations)), &derived, keyLength)
            }
        }
        return Data(derived)
    }

    static func aes(_ operation: Int, key: Data, iv: Data?, data: Data, padding: Bool) -> Data? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        var options = CCOptions(padding ? kCCOptionPKCS7Padding : 0)
        if iv == nil { options |= CCOptions(kCCOptionECBMode) }
        let status = key.withUnsafeBytes { k in
            data.withUnsafeBytes { d in
                (iv ?? Data(count: 16)).withUnsafeBytes { v in
                    CCCrypt(CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), options, k.baseAddress, key.count,
                            v.baseAddress, d.baseAddress, data.count, &out, out.count, &moved)
                }
            }
        }
        return status == kCCSuccess ? Data(out.prefix(moved)) : nil
    }

    public static func aesCBCEncrypt(key: Data, iv: Data, plaintext: Data) -> Data? { aes(kCCEncrypt, key: key, iv: iv, data: plaintext, padding: true) }
    public static func aesCBCDecrypt(key: Data, iv: Data, ciphertext: Data) -> Data? { aes(kCCDecrypt, key: key, iv: iv, data: ciphertext, padding: true) }
    public static func aesECBDecrypt(key: Data, ciphertext: Data, padding: Bool = true) -> Data? { aes(kCCDecrypt, key: key, iv: nil, data: ciphertext, padding: padding) }

    /// RSA PKCS#1 v1.5 encryption with a public key given as base64 SubjectPublicKeyInfo.
    public static func rsaEncrypt(_ data: Data, publicKeyBase64: String) throws -> Data {
        guard let spki = Data(base64Encoded: publicKeyBase64), let pkcs1 = rsaKeyFromSPKI(spki) else { throw Failure.badPublicKey }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, data as CFData, &error) else { throw Failure.encryptionFailed }
        return encrypted as Data
    }

    /// The RSAPublicKey inside a SubjectPublicKeyInfo: SEQUENCE { SEQUENCE alg, BIT STRING key }.
    static func rsaKeyFromSPKI(_ der: Data) -> Data? {
        let bytes = [UInt8](der)
        var index = 0
        func header() -> (tag: UInt8, length: Int)? {
            guard index + 2 <= bytes.count else { return nil }
            let tag = bytes[index]; index += 1
            var length = Int(bytes[index]); index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(bytes[index]); index += 1 }
            }
            return (tag, length)
        }
        guard let outer = header(), outer.tag == 0x30, let algorithm = header(), algorithm.tag == 0x30 else { return nil }
        index += algorithm.length
        guard let bits = header(), bits.tag == 0x03, index + bits.length <= bytes.count, bits.length > 1 else { return nil }
        return Data(bytes[(index + 1)..<(index + bits.length)])
    }

    /// The `svcParam` query value: the request JSON under AES-CBC with a PBKDF2 key, the key under RSA.
    public static func encryptServiceParameter(json: Data, chkDoNum: String, iterations: Int, publicKeyBase64: String) throws -> String {
        let password = Data(Data(SHA256.hash(data: Data(chkDoNum.utf8))).base64EncodedString().utf8)
        let key = pbkdf2SHA256(password: password, salt: randomBytes(16), iterations: iterations, keyLength: 16)
        let wrapped = try rsaEncrypt(Data(key.base64EncodedString().utf8), publicKeyBase64: publicKeyBase64)
        let iv = randomBytes(16)
        guard let encrypted = aesCBCEncrypt(key: key, iv: iv, plaintext: json) else { throw Failure.encryptionFailed }
        let envelope: [String: String] = [
            "chkDoNum": chkDoNum,
            "svcEncParam": encrypted.base64EncodedString(),
            "svcEncKY": wrapped.base64EncodedString(),
            "svcEncIV": iv.map { String(format: "%02x", $0) }.joined(),
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return body.base64EncodedString()
    }

    public static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte); index = next
        }
        return out
    }

    /// Decrypts the fields of the sign-in redirect. The key is the first 16 bytes of the state we
    /// sent. The Android flow answers in AES-ECB. The Windows flow answers in AES-CBC with an IV
    /// that is not in the redirect; since the encrypted `state` field is our own state string, its
    /// first block gives that IV back.
    public struct RedirectCipher {
        let key: Data
        let iv: Data?

        public init(originalState: String, encryptedStateHex: String) throws {
            var keyBytes = Data(originalState.utf8.prefix(16))
            while keyBytes.count < 16 { keyBytes.append(0) }
            key = keyBytes
            guard let cipher = AccountCrypto.data(hex: encryptedStateHex), cipher.count >= 16 else { throw Failure.badHex }
            if let plain = AccountCrypto.aesECBDecrypt(key: key, ciphertext: cipher), String(data: plain, encoding: .utf8) == originalState {
                iv = nil
                return
            }
            guard let firstBlock = AccountCrypto.aesECBDecrypt(key: key, ciphertext: cipher.prefix(16), padding: false), firstBlock.count == 16 else { throw Failure.decryptionFailed }
            let expected = [UInt8](keyBytes)
            let derived = Data(zip([UInt8](firstBlock), expected).map { $0 ^ $1 })
            guard let plain = AccountCrypto.aesCBCDecrypt(key: key, iv: derived, ciphertext: cipher),
                  let text = String(data: plain, encoding: .utf8), text.hasPrefix(originalState.prefix(16)) else { throw Failure.decryptionFailed }
            iv = derived
        }

        public func decrypt(_ hex: String) throws -> String {
            guard let cipher = AccountCrypto.data(hex: hex) else { throw Failure.badHex }
            let plain = iv.map { AccountCrypto.aesCBCDecrypt(key: key, iv: $0, ciphertext: cipher) } ?? AccountCrypto.aesECBDecrypt(key: key, ciphertext: cipher)
            guard let plain, let text = String(data: plain, encoding: .utf8) else { throw Failure.decryptionFailed }
            return text
        }
    }
}
