import XCTest
@testable import SamsungNotesKit

final class AuthFlowTests: XCTestCase {
    /// From the page's redirect to a usable cloud token, with a real (long expired) redirect.
    func testSignInCompletesDownToTheCloudToken() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let secrets = FileSecretStore(url: folder.appendingPathComponent("account.json"))
        let http = HTTPClient(protocolClasses: [StubServer.self])
        let manager = AccountManager(store: secrets, http: http)
        StubServer.calls = []
        func form(_ call: StubServer.Call) -> [String: String] {
            var out: [String: String] = [:]
            for item in URLComponents(string: "x://x?" + String(decoding: call.body, as: UTF8.self))?.queryItems ?? [] { out[item.name] = item.value ?? "" }
            return out
        }
        StubServer.handler = { call in
            func json(_ text: String) -> (Int, String, Data) { (200, "application/json", Data(text.utf8)) }
            switch call.path {
            case "/auth/oauth2/authenticate": return json(#"{"userauth_token_expires_in":31536000,"userauth_token":"MASTERTOKEN","userId":"uid123"}"#)
            case "/auth/oauth2/v2/authorize": return json(#"{"code":"SERVICECODE","code_expires_in":300,"privacyAccepted":"N","requireTncAccepted":"N"}"#)
            case "/auth/oauth2/token": return json(#"{"access_token":"ACCESS","refresh_token_expires_in":7776000,"refresh_token":"REFRESHTOKEN","token_type":"bearer","expires_in":88604,"userId":"uid123","access_token_expires_in":88604}"#)
            case "/ers/v1/endpoints": return json(#"{"default":"https://api.samsungcloud.com","play":"https://play.samsungcloud.com","odm":"https://play.samsungcloud.com"}"#)
            case "/identity/v2/user/register": return json(#"{"dvcId":"dvc","tokens":[{"type":"user","accessToken":"CLOUDUSER","expiresAt":\#(Int(Date().timeIntervalSince1970) + 89299),"expiresIn":89299},{"type":"device","accessToken":"CLOUDDEVICE","expiresIn":179100}]}"#)
            default: return (404, "text/plain", Data())
            }
        }
        let state = "15wNPfqcwlXQnZfDSpS1QeGnoUPjCSY9"
        let pending = SamsungAccount.Pending(state: state, verifier: String(repeating: "v", count: 50), deviceID: "0123456789abcdef0123456789abcdef", createdAt: Date(), signInURL: URL(string: "https://account.samsung.com/")!)
        let redirect = URL(string: "ms-app://s-1-15-2-4027708247-2189610-1983755848-2937435718-1578786913-2158692839-1974417358/?status=new&code=c599a36478dccac832249407d29cfb55a673ab40e199ce9083c5b9fe318ba682&api_server_url=c6dda628d46520e79125268fffc3d02614ffb3aba20f72fa54a27170e827a074&auth_server_url=c6dda628d46520e79125268fffc3d02614ffb3aba20f72fa54a27170e827a074&code_expires_in=300&retValue=d774ff496d9a3804dfea6b4cf9298154c56bef152b547dcf5c9fc4d693de8afc&state=897ba5ad4b9ab6ebe4149fde2a4f522d6368b567ce042971f0b5279c14d48559709057fd85b747e5a178d239acbf89a4")!
        XCTAssertTrue(SamsungAccount.isRedirect(redirect))
        try await manager.completeSignIn(redirect: redirect, pending: pending, country3: "USA")

        let authenticate = form(try XCTUnwrap(StubServer.calls.first { $0.path == "/auth/oauth2/authenticate" }))
        XCTAssertEqual(authenticate["grant_type"], "authorization_code")
        XCTAssertEqual(authenticate["client_id"], "yfrtglt53o")
        XCTAssertEqual(authenticate["code"]?.count, 25)
        XCTAssertEqual(authenticate["code_verifier"], pending.verifier)
        XCTAssertEqual(authenticate["serviceType"], "M")
        XCTAssertEqual(authenticate["physical_address_text"]?.count, 36)
        XCTAssertEqual(authenticate["username"], "user@example.com")
        let authorize = form(try XCTUnwrap(StubServer.calls.first { $0.path == "/auth/oauth2/v2/authorize" }))
        XCTAssertEqual(authorize["client_id"], "tcl0p60gnz")
        XCTAssertEqual(authorize["userauth_token"], "MASTERTOKEN")
        XCTAssertEqual(authorize["scope"], "offline.access")
        XCTAssertEqual(authorize["code_challenge_method"], "S256")
        XCTAssertEqual(authorize["code_challenge"]?.count, 43)
        XCTAssertEqual(authorize["login_id"], authenticate["username"])
        let token = form(try XCTUnwrap(StubServer.calls.first { $0.path == "/auth/oauth2/token" }))
        XCTAssertEqual(token["code"], "SERVICECODE")
        XCTAssertEqual(token["client_id"], "tcl0p60gnz")
        let register = try XCTUnwrap(StubServer.calls.first { $0.path == "/identity/v2/user/register" })
        XCTAssertEqual(register.headers["x-sc-access-token"], "ACCESS")
        XCTAssertEqual(register.headers["x-sc-uid"], "uid123")
        XCTAssertEqual(register.headers["x-sc-app-id"], "tcl0p60gnz")
        XCTAssertEqual(register.headers["x-sc-pdid"]?.count, 32)
        let device = try XCTUnwrap((try JSONSerialization.jsonObject(with: register.body) as? [String: Any])?["device"] as? [String: Any])
        XCTAssertEqual(device["osType"] as? String, "win")
        XCTAssertEqual(device["type"] as? String, "pc")

        let cloudToken = try await manager.cloudToken()
        XCTAssertEqual(cloudToken, "CLOUDUSER")
        XCTAssertEqual(StubServer.calls.filter { $0.path == "/identity/v2/user/register" }.count, 1, "a fresh token is not asked for again")
        // A new manager reads the same account back from the store.
        let reopened = AccountManager(store: secrets, http: http)
        let signedIn = await reopened.isSignedIn
        XCTAssertTrue(signedIn)
        let saved = await reopened.state
        XCTAssertEqual(saved.session?.authServer, "https://eu-auth2.samsungosp.com")
        XCTAssertEqual(saved.oauth?.refreshToken, "REFRESHTOKEN")
        await reopened.signOut()
        let after = await AccountManager(store: secrets, http: http).isSignedIn
        XCTAssertFalse(after)
    }

    func testAnswersNamingForeignServersAreRefused() {
        XCTAssertThrowsError(try SamsungAccount.trustedServer("evil.example.com"))
        XCTAssertThrowsError(try SamsungAccount.trustedServer("eu-auth2.samsungosp.com.evil.example"))
        XCTAssertThrowsError(try SamsungAccount.trustedServer("user@eu-auth2.samsungosp.com"))
        XCTAssertThrowsError(try SamsungAccount.trustedServer("evil.com?.samsungosp.com"))
        XCTAssertThrowsError(try SamsungAccount.trustedServer("evil.com#.samsungosp.com"))
        XCTAssertThrowsError(try SamsungAccount.trustedServer("evil.com/.samsungosp.com"))
        XCTAssertThrowsError(try SamsungAccount.trustedServer("eu-auth2.samsungosp.com:8443"))
        XCTAssertThrowsError(try SamsungAccount.trustedServer("http://eu-auth2.samsungosp.com"))
        XCTAssertEqual(try SamsungAccount.trustedServer("https://EU-auth2.samsungosp.com/"), "https://eu-auth2.samsungosp.com")
        XCTAssertEqual(try SamsungAccount.trustedServer("eu-auth2.samsungosp.com"), "https://eu-auth2.samsungosp.com")
    }
}
