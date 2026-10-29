import XCTest
@testable import SamsungNotesKit

/// A cloud that keeps named files and its history, as CloudKit's zone does, in memory.
final class FakeCloud: CloudFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var history: [(name: String, deleted: Bool)] = []
    private let scratch: URL
    /// Histories shorter than this are "too old to continue from".
    var expiredBefore = 0
    var saves = 0
    var deletes = 0

    init(scratch: URL) { self.scratch = scratch; try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true) }

    var names: [String] { lock.lock(); defer { lock.unlock() }; return files.keys.sorted() }
    func data(_ name: String) -> Data? { lock.lock(); defer { lock.unlock() }; return files[name] }

    private func hand(_ name: String, _ data: Data) -> CloudFile {
        let url = scratch.appendingPathComponent(UUID().uuidString)
        try? data.write(to: url)
        return CloudFile(name: name, url: url, isTemporary: true)
    }

    func changes(since token: Data?) async throws -> CloudChanges {
        lock.lock(); defer { lock.unlock() }
        var out = CloudChanges()
        let at = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        if let at, at >= expiredBefore {
            var seen = Set<String>()
            for entry in history[min(at, history.count)...].reversed() where seen.insert(entry.name).inserted {
                if let data = files[entry.name], !entry.deleted { out.changed.append(hand(entry.name, data)) } else if files[entry.name] == nil { out.deleted.append(entry.name) }
            }
        } else {
            out.isEverything = true
            out.changed = files.map { hand($0.key, $0.value) }
        }
        out.token = Data(String(history.count).utf8)
        return out
    }

    func save(_ sent: [CloudFile]) async throws {
        lock.lock(); defer { lock.unlock() }
        for file in sent {
            files[file.name] = try Data(contentsOf: file.url)
            history.append((file.name, false))
            saves += 1
        }
    }

    func delete(_ names: [String]) async throws {
        lock.lock(); defer { lock.unlock() }
        for name in names {
            files[name] = nil
            history.append((name, true))
            deletes += 1
        }
    }
}

/// Two Macs and a cloud database between them.
final class CloudMirrorTests: XCTestCase {
    private var root: URL!
    private var cloud: FakeCloud!
    private var storeA: LocalStore!
    private var storeB: LocalStore!
    private var editsA: LocalEdits!
    private var editsB: LocalEdits!
    private var a: CloudMirror!
    private var b: CloudMirror!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-cloud-\(UUID().uuidString)")
        cloud = FakeCloud(scratch: root.appendingPathComponent("scratch"))
        storeA = LocalStore(root: root.appendingPathComponent("a"))
        storeB = LocalStore(root: root.appendingPathComponent("b"))
        editsA = LocalEdits(store: storeA)
        editsB = LocalEdits(store: storeB)
        a = CloudMirror(store: storeA, cloud: cloud, folder: root.appendingPathComponent("a/cloud"))
        b = CloudMirror(store: storeB, cloud: cloud, folder: root.appendingPathComponent("b/cloud"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func text(_ store: LocalStore, _ id: String) throws -> String { try store.load(id).document.body.plain }
    private func type(_ edits: LocalEdits, _ id: String, _ more: String) throws {
        var body = try XCTUnwrap(edits.richText(id)).body
        body.replace(body.length..<body.length, with: more)
        try edits.saveRich(id, title: nil, body: body)
    }

    func testNotesTravelThroughTheCloud() async throws {
        let id = try editsA.createTextNote(title: "Trip", body: "Pack bags")
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7])
        _ = try editsA.addImage(id, data: picture, fileExtension: "jpg", pixelSize: CGSize(width: 30, height: 20))
        var out = try await a.sync()
        XCTAssertEqual(out.uploaded, 1)
        XCTAssertTrue(cloud.names.contains { $0.hasPrefix("notes/\(id)/") && $0.hasSuffix(".snote") })
        XCTAssertTrue(cloud.names.contains("notes/\(id)/\(NoteFile.sha256(picture))"))
        XCTAssertTrue(cloud.names.contains { $0.hasPrefix("tree/") })
        let sent = cloud.saves
        out = try await a.sync()
        XCTAssertEqual(out, FolderSync.Outcome())
        XCTAssertEqual(cloud.saves, sent, "a second round sends nothing")

        out = try await b.sync()
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertEqual(storeB.loadLibrary().notes[id]?.title, "Trip")
        XCTAssertTrue(storeB.hasFile(id, NoteFile.sha256(picture)))
        XCTAssertEqual(cloud.saves, sent, "taking a note sends nothing")

        // Changed on B: the new version goes up, the old one comes out of the cloud, and A takes it.
        try type(editsB, id, "\nBook tickets")
        _ = try await b.sync()
        XCTAssertEqual(cloud.names.filter { $0.hasPrefix("notes/\(id)/") && $0.hasSuffix(".snote") }.count, 1)
        XCTAssertGreaterThan(cloud.deletes, 0)
        out = try await a.sync()
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertTrue(try text(storeA, id).contains("Book tickets"))
        let quietA = try await a.sync(), quietB = try await b.sync()
        XCTAssertEqual(quietA, FolderSync.Outcome())
        XCTAssertEqual(quietB, FolderSync.Outcome())
    }

    func testConflictsAndDeletionsHoldAsInAFolder() async throws {
        let id = try editsA.createTextNote(title: "Plan", body: "start")
        let gone = try editsA.createTextNote(title: "Gone", body: "soon")
        _ = try await a.sync()
        _ = try await b.sync()
        try type(editsA, id, "\nfrom A")
        try type(editsB, id, "\nfrom B")
        editsA.deleteForever(gone)
        _ = try await a.sync()
        var out = try await b.sync()
        XCTAssertEqual(out.conflicts.map(\.id), [id])
        XCTAssertEqual(out.removed, 1)
        XCTAssertNil(storeB.loadLibrary().notes[gone])
        XCTAssertTrue(try text(storeB, id).contains("from B"))
        out = try await b.sync(resolve: [id: .keepMine])
        XCTAssertTrue(out.conflicts.isEmpty)
        out = try await a.sync()
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertTrue(try text(storeA, id).contains("from B"))
        XCTAssertFalse(cloud.names.contains { $0.hasPrefix("notes/\(gone)/") })
    }

    /// A Mac whose place in the cloud's history is too old is given everything anew, and
    /// drops from its copy what the cloud no longer has.
    func testAnExpiredPlaceInTheHistory() async throws {
        let id = try editsA.createTextNote(title: "One", body: "first")
        _ = try await a.sync()
        _ = try await b.sync()
        try type(editsA, id, "\nsecond")
        _ = try await a.sync()
        cloud.expiredBefore = 1_000_000
        let out = try await b.sync()
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertTrue(try text(storeB, id).contains("second"))
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("b/cloud/notes/\(id)").path))?.filter { $0.hasSuffix(".snote") } ?? []
        XCTAssertEqual(copies.count, 1, "the version the cloud no longer has is gone from the copy")
        cloud.expiredBefore = 0
        let quiet = try await b.sync()
        XCTAssertEqual(quiet, FolderSync.Outcome())
    }

    func testLockedNotesAreSealedInTheCloud() async throws {
        let secret = try editsA.createTextNote(title: "Secret plan", body: "the hidden words")
        try editsA.setLocked(secret, true, owner: "")
        let vault = Vault()
        try a.folderSync().writeLockedVault(Vault.Locked(keyOnly: vault))
        _ = try await a.sync { $0.vault = vault; $0.seals = true }
        for name in cloud.names {
            let data = try XCTUnwrap(cloud.data(name))
            XCTAssertNil(data.range(of: Data("hidden words".utf8)), name)
            XCTAssertNil(data.range(of: Data("Secret plan".utf8)), name)
        }
        XCTAssertTrue(cloud.names.contains("vault.json"))
        // The other Mac: without the key it waits; with it (from the keychain iCloud keeps) it reads.
        var out = try await b.sync()
        XCTAssertEqual(out.sealedWithoutKey, 1)
        let locked = try XCTUnwrap(b.folderSync().lockedVault())
        XCTAssertFalse(locked.hasPassword)
        XCTAssertEqual(locked.keyID, vault.keyID)
        out = try await b.sync { $0.vault = Vault(stored: vault.stored); $0.seals = locked.active }
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertTrue(try text(storeB, secret).contains("the hidden words"))
    }
}
