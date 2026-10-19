import XCTest
@testable import SamsungNotesKit

/// Answers the engine's requests in place of Samsung Cloud and keeps what it was sent.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Call { let method: String; let path: String; let query: String; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var handler: ((Call) -> (Int, String, Data))?
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        if request.value(forHTTPHeaderField: "Content-Encoding") == "gzip", let plain = Gzip.decompress(body) { body = plain }
        let call = Call(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", query: request.url?.query ?? "", headers: request.allHTTPHeaderFields ?? [:], body: body)
        StubServer.lock.lock()
        StubServer.calls.append(call)
        let answer = StubServer.handler?(call) ?? (404, "text/plain", Data())
        StubServer.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": answer.1])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.2)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func count(_ method: String, _ suffix: String) -> Int { calls.filter { $0.method == method && $0.path.hasSuffix(suffix) }.count }
    static func last(_ method: String, _ suffix: String) -> Call? { calls.last { $0.method == method && $0.path.hasSuffix(suffix) } }
}

final class SyncEngineTests: XCTestCase {
    var folder: URL!
    var store: LocalStore!
    var engine: SyncEngine!
    var serverCommit = "C1"
    let phoneNote = "eeaee3f2-83de-03d4-0000-01a12862677e"
    /// What the notes feed says after its first two pages: nothing, a newer version of the phone's note, or its deletion.
    var later = ""
    var failDownloads = false
    /// How many folder updates the stub refuses as older than its own list.
    var folderConflicts = 0
    var account: AccountManager!
    var settings = ""

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-sync-\(UUID().uuidString)")
        store = LocalStore(root: folder)
        var state = AccountState()
        state.session = SamsungAccount.Session(authServer: "https://eu-auth2.samsungosp.com", loginID: "user@example.com", userID: "uid", userAuthToken: "master", deviceID: "device", signedInAt: Date())
        state.oauth = SamsungAccount.OAuthToken(accessToken: "oauth", refreshToken: nil, expiresAt: Date().addingTimeInterval(3600), refreshExpiresAt: nil)
        state.cloud = CloudIdentity.Tokens(userToken: "cloud-token", userExpiresAt: Date().addingTimeInterval(3600), deviceToken: nil, deviceID: nil)
        let secrets = FileSecretStore(url: folder.appendingPathComponent("account.json"))
        secrets.save(try JSONEncoder().encode(state))
        let http = HTTPClient(protocolClasses: [StubServer.self])
        account = AccountManager(store: secrets, http: http)
        engine = SyncEngine(account: account, store: store, http: http)
        settings = "<Settings><passcode/><sorting/></Settings>"
        StubServer.calls = []
        serverCommit = "C1"
        later = ""
        failDownloads = false
        folderConflicts = 0
        let folders = try fixture("folder-changes-initial.xml"), download = try fixture("downsync-ink-phone.multipart")
        let note = phoneNote
        StubServer.handler = { [unowned self] call in
            func xml(_ text: String, _ status: Int = 200) -> (Int, String, Data) { (status, "application/xml", Data(text.utf8)) }
            switch (call.method, call.path) {
            case ("GET", let path) where path.hasSuffix("/folder/changes"): return (200, "application/xml", folders)
            case ("GET", let path) where path.hasSuffix("/settings"): return xml(self.settings)
            case ("POST", let path) where path.hasSuffix("/settings"):
                self.settings = String(decoding: call.body, as: UTF8.self)
                return xml("<DefaultView/>")
            case ("GET", let path) where path.hasSuffix("/notes/changes"):
                // The first page lists the phone's note; the page after it ends the feed.
                if call.query.contains(Data(#"{"version":0"#.utf8).base64EncodedString().prefix(12)) {
                    return xml("<NoteChangesView><hasNext>true</hasNext><lastChangePoint>cursor1</lastChangePoint><changes><modelName>UGhvbmU=</modelName><deviceId/><commitId>179167891271018e4fddbae559544</commitId><syncModifiedTime>1</syncModifiedTime><serverModifiedTime>2</serverModifiedTime><isDeleted>false</isDeleted><isLocked>false</isLocked><isEncrypted>false</isEncrypted><serverId>SRVPHONE</serverId><resourceId>\(note)</resourceId></changes></NoteChangesView>")
                }
                if call.query.contains("cursor2"), !self.later.isEmpty {
                    let deleted = self.later == "deleted"
                    let change = "<changes><modelName>UGhvbmU=</modelName><commitId>\(self.later)</commitId><syncModifiedTime>5</syncModifiedTime><serverModifiedTime>6</serverModifiedTime><isDeleted>\(deleted)</isDeleted><isLocked>false</isLocked><isEncrypted>false</isEncrypted><serverId>SRVPHONE</serverId><resourceId>\(note)</resourceId></changes>"
                    return xml("<NoteChangesView><hasNext>false</hasNext><lastChangePoint>cursor3</lastChangePoint>\(change)</NoteChangesView>")
                }
                return xml("<NoteChangesView><hasNext>false</hasNext><lastChangePoint>\(call.query.contains("cursor3") ? "cursor3" : "cursor2")</lastChangePoint></NoteChangesView>")
            case ("POST", let path) where path.hasSuffix("/compareForDownsync"):
                return self.failDownloads ? (500, "text/plain", Data("boom".utf8)) : (200, "multipart/form-data", download)
            case ("PATCH", let path) where path.hasSuffix("/folder"):
                if self.folderConflicts > 0 {
                    self.folderConflicts -= 1
                    return xml("<ErrorResource><status>409</status><code>409</code><message>Request conflict</message></ErrorResource>", 409)
                }
                return xml("<DefaultView><resourceId>folder</resourceId></DefaultView>")
            case ("POST", let path) where path.hasSuffix("/samsungnotes/v1/notes"): return xml("<DefaultView><resourceId>SRVNEW</resourceId><commitId>C1</commitId></DefaultView>", 201)
            case ("POST", let path) where path.hasSuffix("/compareForUpsync"): return xml("<CompareForUpsyncView><bodyText id=\"x\"/><commitId>\(self.serverCommit)</commitId></CompareForUpsyncView>")
            case ("POST", let path) where path.hasSuffix("/update"):
                self.serverCommit = "C\(Int(self.serverCommit.dropFirst())! + 1)"
                return xml("<DefaultView><resourceId>SRVNEW</resourceId><commitId>\(self.serverCommit)</commitId></DefaultView>", 201)
            case ("DELETE", _): return (200, "application/xml", Data())
            case ("GET", let path) where path.hasSuffix("/quota/v3/usage"): return (200, "application/json", Data(#"{"rcode":0,"usage_info":[{"cid":"aWluBInwWH","size":4321}]}"#.utf8))
            default: return (404, "text/plain", Data())
            }
        }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    /// The password of locked notes: checked against the verifier as Samsung's clients make it
    /// (the expected values were worked out with another implementation of PBKDF2).
    func testThePasswordOfLockedNotes() throws {
        let salt = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        let code = Passcode(hash: "16e40a648588561b656488cd8b8b9d5ce85d733ab8a3b51a375869dc740aa54f", salt: salt, time: 5)
        XCTAssertTrue(code.verify("correct horse"))
        XCTAssertFalse(code.verify("correct horsf"))
        XCTAssertFalse(code.verify(""))
        XCTAssertTrue(Passcode(hash: "03714D1854A348D9A0558E6444FD47386E31B11CF15C02294168446A3B6F9454", salt: salt, time: 5).verify("пароль1"), "the password's UTF-8 bytes; the hex in either case")
        let made = try XCTUnwrap(Passcode.make("four", now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(made.salt.count, 64)
        XCTAssertEqual(made.hash.count, 64)
        XCTAssertEqual(made.time, 1_800_000_000_000)
        XCTAssertTrue(made.verify("four"))
        XCTAssertFalse(made.verify("Four"))
        XCTAssertNotEqual(Passcode.make("four")?.salt, made.salt, "every password gets a salt of its own")
        XCTAssertNil(Passcode.make("abc"), "four characters at least")
        // In the service's settings.
        let read = try XCTUnwrap(Passcode(settings: try XMLTree.parse(Data(made.settingsXML.utf8))))
        XCTAssertEqual(read, made)
        XCTAssertNil(Passcode(settings: try XMLTree.parse(Data("<Settings><passcode/><sorting/></Settings>".utf8))))
        XCTAssertNil(Passcode(settings: try XMLTree.parse(Data("<Settings><passcode syncModifiedTime=\"4\">onlyonepart</passcode></Settings>".utf8))))
        XCTAssertEqual(Passcode.owner(userID: "abc123userid"), "a8a4c0dc21bcc0d7bcbe2ea6a3e0dfeacf5e6e140aef8639be3a8cc48085b799")
    }

    func testThePasswordIsTakenFromTheServiceAndOneSetHereIsSent() async throws {
        // None anywhere: nothing is kept and nothing is sent.
        _ = try await engine.sync()
        var kept = await account.passcode
        XCTAssertNil(kept)
        XCTAssertEqual(StubServer.count("POST", "/settings"), 0)
        // Set on another device: this Mac takes it.
        let theirs = try XCTUnwrap(Passcode.make("windows", now: Date(timeIntervalSince1970: 1_800_000_000)))
        settings = theirs.settingsXML
        _ = try await engine.sync()
        kept = await account.passcode
        XCTAssertEqual(kept, theirs)
        XCTAssertEqual(StubServer.count("POST", "/settings"), 0)
        // Changed here, later: it is sent, once.
        let ours = try XCTUnwrap(Passcode.make("from the mac", now: Date(timeIntervalSince1970: 1_800_000_100)))
        await account.setPasscode(ours, unsent: true)
        _ = try await engine.sync()
        XCTAssertEqual(StubServer.count("POST", "/settings"), 1)
        XCTAssertEqual(try Passcode(settings: XMLTree.parse(Data(settings.utf8))), ours)
        var unsent = await account.passcodeUnsent
        XCTAssertFalse(unsent)
        _ = try await engine.sync()
        XCTAssertEqual(StubServer.count("POST", "/settings"), 1)
        // Set here, but a newer one is on the service already: the service's stands.
        let stale = try XCTUnwrap(Passcode.make("too late", now: Date(timeIntervalSince1970: 1_800_000_050)))
        await account.setPasscode(stale, unsent: true)
        _ = try await engine.sync()
        kept = await account.passcode
        unsent = await account.passcodeUnsent
        XCTAssertEqual(kept, ours)
        XCTAssertFalse(unsent)
        XCTAssertEqual(StubServer.count("POST", "/settings"), 1)
    }

    func testLockingANoteMarksItAsTheWindowsClientDoes() async throws {
        _ = try await engine.sync()
        let edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "Secret", body: "hidden")
        let owner = Passcode.owner(userID: "abc123userid")
        try edits.setLocked(id, true, owner: owner)
        var file = try store.noteFile(id)
        XCTAssertEqual(file.note["isLocked"], "True")
        XCTAssertEqual(file.note["ownerId"], owner)
        XCTAssertEqual(file.attributes["documentType"], "5")
        XCTAssertEqual(file.attributes["ownerId"], owner)
        XCTAssertEqual(store.loadLibrary().notes[id]?.isLocked, true)
        XCTAssertNotNil(store.loadLibrary().notes[id]?.pending)
        XCTAssertTrue(NoteHash.verify(tree: file.tree))
        // A locked note as the service hands it down: locked, in lowercase, with no owner on the
        // note itself. Sent back, it names the owner its attributes name.
        file.note.attributes["isLocked"] = "true"
        file.note.attributes["ownerId"] = ""
        let back = try XMLTree.parse(Data(file.uploadDocument(pages: false, body: false).utf8))
        XCTAssertEqual(back["isLocked"], "True")
        XCTAssertEqual(back["ownerId"], owner)
        XCTAssertTrue(SyncEngine.shape(of: file.uploadDocument(pages: true, body: true)).contains("locked True; encrypted False; owner named; format 4000/4000 type 5 mode 0; pages 2; body"))
        file.note.attributes["isLocked"] = "True"
        file.note.attributes["ownerId"] = owner
        // What is sent says so too.
        let sent = file.uploadDocument(pages: false, body: false)
        XCTAssertTrue(sent.contains("isLocked=\"True\"") && sent.contains("ownerId=\"\(owner)\"") && sent.contains("documentType=\"5\""))
        try edits.setLocked(id, false, owner: owner)
        file = try store.noteFile(id)
        XCTAssertEqual(file.note["isLocked"], "False")
        XCTAssertEqual(file.note["ownerId"], "")
        XCTAssertEqual(file.attributes["documentType"], "0")
        XCTAssertEqual(store.loadLibrary().notes[id]?.isLocked, false)
        // The note's text is the same throughout: the lock is the clients' to keep.
        XCTAssertEqual(try store.load(id).document.body.plain, "hidden")
    }

    func testFirstSyncDownloadsAndSecondIsQuiet() async throws {
        let library = try await engine.sync()
        XCTAssertEqual(library.notes.count, 1)
        let record = try XCTUnwrap(library.notes[phoneNote])
        XCTAssertEqual(record.serverID, "SRVPHONE")
        XCTAssertEqual(record.commitID, "179167891271018e4fddbae559544")
        XCTAssertTrue(record.hasInk)
        XCTAssertEqual(library.nodes.count, 17)
        XCTAssertEqual(library.noteCursor, "cursor2")
        XCTAssertEqual(library.cloudBytes, 4321)
        XCTAssertEqual(try store.load(phoneNote).strokes.count, 2)
        let call = try XCTUnwrap(StubServer.last("POST", "/compareForDownsync"))
        XCTAssertEqual(call.headers["Authorization"], "Bearer cloud-token")
        XCTAssertEqual(String(decoding: call.body, as: UTF8.self), #"<noteTree ver="0" />"#)
        XCTAssertEqual(call.headers["x-sn-sdk-ver"], "5500")
        XCTAssertTrue(call.headers["x-sn-transaction-id"]?.hasPrefix("NC-") == true)

        _ = try await engine.sync()
        XCTAssertEqual(StubServer.count("POST", "/compareForDownsync"), 1, "an unchanged note is not downloaded again")
        XCTAssertEqual(StubServer.count("PATCH", "/folder"), 0)
    }

    func testCreateEditTrashDelete() async throws {
        let edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "Plan", body: "one\ntwo")
        XCTAssertTrue(edits.canEditText(id))
        XCTAssertEqual(store.loadLibrary().notes[id]?.pending, .create)
        var library = try await engine.sync()
        XCTAssertEqual(library.notes[id]?.serverID, "SRVNEW")
        XCTAssertNil(library.notes[id]?.pending)
        XCTAssertFalse(library.hasPendingUploads)
        let patch = try XCTUnwrap(StubServer.last("PATCH", "/folder"))
        let node = try XCTUnwrap(XMLTree.parse(patch.body).descendant("node"))
        XCTAssertEqual(node["id"], id)
        // The list is stamped with the moment it is sent, not with when its nodes were last
        // touched: the service refused a list stamped with an edit made hours before (first live sync).
        let listStamp = try XCTUnwrap(XMLTree.parse(patch.body).value("syncModifiedTime").flatMap { Int64($0) })
        XCTAssertEqual(Double(listStamp), Date().timeIntervalSince1970 * 1000, accuracy: 60_000)
        XCTAssertEqual(node.value("name")?.decodedBase64, "Plan")
        XCTAssertEqual(node.value("state"), "normal")
        let created = try XCTUnwrap(StubServer.last("POST", "/samsungnotes/v1/notes"))
        XCTAssertTrue(created.headers["Content-Type"]?.hasPrefix("multipart/form-data;boundary=") == true)
        let sent = try NoteDocument(xml: try XCTUnwrap(Multipart.parse(created.body).first { $0.name == "noteResource" }).body)
        XCTAssertEqual(sent.title.plain, "Plan")
        XCTAssertEqual(sent.body.plain, "one\ntwo")
        XCTAssertEqual(sent.pages.count, 2)

        try edits.saveText(id, title: "Plan", body: "one\ntwo\nthree")
        XCTAssertEqual(store.loadLibrary().notes[id]?.pending, .update)
        library = try await engine.sync()
        XCTAssertEqual(library.notes[id]?.commitID, "C2")
        XCTAssertNil(library.notes[id]?.pending)
        let tree = try XMLTree.parse(try XCTUnwrap(StubServer.last("POST", "/compareForUpsync")).body)
        XCTAssertEqual(tree["ver"], "4000")
        XCTAssertTrue(NoteHash.verify(tree: tree))
        let update = try XMLTree.parse(try XCTUnwrap(Multipart.parse(try XCTUnwrap(StubServer.last("POST", "/update")).body).first).body)
        XCTAssertEqual(update.children.map(\.name), ["noteTree", "attributes", "bodyText"])

        try edits.setTrashed(id, true)
        library = try await engine.sync()
        XCTAssertEqual(try XMLTree.parse(try XCTUnwrap(StubServer.last("PATCH", "/folder")).body).descendant("node")?.value("state"), "trashed")
        XCTAssertEqual(try XMLTree.parse(try XCTUnwrap(StubServer.last("PATCH", "/folder")).body).descendant("node")?.value("restorePath")?.decodedBase64, "uncategorized:///")
        XCTAssertEqual(library.nodes[id]?.state, .trashed)
        XCTAssertEqual(library.notes[id]?.commitID, "C3")

        edits.deleteForever(id)
        library = try await engine.sync()
        XCTAssertEqual(StubServer.count("DELETE", "/SRVNEW"), 1)
        XCTAssertNil(library.notes[id])
        XCTAssertFalse(library.hasPendingUploads)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(id).path))
    }

    func testAnEditIsNotSentOverANewerVersion() async throws {
        let edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "Shared", body: "mine")
        _ = try await engine.sync()
        try edits.saveText(id, title: "Shared", body: "mine, edited")
        serverCommit = "C9"   // another device has saved since
        _ = try? await engine.sync()
        XCTAssertEqual(StubServer.count("POST", "/update"), 0)
        XCTAssertEqual(store.loadLibrary().notes[id]?.pending, .update, "the edit waits for the next round")
    }

    func testHandwritingIsStoredHashedAndSent() async throws {
        let edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "", body: "")
        func line(_ y: Double) -> [InkPoint] { (0..<30).map { InkPoint(x: 100 + Double($0) * 9.5, y: y + Double($0 % 5), pressure: 1, time: $0 * 16) } }
        let size = LocalEdits.standardPenSize(pageWidth: 848)
        let first = try edits.addStrokes(id, page: 0, strokes: [(line(200), 0xFF25_2525, size, nil), (line(300), 0xFFFF_3636, size, nil)])
        XCTAssertEqual(first.count, 2)
        var note = try store.load(id)
        XCTAssertEqual(note.strokes.count, 2)
        XCTAssertEqual(note.strokes[first[1].id]?.argb, 0xFFFF_3636)
        XCTAssertEqual(note.strokes[first[0].id]?.penName, NoteFile.fountainPen)
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(XMLTree.parse(Data(try store.noteFile(id).treeDocument().utf8)))))
        XCTAssertFalse(edits.canEditText(id), "a note with ink is no longer rewritten as plain text")
        XCTAssertEqual(store.loadLibrary().notes[id]?.hasInk, true)

        _ = try await engine.sync()
        let created = Multipart.parse(try XCTUnwrap(StubServer.last("POST", "/samsungnotes/v1/notes")).body)
        XCTAssertEqual(created.filter { $0.name == "strokeResource" }.count, 2)
        let part = try XCTUnwrap(created.first { $0.filename?.hasPrefix(first[0].id) == true })
        XCTAssertEqual(try StrokeDecoder.decode(part.body).points.count, 30)
        let sentDocument = try XMLTree.parse(created[0].body)
        XCTAssertEqual(part.filename, "\(first[0].id)_\(sentDocument.descendants("object").first { $0["id"] == first[0].id && $0["type"] == "stroke" }?["modifiedTime"] ?? "")")
        XCTAssertEqual(sentDocument.descendant("penInfo")?["color"], "-51658")
        XCTAssertNil(store.loadLibrary().notes[id]?.unsentStrokes)

        // One more stroke: only it travels, with the pages.
        let second = try edits.addStrokes(id, page: 0, strokes: [(line(400), 0xFF14_47FF, size, nil)])
        _ = try await engine.sync()
        let update = Multipart.parse(try XCTUnwrap(StubServer.last("POST", "/update")).body)
        XCTAssertEqual(update.filter { $0.name == "strokeResource" }.compactMap { $0.filename?.split(separator: "_").first.map(String.init) }, [second[0].id])
        let updateDocument = try XMLTree.parse(update[0].body)
        XCTAssertTrue(updateDocument.children.map(\.name).contains("pageList"))
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(updateDocument.child("noteTree"))))
        XCTAssertEqual(updateDocument.child("noteTree")?.descendants("object").count, 3)

        try edits.eraseStrokes(id, ids: [first[0].id])
        note = try store.load(id)
        XCTAssertEqual(note.strokes.count, 2)
        _ = try await engine.sync()
        let erased = Multipart.parse(try XCTUnwrap(StubServer.last("POST", "/update")).body)
        XCTAssertTrue(erased.filter { $0.name == "strokeResource" }.isEmpty)
        XCTAssertEqual(try XMLTree.parse(erased[0].body).child("noteTree")?.descendants("object").count, 2)
        XCTAssertFalse(store.loadLibrary().hasPendingUploads)
    }

    /// The service refuses an update when it misses the record of a stroke the pages name
    /// (2026-10-14, field "strokeResource"): the update goes once more with every stroke's record.
    func testARefusedStrokeUploadGoesAgainWithEveryStroke() async throws {
        let edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "", body: "")
        func line(_ y: Double) -> [InkPoint] { (0..<30).map { InkPoint(x: 100 + Double($0) * 9.5, y: y, pressure: 1, time: $0 * 16) } }
        let size = LocalEdits.standardPenSize(pageWidth: 848)
        _ = try edits.addStrokes(id, page: 0, strokes: [(line(200), 0xFF25_2525, size, nil), (line(300), 0xFF25_2525, size, nil)])
        _ = try await engine.sync()
        let more = try edits.addStrokes(id, page: 0, strokes: [(line(400), 0xFF25_2525, size, nil)])
        let previous = try XCTUnwrap(StubServer.handler)
        var updates = 0
        StubServer.handler = { call in
            if call.method == "POST", call.path.hasSuffix("/update") {
                updates += 1
                if updates == 1 {
                    return (400, "application/xml", Data("<ErrorResource><status>400</status><code>128406</code><message>Request payload invalid</message><errors><errors><field>strokeResource</field><value>MultipartOnlyFileNames [], strokeResourceOnlyFileNames [x]</value></errors></errors></ErrorResource>".utf8))
                }
            }
            return previous(call)
        }
        StubServer.calls = []
        _ = try await engine.sync()
        XCTAssertEqual(updates, 2)
        let parts = { (index: Int) in Multipart.parse(StubServer.calls.filter { $0.method == "POST" && $0.path.hasSuffix("/update") }[index].body).filter { $0.name == "strokeResource" } }
        XCTAssertEqual(parts(0).count, 1, "at first only the stroke drawn since")
        XCTAssertEqual(parts(0).first?.filename?.hasPrefix(more[0].id), true)
        XCTAssertEqual(parts(1).count, 3, "then every stroke the pages name")
        XCTAssertNil(store.loadLibrary().notes[id]?.pending)
        XCTAssertNil(store.loadLibrary().notes[id]?.unsentStrokes)
    }

    private func line(_ y: Double) -> [InkPoint] { (0..<20).map { InkPoint(x: 200 + Double($0) * 12, y: y, pressure: 1, time: $0 * 16) } }

    /// Drawn on here, changed on the phone meanwhile: the phone's version comes in and what was
    /// drawn here survives, ink and all, as a note of its own.
    func testAConflictKeepsTheWholeLocalNoteAsACopy() async throws {
        _ = try await engine.sync()
        let edits = LocalEdits(store: store)
        let mine = try edits.addStrokes(phoneNote, page: 0, strokes: [(line(700), 0xFFFF_3636, 7.65, nil)])
        XCTAssertEqual(try store.load(phoneNote).strokes.count, 3)
        later = "NEWERCOMMIT"
        let library = try await engine.sync()
        XCTAssertEqual(library.notes.count, 2)
        let original = try XCTUnwrap(library.notes[phoneNote])
        XCTAssertEqual(original.commitID, "NEWERCOMMIT")
        XCTAssertNil(original.pending)
        XCTAssertEqual(try store.load(phoneNote).strokes.count, 2, "the phone's version replaced the local one")
        let copy = try XCTUnwrap(library.notes.values.first { $0.id != phoneNote })
        XCTAssertTrue(copy.title.hasSuffix("(Mac copy)"))
        XCTAssertEqual(try store.load(copy.id).strokes.count, 3)
        XCTAssertNotNil(try store.load(copy.id).strokes[mine[0].id])
        XCTAssertEqual(copy.serverID, "SRVNEW", "the copy was uploaded in the same round")
        XCTAssertNil(copy.pending)
        let sent = Multipart.parse(try XCTUnwrap(StubServer.last("POST", "/samsungnotes/v1/notes")).body)
        XCTAssertEqual(sent.filter { $0.name == "strokeResource" }.count, 3)
        XCTAssertEqual(try XMLTree.parse(sent[0].body)["id"], copy.id)
        XCTAssertEqual(StubServer.count("POST", "/update"), 0, "nothing was written over the phone's version")
        // The next round has nothing left to do.
        let calls = StubServer.calls.count
        _ = try await engine.sync()
        XCTAssertEqual(StubServer.calls[calls...].filter { $0.method != "GET" }.count, 0)
    }

    func testADeletionElsewhereKeepsUnsentWork() async throws {
        _ = try await engine.sync()
        try LocalEdits(store: store).addStrokes(phoneNote, page: 0, strokes: [(line(700), 0xFF25_2525, 7.65, nil)])
        later = "deleted"
        let library = try await engine.sync()
        XCTAssertNil(library.notes[phoneNote])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(phoneNote).path))
        let copy = try XCTUnwrap(library.notes.values.first)
        XCTAssertEqual(try store.load(copy.id).strokes.count, 3)
        XCTAssertEqual(StubServer.count("DELETE", "/SRVPHONE"), 0)
    }

    func testAFailedDownloadIsRetriedWithoutWalkingTheFeedAgain() async throws {
        failDownloads = true
        do { _ = try await engine.sync(); XCTFail("the sync should report the failure") } catch {}
        var library = store.loadLibrary()
        XCTAssertNil(library.notes[phoneNote])
        XCTAssertEqual(library.noteCursor, "cursor2", "the feed's place is kept all the same")
        XCTAssertEqual(library.failedDownloads?[phoneNote]?.serverID, "SRVPHONE")
        failDownloads = false
        library = try await engine.sync()
        XCTAssertNotNil(library.notes[phoneNote])
        XCTAssertNil(library.failedDownloads?[phoneNote])
        XCTAssertEqual(try store.load(phoneNote).strokes.count, 2)
    }

    /// An edit made while its note's upload is on its way is not counted as sent.
    func testAnEditDuringAnUploadStaysPending() async throws {
        let edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "Racing", body: "one")
        let inner = try XCTUnwrap(StubServer.handler)
        StubServer.handler = { call in
            if call.method == "POST", call.path.hasSuffix("/samsungnotes/v1/notes") { try? edits.saveText(id, title: "Racing", body: "one two") }
            return inner(call)
        }
        var library = try await engine.sync()
        XCTAssertEqual(library.notes[id]?.serverID, "SRVNEW")
        XCTAssertEqual(library.notes[id]?.pending, .update, "the edit made during the upload still waits")
        library = try await engine.sync()
        XCTAssertNil(library.notes[id]?.pending)
        XCTAssertEqual(try NoteDocument(xml: try XCTUnwrap(Multipart.parse(try XCTUnwrap(StubServer.last("POST", "/update")).body).first).body).body.plain, "one two")
    }

    /// The service refuses a folder update stamped older than its own list (seen on the first
    /// live sync): the nodes are stamped anew and sent once more, and the sync goes on.
    func testAFolderUpdateRefusedAsOldIsSentAgainWithANewStamp() async throws {
        _ = try await engine.sync()
        let edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "Later", body: "text", now: Date(timeIntervalSinceNow: -7200))
        let before = try XCTUnwrap(store.loadLibrary().nodes[id]?.syncModifiedTime)
        StubServer.calls = []
        folderConflicts = 1
        let library = try await engine.sync()
        XCTAssertEqual(StubServer.count("PATCH", "/folder"), 2)
        XCTAssertNil(library.notes[id]?.pending)
        XCTAssertFalse(library.hasPendingUploads)
        let second = try XMLTree.parse(try XCTUnwrap(StubServer.last("PATCH", "/folder")).body)
        let sent = try XCTUnwrap(second.descendant("node")?.value("syncModifiedTime").flatMap { Int64($0) })
        XCTAssertGreaterThan(sent, before + 7_000_000)
        XCTAssertEqual(library.nodes[id]?.syncModifiedTime, sent)
        // Refused every time (a round tries before and after the notes, each time twice), it is
        // an error like any other, and the change stays waiting.
        _ = try edits.createTextNote(title: "Again", body: "text")
        folderConflicts = 4
        do { _ = try await engine.sync(); XCTFail("a folder update refused twice is an error") } catch let error as HTTPError { XCTAssertEqual(error.status, 409) }
        XCTAssertTrue(store.loadLibrary().hasPendingUploads)
    }

    func testFoldersAndMoves() async throws {
        let edits = LocalEdits(store: store)
        let folderID = edits.createFolder(name: "Work")
        let note = try edits.createTextNote(title: "In a folder", body: "", parent: folderID)
        let library = try await engine.sync()
        XCTAssertEqual(library.folders(in: TreeNode.rootID).map(\.name), ["Work"])
        XCTAssertEqual(library.nodes[note]?.parentID, folderID)
        let nodes = try XMLTree.parse(try XCTUnwrap(StubServer.last("PATCH", "/folder")).body).descendants("node")
        XCTAssertEqual(Set(nodes.compactMap { $0["type"] }), ["folder", "note"])
        XCTAssertEqual(nodes.first { $0["type"] == "folder" }?.value("color"), "-48845")
    }

    func testPicturesAreUploadedBeforeTheirNote() async throws {
        let edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "Photo", body: "look")
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: UInt8(7), count: 500))
        let hash = NoteFile.sha256(picture)
        let previous = try XCTUnwrap(StubServer.handler)
        var asked: Set<String> = []
        StubServer.handler = { call in
            if call.method == "POST", call.path.hasSuffix("/samsungnotes/v2/binaries/createUploadURLs") {
                let hashes = (try? XMLTree.parse(call.body))?.descendants("hash").map(\.text) ?? []
                let files = hashes.map { "<file><hash>\($0)</hash><url>https://eu1rgn.file.samsungcloud.com/file/v2/tokens/\($0.prefix(8))/signed?signature=s&amp;v=1</url></file>" }.joined()
                return (207, "application/xml", Data("<V2MultipleUploadURLView><created><file>\(files)</file></created><duplicated/><failed/></V2MultipleUploadURLView>".utf8))
            }
            if call.method == "PUT", call.path.hasSuffix("/signed") { return (200, "application/json", Data("{}".utf8)) }
            if call.method == "POST", call.path.hasSuffix("/compareForUpsync") {
                let wanted = asked.map { "<object id=\"\($0)\"/>" }.joined()
                return (200, "application/xml", Data("<CompareForUpsyncView><contentFileList>\(asked.map { "<contentFile id=\"\($0)\"/>" }.joined())</contentFileList><bodyText id=\"x\"/><floatingObjectList>\(wanted)</floatingObjectList><commitId>C1</commitId></CompareForUpsyncView>".utf8))
            }
            return previous(call)
        }
        let object = try XCTUnwrap(try edits.addImage(id, data: picture, fileExtension: "jpg", pixelSize: CGSize(width: 400, height: 300)))
        XCTAssertTrue(store.hasFile(id, hash))
        XCTAssertEqual(store.loadLibrary().notes[id]?.coverFile, hash)
        _ = try await engine.sync()
        let order = StubServer.calls.filter { $0.method == "PUT" || ($0.method == "POST" && !$0.path.hasSuffix("compareForDownsync")) }.map { "\($0.method) \($0.path.split(separator: "/").last ?? "")" }
        XCTAssertEqual(order, ["POST createUploadURLs", "PUT signed", "POST notes"])
        let request = try XCTUnwrap(StubServer.last("POST", "/createUploadURLs"))
        let info = try XCTUnwrap(XMLTree.parse(request.body).descendant("fileInfo"))
        XCTAssertEqual(info.value("hash"), hash)
        XCTAssertEqual(info.value("size"), "504")
        XCTAssertEqual(info.value("contentType"), "application/octet-stream")
        XCTAssertEqual(info.value("validationKey"), NotesAPI.validationKey(fileHash: hash, token: "cloud-token"))
        XCTAssertNil(request.headers["Content-Encoding"])
        let put = try XCTUnwrap(StubServer.last("PUT", "/signed"))
        XCTAssertEqual(put.body, picture)
        XCTAssertEqual(put.headers["Content-Type"], "image/jpeg")
        XCTAssertEqual(put.headers["Range"], "bytes=0-503")
        XCTAssertTrue(put.query.contains("signature=s"))
        let created = try XCTUnwrap(StubServer.last("POST", "/samsungnotes/v1/notes"))
        let document = try XCTUnwrap(Multipart.parse(created.body).first { $0.name == "noteResource" })
        let root = try XMLTree.parse(document.body)
        XCTAssertEqual(root.child("floatingObjectList")?.child("object")?["id"], object)
        XCTAssertEqual(root.child("contentFileList")?.child("contentFile")?["id"], hash)
        XCTAssertNil(store.loadLibrary().notes[id]?.pending)

        // A second picture on a note the service has: only what it asks for goes.
        let other = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: UInt8(9), count: 90))
        let second = try XCTUnwrap(try edits.addImage(id, data: other, fileExtension: "png", pixelSize: CGSize(width: 50, height: 50)))
        asked = [NoteFile.sha256(other), second]
        StubServer.calls = []
        _ = try await engine.sync()
        XCTAssertEqual(StubServer.count("PUT", "/signed"), 1)
        XCTAssertEqual(StubServer.last("PUT", "/signed")?.headers["Content-Type"], "image/png")
        let update = try XCTUnwrap(StubServer.last("POST", "/update"))
        let sent = try XMLTree.parse(try XCTUnwrap(Multipart.parse(update.body).first { $0.name == "noteResource" }).body)
        XCTAssertEqual(sent.child("floatingObjectList")?.all("object").compactMap { $0["id"] }, [second])
        XCTAssertEqual(sent.child("contentFileList")?.all("contentFile").compactMap { $0["id"] }, [NoteFile.sha256(other)])
        XCTAssertEqual(sent.child("noteTree")?.child("floatingObjectList")?.all("object").count, 2)
        XCTAssertNotNil(sent.child("bodyText"))
        XCTAssertEqual(try store.load(id).document.floating.count, 2)
    }

    /// Text typed into a note that another device's version has replaced meanwhile is not
    /// written over that version: it goes into a copy.
    func testTypingIntoAReplacedNoteGoesToACopy() async throws {
        _ = try await engine.sync()
        let edits = LocalEdits(store: store)
        var typed = try XCTUnwrap(edits.richText(phoneNote)).body
        if typed.isEmpty { typed = NoteText.uniform("typed on the Mac", like: nil, body: true) } else { typed.replace(typed.length..<typed.length, with: " typed on the Mac") }
        // A note made here and sent gets its first commit from the service: that is our own
        // upload, and no reason for a copy when the editor saves again.
        let mine = try edits.createTextNote(title: "Mine", body: "one")
        _ = try await engine.sync()
        XCTAssertEqual(store.loadLibrary().notes[mine]?.commitID, "C1")
        var own = try XCTUnwrap(edits.richText(mine)).body
        own.replace(own.length..<own.length, with: " two")
        XCTAssertNil(try edits.saveRich(mine, title: nil, body: own, typedInto: store.arrivals(mine)))
        XCTAssertEqual(try XCTUnwrap(edits.richText(mine)).body.string, "one two")

        // Another device's version arrives; the editor still holds text typed into the old one.
        let base = store.arrivals(phoneNote)
        XCTAssertEqual(base, 1)
        later = "179167891271018e4fddbae559599"
        _ = try await engine.sync()
        XCTAssertEqual(store.loadLibrary().notes[phoneNote]?.commitID, later)
        let before = store.loadLibrary().notes.count
        var more = typed
        more.replace(more.length..<more.length, with: " and more")
        // A change made here in between (a favourite, say) does not hide that the note was replaced.
        try edits.setFavorite(phoneNote, true)
        let copy = try XCTUnwrap(try edits.saveRich(phoneNote, title: nil, body: more, typedInto: base))
        let library = store.loadLibrary()
        XCTAssertEqual(library.notes.count, before + 1)
        XCTAssertFalse(try XCTUnwrap(edits.richText(phoneNote)).body.string.contains("typed on the Mac"), "the newer version's text is left as it came")
        XCTAssertEqual(library.notes[copy]?.pending, .create)
        XCTAssertTrue(library.notes[copy]?.title.hasSuffix("(Mac copy)") == true)
        XCTAssertTrue(try XCTUnwrap(edits.richText(copy)).body.string.hasSuffix("typed on the Mac and more"))
        XCTAssertFalse(try XCTUnwrap(edits.richText(phoneNote)).body.string.contains("and more"))
        XCTAssertEqual(try store.load(copy).strokes.count, 2, "the copy has the note's handwriting too")
    }

    /// A picture added here whose bytes are gone, or that the service gives no place for,
    /// holds its note back: a note must not go out naming a file the service never got.
    func testANoteDoesNotGoWithoutItsPicture() async throws {
        let edits = LocalEdits(store: store)
        let previous = try XCTUnwrap(StubServer.handler)
        var answer = "<V2MultipleUploadURLView><created/><duplicated/><failed/></V2MultipleUploadURLView>"
        StubServer.handler = { call in
            if call.method == "POST", call.path.hasSuffix("/createUploadURLs") { return (207, "application/xml", Data(answer.utf8)) }
            return previous(call)
        }
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: UInt8(3), count: 64))
        let hash = NoteFile.sha256(picture)
        let id = try edits.createTextNote(title: "Photo", body: "look")
        _ = try edits.addImage(id, data: picture, fileExtension: "jpg", pixelSize: CGSize(width: 40, height: 30))
        // The service names the file in neither list.
        do { _ = try await engine.sync(); XCTFail("the sync should report the picture") } catch {}
        XCTAssertEqual(StubServer.count("POST", "/samsungnotes/v1/notes"), 0)
        XCTAssertEqual(store.loadLibrary().notes[id]?.pending, .create)
        // The bytes are gone from this Mac.
        try FileManager.default.removeItem(at: store.mediaURL(id, hash))
        do { _ = try await engine.sync(); XCTFail("the sync should report the picture") } catch {}
        XCTAssertEqual(StubServer.count("POST", "/samsungnotes/v1/notes"), 0)
        // The service holds the file already: nothing to put, and the note goes.
        store.writeFile(id, hash, picture)
        answer = "<V2MultipleUploadURLView><created/><duplicated><file><hash>\(hash)</hash></file></duplicated><failed/></V2MultipleUploadURLView>"
        _ = try await engine.sync()
        XCTAssertEqual(StubServer.count("PUT", "/signed"), 0)
        XCTAssertEqual(StubServer.count("POST", "/samsungnotes/v1/notes"), 1)
        XCTAssertNil(store.loadLibrary().notes[id]?.pending)
        XCTAssertNil(store.loadLibrary().notes[id]?.unsentFiles)
    }

    /// A note waiting on the retry list whose version is here already, with edits made since:
    /// trying again fetches its files, it does not take the note anew and call the edits a conflict.
    func testRetryingADownloadDoesNotUndoEditsMadeSince() async throws {
        _ = try await engine.sync()
        let edits = LocalEdits(store: store)
        let commit = try XCTUnwrap(store.loadLibrary().notes[phoneNote]?.commitID)
        store.update { $0.failedDownloads = [self.phoneNote: Library.FailedDownload(serverID: "SRVPHONE", attempts: 1)] }
        try edits.setFavorite(phoneNote, true)
        let arrivals = store.arrivals(phoneNote)
        // The stub's compare answers with a commit of its own, so the upload is held back; that is not what is looked at here.
        _ = try? await engine.sync()
        let library = store.loadLibrary()
        XCTAssertEqual(library.notes.count, 1, "no copy was made")
        XCTAssertEqual(library.notes[phoneNote]?.isFavorite, true, "the edit is still there")
        XCTAssertEqual(library.notes[phoneNote]?.commitID, commit)
        XCTAssertEqual(store.arrivals(phoneNote), arrivals, "the note was not taken again")
        XCTAssertNil(library.failedDownloads?[phoneNote])
    }

    /// Signing out: notes the cloud has leave this Mac, notes it never got stay, changes it
    /// never got become notes of their own. Signing in again sends what stayed.
    func testSigningOutKeepsWhatWasNeverSent() async throws {
        let edits = LocalEdits(store: store)
        // One note that reaches the cloud, and the phone's note comes down.
        let sent = try edits.createTextNote(title: "Sent", body: "already in the cloud")
        _ = try await engine.sync()
        XCTAssertFalse(try XCTUnwrap(store.loadLibrary().notes[sent]).serverID.isEmpty)
        // Then work done on this Mac without an account to send it to.
        let local = try edits.createTextNote(title: "Only here", body: "never sent")
        let folder = edits.createFolder(name: "Mine")
        let inFolder = try edits.createTextNote(title: "In my folder", body: "also never sent", parent: folder)
        try edits.setFavorite(phoneNote, true)
        let phoneDirectory = store.directory(phoneNote), sentDirectory = store.directory(sent)
        let summary = store.loadLibrary().signOutSummary
        XCTAssertEqual(summary.staysHere, 2)
        XCTAssertEqual(summary.copied, 1)
        XCTAssertEqual(summary.goes, 1)

        try edits.detachFromAccount()

        let library = store.loadLibrary()
        XCTAssertNil(library.notes[sent])
        XCTAssertNil(library.notes[phoneNote])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneDirectory.path))
        let copy = try XCTUnwrap(library.notes.values.first { $0.title.hasSuffix("(Mac copy)") })
        XCTAssertTrue(copy.serverID.isEmpty)
        XCTAssertEqual(copy.pending, .create)
        XCTAssertEqual(try store.load(copy.id).strokes.count, 2, "the copy has the note's handwriting")
        XCTAssertEqual(library.notes.count, 3)
        for id in [local, inFolder, copy.id] {
            let note = try XCTUnwrap(library.notes[id])
            XCTAssertEqual(note.pending, .create)
            XCTAssertNil(note.nodeSent)
            XCTAssertTrue(library.dirtyNodes?.contains(id) == true)
            let parent = try XCTUnwrap(library.nodes[id]?.parentID)
            XCTAssertTrue(parent == TreeNode.rootID || library.nodes[parent]?.kind == .folder, "every note that stays has a place to stand")
        }
        XCTAssertEqual(library.nodes[inFolder]?.parentID, folder)
        XCTAssertEqual(library.nodes[folder]?.kind, .folder)
        XCTAssertNil(library.folderCursor)
        XCTAssertNil(library.noteCursor)
        XCTAssertNil(library.lastSync)
        XCTAssertNil(library.pendingDeletes)
        XCTAssertFalse(library.nodes.values.contains { $0.kind == .note && library.notes[$0.id] == nil }, "no note without a note")

        // Signing in again: what stayed is created, what was removed comes back from the feed.
        StubServer.calls = []
        let after = try await engine.sync()
        XCTAssertEqual(StubServer.count("POST", "/samsungnotes/v1/notes"), 3)
        XCTAssertFalse(after.hasPendingUploads)
        XCTAssertEqual(after.notes[phoneNote]?.serverID, "SRVPHONE")
        XCTAssertEqual(after.notes[phoneNote]?.isFavorite, false, "the copy kept the change; the cloud's note is as it was")
        let patched = try XMLTree.parse(try XCTUnwrap(StubServer.calls.first { $0.method == "PATCH" && $0.path.hasSuffix("/folder") }).body)
        XCTAssertTrue(patched.descendants("node").contains { $0["id"] == folder })
    }
}
