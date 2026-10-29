import CryptoKit
import XCTest
@testable import SamsungNotesKit

/// Answers in the place of Google: the token service and Drive's interface, with the app's
/// hidden folder kept in memory.
final class FakeGoogle: URLProtocol, @unchecked Sendable {
    struct File { var id: String; var name: String; var data: Data; var modified: Int }
    struct Call { var method: String; var host: String; var path: String; var query: [String: String]; var headers: [String: String]; var body: Data }

    static let lock = NSLock()
    nonisolated(unsafe) static var files: [File] = []
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var validTokens: Set<String> = []
    nonisolated(unsafe) static var issued = 0
    nonisolated(unsafe) static var clock = 0
    nonisolated(unsafe) static var revoked = false
    nonisolated(unsafe) static var grantedScope = GoogleAccount.scope
    nonisolated(unsafe) static var pageLimit = 1000
    nonisolated(unsafe) static var pending: [String: (name: String?, id: String?)] = [:]
    /// Requests to fail once with this status before answering properly.
    nonisolated(unsafe) static var hiccups: [Int] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        files = []; calls = []; validTokens = []; issued = 0; clock = 0; revoked = false; grantedScope = GoogleAccount.scope; pageLimit = 1000; pending = [:]; hiccups = []
    }

    static func count(_ method: String, _ part: String) -> Int { lock.lock(); defer { lock.unlock() }; return calls.filter { $0.method == method && $0.path.contains(part) }.count }
    static var names: [String] { lock.lock(); defer { lock.unlock() }; return files.map(\.name).sorted() }
    static func set(tokens: Set<String>? = nil, hiccups: [Int]? = nil, files: [File]? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let tokens { validTokens = tokens }
        if let hiccups { self.hiccups = hiccups }
        if let files { self.files = files }
    }
    static func put(_ name: String, _ data: Data) { lock.lock(); defer { lock.unlock() }; clock += 1; files.append(File(id: "f\(clock)", name: name, data: data, modified: clock)) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func time(_ value: Int) -> String { String(format: "2026-10-13T10:%02d:%02d.000Z", value / 60, value % 60) }
    private static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private static func described(_ file: File) -> [String: Any] { ["id": file.id, "name": file.name, "md5Checksum": md5(file.data), "modifiedTime": time(file.modified)] }

    /// The two parts of an upload that carries a file with its name.
    private static func parts(_ body: Data, type: String) -> (metadata: [String: Any], content: Data)? {
        guard let boundary = type.components(separatedBy: "boundary=").last else { return nil }
        let mark = Data("--\(boundary)".utf8), gap = Data("\r\n\r\n".utf8)
        guard let first = body.range(of: mark), let second = body.range(of: mark, in: first.upperBound..<body.count), let last = body.range(of: Data("\r\n--\(boundary)--".utf8), options: .backwards),
              let headOne = body.range(of: gap, in: first.upperBound..<second.lowerBound), let headTwo = body.range(of: gap, in: second.upperBound..<body.count) else { return nil }
        let metadata = (try? JSONSerialization.jsonObject(with: body.subdata(in: headOne.upperBound..<(second.lowerBound - 2)))) as? [String: Any]
        return metadata.map { ($0, body.subdata(in: headTwo.upperBound..<last.lowerBound)) }
    }

    private static func store(name: String?, id: String?, data: Data) -> (Int, Data) {
        clock += 1
        if let id {
            guard let index = files.firstIndex(where: { $0.id == id }) else { return (404, json(["error": ["message": "File not found"]])) }
            files[index].data = data
            files[index].modified = clock
            if let name { files[index].name = name }
            return (200, json(described(files[index])))
        }
        let made = File(id: "f\(clock)", name: name ?? "", data: data, modified: clock)
        files.append(made)
        return (200, json(described(made)))
    }

    private static func answer(_ call: Call) -> (Int, [String: String], Data) {
        if call.host == "oauth2.googleapis.com" {
            let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "http://x/?" + String(decoding: call.body, as: UTF8.self))?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if call.path == "/revoke" { revoked = true; return (200, [:], Data("{}".utf8)) }
            let good = fields["grant_type"] == "authorization_code" ? fields["code"] == "good-code" && fields["code_verifier"] != nil : fields["refresh_token"] == "lasting" && !revoked
            guard good, fields["client_id"] == "abc.apps.googleusercontent.com" else { return (400, [:], json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."])) }
            issued += 1
            let token = "access-\(issued)"
            validTokens = [token]
            var out: [String: Any] = ["access_token": token, "expires_in": 3600, "token_type": "Bearer", "scope": grantedScope]
            if fields["grant_type"] == "authorization_code" { out["refresh_token"] = "lasting" }
            return (200, [:], json(out))
        }
        guard let bearer = call.headers["Authorization"], bearer.hasPrefix("Bearer "), validTokens.contains(String(bearer.dropFirst(7))) else {
            return (401, [:], json(["error": ["code": 401, "message": "Invalid Credentials"]]))
        }
        if !hiccups.isEmpty { return (hiccups.removeFirst(), [:], json(["error": ["errors": [["reason": "userRateLimitExceeded"]]]])) }
        let path = call.path
        if path == "/drive/v3/about" { return (200, [:], json(["user": ["emailAddress": "user@example.com"]])) }
        if path == "/drive/v3/files", call.method == "GET" {
            guard call.query["spaces"] == "appDataFolder" else { return (400, [:], Data()) }
            let from = Int(call.query["pageToken"] ?? "") ?? 0
            let page = files.dropFirst(from).prefix(pageLimit)
            var out: [String: Any] = ["files": page.map(described)]
            if from + page.count < files.count { out["nextPageToken"] = String(from + page.count) }
            return (200, [:], json(out))
        }
        if path.hasPrefix("/drive/v3/files/") {
            let id = String(path.dropFirst("/drive/v3/files/".count))
            guard let index = files.firstIndex(where: { $0.id == id }) else { return (404, [:], json(["error": ["message": "File not found"]])) }
            if call.method == "DELETE" { files.remove(at: index); return (204, [:], Data()) }
            if call.method == "GET", call.query["alt"] == "media" { return (200, [:], files[index].data) }
        }
        if path.hasPrefix("/upload/drive/v3/files") {
            let id = path.count > "/upload/drive/v3/files/".count ? String(path.dropFirst("/upload/drive/v3/files/".count)) : nil
            if call.method == "PUT", let session = call.query["upload_id"], let begun = pending[session] {
                pending[session] = nil
                let (status, data) = store(name: begun.name, id: begun.id, data: call.body)
                return (status, [:], data)
            }
            guard call.method == (id == nil ? "POST" : "PATCH") else { return (400, [:], Data()) }
            if call.query["uploadType"] == "multipart", let (metadata, content) = parts(call.body, type: call.headers["Content-Type"] ?? "") {
                // A new file names the hidden folder as its place; one written over must not.
                guard (metadata["parents"] as? [String] == ["appDataFolder"]) == (id == nil) else { return (403, [:], Data()) }
                let (status, data) = store(name: metadata["name"] as? String, id: id, data: content)
                return (status, [:], data)
            }
            if call.query["uploadType"] == "resumable", let metadata = (try? JSONSerialization.jsonObject(with: call.body)) as? [String: Any] {
                if let id, !files.contains(where: { $0.id == id }) { return (404, [:], Data()) }
                clock += 1
                pending["u\(clock)"] = (metadata["name"] as? String, id)
                return (200, ["Location": "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=u\(clock)"], Data())
            }
        }
        return (400, [:], Data("unexpected \(call.method) \(path)".utf8))
    }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let call = Call(method: request.httpMethod ?? "GET", host: request.url?.host ?? "", path: request.url?.path ?? "", query: Dictionary(items.map { ($0.name, $0.value ?? "") }) { $1 },
                        headers: request.allHTTPHeaderFields ?? [:], body: body)
        FakeGoogle.lock.lock()
        FakeGoogle.calls.append(call)
        let (status, headers, data) = FakeGoogle.answer(call)
        FakeGoogle.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers.merging(["Content-Type": "application/json"]) { first, _ in first })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class Seen: @unchecked Sendable { var value: URL? }

final class GoogleDriveTests: XCTestCase {
    private var root: URL!
    private var http: HTTPClient!
    private let client = GoogleClient(id: "abc.apps.googleusercontent.com", secret: "not-a-secret")

    override func setUp() {
        FakeGoogle.reset()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-google-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        http = HTTPClient(protocolClasses: [FakeGoogle.self])
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func account(_ name: String = "google.json") -> GoogleAccount { GoogleAccount(store: FileSecretStore(url: root.appendingPathComponent(name)), http: http) }

    /// Plays the user's browser: opens the page's redirect with what Google would hand back.
    private func browser(answering fields: @escaping @Sendable (URLComponents) -> [URLQueryItem]) -> @Sendable (URL) -> Void {
        { page in
            let asked = URLComponents(url: page, resolvingAgainstBaseURL: false)!
            var back = URLComponents(string: asked.queryItems!.first { $0.name == "redirect_uri" }!.value!)!
            back.path = "/"
            back.queryItems = fields(asked)
            let url = back.url!
            Task.detached { _ = try? await URLSession.shared.data(from: url) }
        }
    }

    private func signedIn(_ name: String = "google.json") async throws -> GoogleAccount {
        let account = account(name)
        await account.setClient(client)
        try await account.signIn(timeout: 20, open: browser { asked in [URLQueryItem(name: "state", value: asked.queryItems!.first { $0.name == "state" }!.value), URLQueryItem(name: "code", value: "good-code")] })
        return account
    }

    private func file(_ name: String, _ text: String) throws -> CloudFile {
        let url = root.appendingPathComponent("out-" + UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return CloudFile(name: name, url: url)
    }

    private func read(_ changes: CloudChanges) -> [String: String] {
        Dictionary(uniqueKeysWithValues: changes.changed.map { ($0.name, (try? String(contentsOf: $0.url, encoding: .utf8)) ?? "?") })
    }

    // MARK: The account

    func testSigningInAsksInTheBrowserAndKeepsTheLastingPermission() async throws {
        let seen = Seen()
        let account = account()
        await account.setClient(client)
        let play = browser { asked in [URLQueryItem(name: "state", value: asked.queryItems!.first { $0.name == "state" }!.value), URLQueryItem(name: "code", value: "good-code")] }
        try await account.signIn(timeout: 20) { page in seen.value = page; play(page) }
        let page = URLComponents(url: try XCTUnwrap(seen.value), resolvingAgainstBaseURL: false)!
        let asked = Dictionary(uniqueKeysWithValues: page.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(page.host, "accounts.google.com")
        XCTAssertEqual(asked["client_id"], client.id)
        XCTAssertEqual(asked["scope"], "https://www.googleapis.com/auth/drive.appdata", "only the app's own folder is asked for")
        XCTAssertEqual(asked["access_type"], "offline")
        XCTAssertTrue(asked["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        // The code is redeemed with the verifier whose hash the page was given.
        let call = try XCTUnwrap(FakeGoogle.calls.first { $0.host == "oauth2.googleapis.com" })
        let sent = Dictionary(uniqueKeysWithValues: URLComponents(string: "http://x/?" + String(decoding: call.body, as: UTF8.self))!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(GoogleAccount.encoded(Data(SHA256.hash(data: Data(sent["code_verifier"]!.utf8)))), asked["code_challenge"])
        XCTAssertEqual(sent["redirect_uri"], asked["redirect_uri"])

        let signedIn = await account.isSignedIn, email = await account.email
        XCTAssertTrue(signedIn)
        XCTAssertEqual(email, "user@example.com")
        let first = try await account.accessToken()
        XCTAssertEqual(first, "access-1")
        let again = try await account.accessToken()
        XCTAssertEqual(again, "access-1", "a token that still holds is not asked for again")
        let fresh = try await account.accessToken(renew: true)
        XCTAssertEqual(fresh, "access-2")

        // Another launch of the app finds the account, and gets a token with the lasting one.
        let later = self.account()
        let still = await later.isSignedIn
        XCTAssertTrue(still)
        let next = try await later.accessToken()
        XCTAssertEqual(next, "access-3")
    }

    func testAClientWithoutASecretIsAnsweredAtTheAppsOwnAddress() async throws {
        // Registered with Google as an app: an ID, no secret, and an address scheme made of the ID.
        let app = GoogleClient(id: "abc.apps.googleusercontent.com")
        XCTAssertEqual(app.appScheme, "com.googleusercontent.apps.abc")
        XCTAssertNil(client.appScheme, "a client with a secret is answered on a port")
        XCTAssertNil(GoogleClient(id: "nonsense").appScheme)
        let account = account()
        await account.setClient(app)
        let pending = try await account.beginSignIn()
        XCTAssertEqual(pending.callbackScheme, "com.googleusercontent.apps.abc")
        let asked = Dictionary(uniqueKeysWithValues: URLComponents(url: pending.page, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(asked["redirect_uri"], "com.googleusercontent.apps.abc:/oauth2redirect")
        XCTAssertEqual(asked["scope"], GoogleAccount.scope)
        XCTAssertEqual(asked["code_challenge_method"], "S256")

        // An answer for another sign-in, or to another address, is not taken.
        for wrong in ["com.googleusercontent.apps.abc:/oauth2redirect?state=other&code=good-code", "com.example.other:/oauth2redirect?state=\(asked["state"]!)&code=good-code"] {
            do { try await account.completeSignIn(pending, callback: URL(string: wrong)!); XCTFail("took \(wrong)") } catch {}
        }
        XCTAssertTrue(FakeGoogle.calls.isEmpty)
        try await account.completeSignIn(pending, callback: URL(string: "com.googleusercontent.apps.abc:/oauth2redirect?state=\(asked["state"]!)&code=good-code&scope=x")!)
        let signedIn = await account.isSignedIn, email = await account.email
        XCTAssertTrue(signedIn)
        XCTAssertEqual(email, "user@example.com")
        _ = try await account.accessToken(renew: true)
        for call in FakeGoogle.calls where call.host == "oauth2.googleapis.com" {
            let sent = Dictionary(uniqueKeysWithValues: URLComponents(string: "http://x/?" + String(decoding: call.body, as: UTF8.self))!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertNil(sent["client_secret"], "no secret is sent for a client that has none")
            XCTAssertEqual(sent["client_id"], app.id)
        }
        XCTAssertEqual(FakeGoogle.calls.filter { $0.host == "oauth2.googleapis.com" }.count, 2)
        // A client with a secret has no such address to begin at.
        await account.setClient(client)
        do { _ = try await account.beginSignIn(); XCTFail("began at an address the client does not have") } catch {}
    }

    func testARefusalOnThePageIsNotASignIn() async throws {
        let account = account()
        await account.setClient(client)
        do {
            try await account.signIn(timeout: 20, open: browser { asked in [URLQueryItem(name: "state", value: asked.queryItems!.first { $0.name == "state" }!.value), URLQueryItem(name: "error", value: "access_denied")] })
            XCTFail("signed in after a refusal")
        } catch { XCTAssertEqual(error as? GoogleAccount.Failure, .cancelled) }
        // An answer that does not belong to this sign-in is not taken.
        do {
            try await account.signIn(timeout: 20, open: browser { _ in [URLQueryItem(name: "state", value: "someone-else"), URLQueryItem(name: "code", value: "good-code")] })
            XCTFail("signed in with a foreign answer")
        } catch { XCTAssertNotEqual(error as? GoogleAccount.Failure, nil) }
        // Signed in, but with the Drive left unticked.
        FakeGoogle.grantedScope = "openid"
        do {
            try await account.signIn(timeout: 20, open: browser { asked in [URLQueryItem(name: "state", value: asked.queryItems!.first { $0.name == "state" }!.value), URLQueryItem(name: "code", value: "good-code")] })
            XCTFail("signed in without the Drive")
        } catch {}
        let signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertEqual(FakeGoogle.calls.filter { $0.host == "oauth2.googleapis.com" }.count, 1)
    }

    func testNobodyAnsweringEndsTheWait() async throws {
        let account = account()
        await account.setClient(client)
        do { try await account.signIn(timeout: 0.3) { _ in }; XCTFail("signed in with no answer") } catch { XCTAssertEqual(error as? GoogleAccount.Failure, .cancelled) }
        do { try await self.account("none.json").signIn(timeout: 0.3) { _ in }; XCTFail("signed in with no client") } catch { XCTAssertEqual(error as? GoogleAccount.Failure, .noClient) }
    }

    func testPermissionTakenBackAsksToSignInAgainAndSigningOutGivesItBack() async throws {
        let account = try await signedIn()
        FakeGoogle.revoked = true
        do { _ = try await account.accessToken(renew: true); XCTFail("a token after the permission was taken back") } catch { XCTAssertEqual(error as? GoogleAccount.Failure, .signInAgain) }
        var signedIn = await account.isSignedIn
        XCTAssertFalse(signedIn)
        let kept = await account.client
        XCTAssertEqual(kept, client, "the client stays for the next sign-in")

        FakeGoogle.revoked = false
        let other = try await self.signedIn("other.json")
        await other.signOut()
        signedIn = await other.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertTrue(FakeGoogle.revoked)
        XCTAssertEqual(FakeGoogle.count("POST", "/revoke"), 1)
    }

    // MARK: The Drive

    func testFilesGoUpComeDownAndGo() async throws {
        let account = try await signedIn()
        let drive = account.drive(http: http)
        drive.simpleLimit = 64
        var changes = try await drive.changes(since: nil)
        XCTAssertTrue(changes.isEverything)
        XCTAssertTrue(changes.changed.isEmpty)
        let large = String(repeating: "large ", count: 100)
        try await drive.save([try file("notes/a/000001-mac.snote", "one"), try file("notes/a/picture", large), try file("tree/x.json", "{}")])
        XCTAssertEqual(FakeGoogle.names, ["notes/a/000001-mac.snote", "notes/a/picture", "tree/x.json"])
        XCTAssertEqual(FakeGoogle.count("PUT", "/upload/"), 1, "the large file went up in two steps")
        // What this Mac wrote is not news to it.
        let after = await drive.tokenAfterRound()
        changes = try await drive.changes(since: after)
        XCTAssertFalse(changes.isEverything)
        XCTAssertTrue(changes.changed.isEmpty && changes.deleted.isEmpty)

        // Another Mac sees all of it, and then only what changes.
        let other = try await signedIn("other.json").drive(http: http)
        other.simpleLimit = 64
        var theirs = try await other.changes(since: nil)
        XCTAssertEqual(read(theirs), ["notes/a/000001-mac.snote": "one", "notes/a/picture": large, "tree/x.json": "{}"])
        XCTAssertTrue(theirs.changed.allSatisfy(\.isTemporary))
        try await other.save([try file("tree/x.json", "{\"moved\":true}"), try file("notes/a/000002-other.snote", "two")])
        try await other.delete(["notes/a/000001-mac.snote", "never/there"])
        XCTAssertEqual(FakeGoogle.names, ["notes/a/000002-other.snote", "notes/a/picture", "tree/x.json"], "a file written again keeps its place")
        theirs = try await other.changes(since: await other.tokenAfterRound())
        XCTAssertTrue(theirs.changed.isEmpty && theirs.deleted.isEmpty)

        changes = try await drive.changes(since: after)
        XCTAssertEqual(read(changes), ["notes/a/000002-other.snote": "two", "tree/x.json": "{\"moved\":true}"])
        XCTAssertEqual(changes.deleted, ["notes/a/000001-mac.snote"])
    }

    func testListsInPagesAndClearsAwayDoubles() async throws {
        let drive = try await signedIn().drive(http: http)
        FakeGoogle.pageLimit = 2
        for index in 0..<5 { FakeGoogle.put("notes/n/\(index)", Data("v\(index)".utf8)) }
        // Two Macs wrote the same place at once: Drive keeps both under one name.
        FakeGoogle.put("tree/p.json", Data("older".utf8))
        FakeGoogle.put("tree/p.json", Data("newer".utf8))
        let changes = try await drive.changes(since: nil)
        XCTAssertEqual(changes.changed.count, 6)
        XCTAssertEqual(read(changes)["tree/p.json"], "newer")
        XCTAssertEqual(FakeGoogle.names.filter { $0 == "tree/p.json" }.count, 1, "the older double is gone")
        XCTAssertEqual(FakeGoogle.count("GET", "/drive/v3/files"), 4 + 6, "four pages, six downloads")
    }

    func testAStaleTokenIsRenewedAndGoogleIsGivenTime() async throws {
        let drive = try await signedIn().drive(http: http)
        drive.patience = 1
        FakeGoogle.put("tree/a.json", Data("a".utf8))
        // The token Google gave is no longer good there: one more is asked for, and the request goes again.
        FakeGoogle.set(tokens: [])
        var changes = try await drive.changes(since: nil)
        XCTAssertEqual(read(changes), ["tree/a.json": "a"])
        XCTAssertEqual(FakeGoogle.issued, 2)
        // Too many requests, and a fault at Google's end: waited out.
        FakeGoogle.set(hiccups: [403, 503])
        changes = try await drive.changes(since: nil)
        XCTAssertEqual(read(changes), ["tree/a.json": "a"])
        // A request Google will not have is an error that says so.
        FakeGoogle.set(hiccups: [403, 403, 403, 403, 403, 403])
        do { _ = try await drive.changes(since: nil); XCTFail("listed through a refusal") } catch { XCTAssertEqual((error as? GoogleDriveFiles.Refused)?.status, 403) }
    }

    func testAFileThatVanishedIsWrittenAnew() async throws {
        let drive = try await signedIn().drive(http: http)
        try await drive.save([try file("vault.json", "first")])
        FakeGoogle.set(files: [])
        try await drive.save([try file("vault.json", "second")])
        XCTAssertEqual(FakeGoogle.names, ["vault.json"])
        try await drive.removeEverything()
        XCTAssertEqual(FakeGoogle.names, [])
    }

    // MARK: Notes through the Drive

    func testNotesTravelBetweenTwoMacsThroughTheDrive() async throws {
        let storeA = LocalStore(root: root.appendingPathComponent("a")), storeB = LocalStore(root: root.appendingPathComponent("b"))
        let editsA = LocalEdits(store: storeA), editsB = LocalEdits(store: storeB)
        let a = CloudMirror(store: storeA, cloud: try await signedIn("a.json").drive(http: http), folder: root.appendingPathComponent("a/google"))
        let b = CloudMirror(store: storeB, cloud: try await signedIn("b.json").drive(http: http), folder: root.appendingPathComponent("b/google"))
        func text(_ store: LocalStore, _ id: String) throws -> String { try store.load(id).document.body.plain }
        func type(_ edits: LocalEdits, _ id: String, _ more: String) throws {
            var body = try XCTUnwrap(edits.richText(id)).body
            body.replace(body.length..<body.length, with: more)
            try edits.saveRich(id, title: nil, body: body)
        }

        let id = try editsA.createTextNote(title: "Trip", body: "Pack bags")
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7])
        _ = try editsA.addImage(id, data: picture, fileExtension: "jpg", pixelSize: CGSize(width: 30, height: 20))
        var out = try await a.sync()
        XCTAssertEqual(out.uploaded, 1)
        XCTAssertTrue(a.hasSynced)
        XCTAssertTrue(FakeGoogle.names.contains("notes/\(id)/\(NoteFile.sha256(picture))"))
        let uploads = FakeGoogle.count("POST", "/upload/"), downloads = FakeGoogle.count("GET", "/drive/v3/files/")
        out = try await a.sync()
        XCTAssertEqual(out, FolderSync.Outcome())
        XCTAssertEqual(FakeGoogle.count("POST", "/upload/"), uploads, "a second round sends nothing")
        XCTAssertEqual(FakeGoogle.count("GET", "/drive/v3/files/"), downloads, "and does not fetch what this Mac sent")

        out = try await b.sync()
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertEqual(storeB.loadLibrary().notes[id]?.title, "Trip")
        XCTAssertTrue(storeB.hasFile(id, NoteFile.sha256(picture)))

        // Changed on both before either synced: asked about, then settled.
        try type(editsA, id, "\nfrom A")
        try type(editsB, id, "\nfrom B")
        _ = try await a.sync()
        out = try await b.sync()
        XCTAssertEqual(out.conflicts.map(\.id), [id])
        XCTAssertTrue(try text(storeB, id).contains("from B"))
        out = try await b.sync(resolve: [id: .keepTheirs])
        XCTAssertTrue(try text(storeB, id).contains("from A"))
        XCTAssertEqual(FakeGoogle.names.filter { $0.hasPrefix("notes/\(id)/") && $0.hasSuffix(".snote") }.count, 1)

        // Deleted for good on A: gone from the Drive and from B.
        editsA.deleteForever(id)
        out = try await a.sync()
        XCTAssertEqual(out.removed, 1)
        XCTAssertFalse(FakeGoogle.names.contains { $0.hasPrefix("notes/\(id)/") })
        out = try await b.sync()
        XCTAssertNil(storeB.loadLibrary().notes[id])
    }
}
