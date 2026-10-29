import XCTest
@testable import SamsungNotesKit

final class AccountCryptoTests: XCTestCase {
    /// A real redirect from the Windows client (2026-10-11): the code in it expired minutes later.
    func testWindowsRedirectDecryptsWithDerivedIV() throws {
        let state = "15wNPfqcwlXQnZfDSpS1QeGnoUPjCSY9"
        let cipher = try AccountCrypto.RedirectCipher(originalState: state, encryptedStateHex: "897ba5ad4b9ab6ebe4149fde2a4f522d6368b567ce042971f0b5279c14d48559709057fd85b747e5a178d239acbf89a4")
        XCTAssertEqual(try cipher.decrypt("c6dda628d46520e79125268fffc3d02614ffb3aba20f72fa54a27170e827a074"), "eu-auth2.samsungosp.com")
        XCTAssertEqual(try cipher.decrypt("c599a36478dccac832249407d29cfb55a673ab40e199ce9083c5b9fe318ba682").count, 25)
    }

    func testChallengeIsS256() {
        XCTAssertEqual(AccountCrypto.codeChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testPublicKeyUnwraps() throws {
        let key = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCylnSE8ANPUNPmgYJGnApUrUPQiBmTY44Lw+fQbFOOslZZnuUasDFJuPU4287/LBQEpTtgPWLmjGftG/b2sj8eTH46mvhDtE8ijgZsMnGPMmhu/AljEvNOqU6nDZDtgGmL/pAdEBtsJ/VzClv8G9bV1kvczuZtg0gt3JTH+pagEwIDAQAB"
        XCTAssertEqual(try AccountCrypto.rsaEncrypt(Data("hello".utf8), publicKeyBase64: key).count, 128)
    }
}
