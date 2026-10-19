import XCTest
@testable import SamsungNotesKit

/// Two Macs and the folder a service keeps the same on both: each test plays both Macs.
final class FolderSyncTests: XCTestCase {
    private var root: URL!
    private var shared: URL!
    private var storeA: LocalStore!
    private var storeB: LocalStore!
    private var editsA: LocalEdits!
    private var editsB: LocalEdits!
    private var a: FolderSync!
    private var b: FolderSync!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-folder-\(UUID().uuidString)")
        shared = root.appendingPathComponent("cloud/SNotes")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cloud"), withIntermediateDirectories: true)
        storeA = LocalStore(root: root.appendingPathComponent("a"))
        storeB = LocalStore(root: root.appendingPathComponent("b"))
        editsA = LocalEdits(store: storeA)
        editsB = LocalEdits(store: storeB)
        a = FolderSync(store: storeA, folder: shared, deviceName: "Mac A")
        b = FolderSync(store: storeB, folder: shared, deviceName: "Mac B")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func text(_ store: LocalStore, _ id: String) throws -> String { try store.load(id).document.body.plain }
    private func versions(_ id: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: shared.appendingPathComponent("notes/\(id)").path)) ?? []).filter { $0.hasSuffix(".snote") }.sorted()
    }
    private func type(_ edits: LocalEdits, _ id: String, _ more: String) throws {
        var body = try XCTUnwrap(edits.richText(id)).body
        body.replace(body.length..<body.length, with: more)
        try edits.saveRich(id, title: nil, body: body)
    }

    func testANoteGoesFromOneMacToTheOtherAndBack() throws {
        let id = try editsA.createTextNote(title: "Trip", body: "Pack bags")
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 9, 8, 7])
        _ = try editsA.addImage(id, data: picture, fileExtension: "jpg", pixelSize: CGSize(width: 300, height: 200))
        _ = try editsA.addStrokes(id, page: 0, strokes: [NewStroke(points: (0..<8).map { InkPoint(x: 100 + Double($0) * 9, y: 300, pressure: 1, time: $0 * 8) }, argb: 0xFF14_47FF, penSize: 6, pen: .fountain)])
        var out = try a.sync()
        XCTAssertEqual(out.uploaded, 1)
        XCTAssertEqual(versions(id).count, 1)
        XCTAssertEqual(try a.sync(), FolderSync.Outcome(), "a second round has nothing to do")

        out = try b.sync()
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertEqual(storeB.loadLibrary().notes[id]?.title, "Trip")
        XCTAssertEqual(try text(storeB, id).replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines), "Pack bags")
        let there = try storeB.load(id)
        XCTAssertEqual(there.strokes.count, 1)
        XCTAssertEqual(there.document.floating.count, 1)
        XCTAssertTrue(storeB.hasFile(id, NoteFile.sha256(picture)))
        XCTAssertEqual(storeB.fingerprint(id), storeA.fingerprint(id), "the same note on both Macs")
        XCTAssertEqual(storeB.loadLibrary().nodes[id]?.state, .normal)
        XCTAssertEqual(try b.sync(), FolderSync.Outcome())

        // Changed on B: A takes it, and the folder holds one version again.
        try type(editsB, id, "\nBook tickets")
        XCTAssertEqual(try b.sync().uploaded, 1)
        XCTAssertEqual(versions(id).count, 1)
        XCTAssertEqual(try a.sync().downloaded, 1)
        XCTAssertTrue(try text(storeA, id).contains("Book tickets"))
        XCTAssertEqual(try a.sync(), FolderSync.Outcome())
        XCTAssertEqual(try b.sync(), FolderSync.Outcome())
        // The attached picture was written to the folder once.
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("notes/\(id)/\(NoteFile.sha256(picture))").path))
    }

    func testFoldersTrashAndDeletionFollow() throws {
        let folder = editsA.createFolder(name: "Work")
        let kept = try editsA.createTextNote(title: "Kept", body: "one", parent: folder)
        let gone = try editsA.createTextNote(title: "Gone", body: "two")
        _ = try a.sync()
        _ = try b.sync()
        XCTAssertEqual(storeB.loadLibrary().nodes[folder]?.name, "Work")
        XCTAssertEqual(storeB.loadLibrary().nodes[kept]?.parentID, folder)

        // Renamed and trashed on B; deleted for good on A.
        editsB.renameFolder(folder, to: "Office", now: Date().addingTimeInterval(5))
        try editsB.setTrashed(kept, true, now: Date().addingTimeInterval(5))
        editsA.deleteForever(gone)
        XCTAssertNil(storeA.loadLibrary().notes[gone])
        var out = try a.sync()
        XCTAssertEqual(out.removed, 1)
        XCTAssertTrue(versions(gone).isEmpty)
        out = try b.sync()
        XCTAssertEqual(out.removed, 1, "deleted on A, it goes on B")
        XCTAssertNil(storeB.loadLibrary().notes[gone])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeB.directory(gone).appendingPathComponent("note.xml").path))
        _ = try a.sync()
        XCTAssertEqual(storeA.loadLibrary().nodes[folder]?.name, "Office")
        XCTAssertEqual(storeA.loadLibrary().state(of: kept), .trashed)
        XCTAssertEqual(try a.sync(), FolderSync.Outcome())
        XCTAssertEqual(try b.sync(), FolderSync.Outcome())
        // It does not come back.
        XCTAssertNil(storeA.loadLibrary().notes[gone])
        XCTAssertNil(storeB.loadLibrary().notes[gone])
    }

    /// A note that is merely gone from a Mac (taken off it, lost) is not deleted for everyone: it comes back.
    func testANoteThatOnlyWentMissingHereIsNotDeletedThere() throws {
        let id = try editsA.createTextNote(title: "Precious", body: "keep me")
        _ = try a.sync()
        _ = try b.sync()
        storeB.update { $0.notes[id] = nil }
        storeB.remove(id)
        let out = try b.sync()
        XCTAssertEqual(out.removed, 0)
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertEqual(versions(id).count, 1)
        XCTAssertEqual(try a.sync(), FolderSync.Outcome())
        XCTAssertNotNil(storeA.loadLibrary().notes[id])
        // Taking the folder's notes off a Mac keeps what was changed there and never synced.
        let mine = try editsB.createTextNote(title: "Only here", body: "local")
        try type(editsB, id, " and changed")
        XCTAssertEqual(FolderSync.removable(in: storeB), 0)
        _ = try b.sync()
        XCTAssertEqual(FolderSync.removable(in: storeB), 2)
        try type(editsB, mine, " more")
        FolderSync.detach(from: storeB)
        XCTAssertEqual(Set(storeB.loadLibrary().notes.keys), [mine])
        XCTAssertEqual(versions(id).count, 1, "the folder keeps its notes")
        XCTAssertNil(storeB.loadLibrary().folderLinks)
    }

    func testANoteChangedOnBothMacsWaitsToBeDecided() throws {
        let id = try editsA.createTextNote(title: "Plan", body: "start")
        _ = try a.sync()
        _ = try b.sync()
        try type(editsA, id, "\nfrom A")
        try type(editsB, id, "\nfrom B")
        XCTAssertEqual(try a.sync().uploaded, 1)
        var out = try b.sync()
        XCTAssertEqual(out.conflicts.map(\.id), [id])
        XCTAssertEqual(out.conflicts.first?.deviceThere, "Mac A")
        XCTAssertEqual(out.downloaded + out.uploaded, 0, "neither side is touched")
        XCTAssertTrue(try text(storeB, id).contains("from B"))
        XCTAssertEqual(try b.sync().conflicts.count, 1, "and it waits, round after round")
        XCTAssertEqual(try a.sync(), FolderSync.Outcome(), "the other Mac has nothing to decide")

        // Kept both: B's version becomes a note of its own, and the note is A's.
        out = try b.sync(resolve: [id: .keepBoth])
        XCTAssertTrue(out.conflicts.isEmpty)
        XCTAssertTrue(try text(storeB, id).contains("from A"))
        let copies = storeB.loadLibrary().notes.values.filter { $0.id != id }
        XCTAssertEqual(copies.count, 1)
        XCTAssertTrue(try text(storeB, try XCTUnwrap(copies.first?.id)).contains("from B"))
        XCTAssertEqual(try b.sync().uploaded, 1, "the copy is a new note for the folder")
        XCTAssertEqual(try a.sync().downloaded, 1)
        XCTAssertEqual(storeA.loadLibrary().notes.count, 2)

        // Once more, and this time this Mac's is kept.
        try type(editsA, id, "\nA again")
        try type(editsB, id, "\nB again")
        _ = try a.sync()
        XCTAssertEqual(try b.sync().conflicts.count, 1)
        out = try b.sync(resolve: [id: .keepMine])
        XCTAssertEqual(out.uploaded, 1)
        XCTAssertEqual(versions(id).count, 1)
        XCTAssertEqual(try a.sync().downloaded, 1)
        XCTAssertTrue(try text(storeA, id).contains("B again"))
        XCTAssertFalse(try text(storeA, id).contains("A again"))
        // And theirs.
        try type(editsA, id, "\nA third")
        try type(editsB, id, "\nB third")
        _ = try a.sync()
        out = try b.sync(resolve: [id: .keepTheirs])
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertTrue(try text(storeB, id).contains("A third"))
        XCTAssertEqual(storeB.loadLibrary().notes.count, 2, "no copy is made")
        XCTAssertEqual(try a.sync(), FolderSync.Outcome())
        XCTAssertEqual(try b.sync(), FolderSync.Outcome())
    }

    func testTwoMacsThatAlreadyHoldTheSameNoteOnlyAgree() throws {
        // Both have the note from elsewhere (Samsung's service, say), byte for byte.
        let id = try editsA.createTextNote(title: "Same", body: "on both")
        let file = try storeA.noteFile(id)
        try storeB.write(file)
        storeB.update { $0.notes[id] = self.storeA.loadLibrary().notes[id]; $0.nodes[id] = self.storeA.loadLibrary().nodes[id] }
        XCTAssertEqual(try a.sync().uploaded, 1)
        let out = try b.sync()
        XCTAssertEqual(out, FolderSync.Outcome(), "nothing to move, nothing to decide")
        XCTAssertNotNil(storeB.loadLibrary().folderLinks?[id])
        // A note of the same id that differs is a conflict, not a silent overwrite.
        let other = try editsA.createTextNote(title: "Differs", body: "A's")
        let copy = try storeA.noteFile(other)
        try storeB.write(copy)
        storeB.update { $0.notes[other] = self.storeA.loadLibrary().notes[other]; $0.nodes[other] = self.storeA.loadLibrary().nodes[other] }
        try type(editsB, other, " and B's")
        _ = try a.sync()
        XCTAssertEqual(try b.sync().conflicts.map(\.id), [other])
    }

    func testAVersionThatCannotBeReadYetKeepsTheNoteWaiting() throws {
        let id = try editsA.createTextNote(title: "Slow", body: "first")
        _ = try a.sync()
        _ = try b.sync()
        try type(editsA, id, "\nsecond")
        _ = try a.sync()
        // The service has listed A's new version on B, and not brought it: it cannot be read there.
        let version = shared.appendingPathComponent("notes/\(id)/\(try XCTUnwrap(versions(id).first))")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: version.path)
        var out = try b.sync()
        XCTAssertEqual(out.notHereYet, 1)
        XCTAssertEqual(out.uploaded + out.downloaded + out.conflicts.count, 0, "nothing is done about a note that is not all there")
        XCTAssertEqual(versions(id).count, 1, "B did not write its older copy beside it")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: version.path)
        out = try b.sync()
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertTrue(try text(storeB, id).contains("second"))

        // A version only half written is waited for as well, while it is fresh.
        try type(editsA, id, "\nthird")
        _ = try a.sync()
        let whole = shared.appendingPathComponent("notes/\(id)/\(try XCTUnwrap(versions(id).first))")
        let data = try Data(contentsOf: whole)
        try data.prefix(9).write(to: whole)
        out = try b.sync()
        XCTAssertEqual(out.notHereYet, 1)
        XCTAssertEqual(versions(id).count, 1)
        try data.write(to: whole)
        XCTAssertEqual(try b.sync().downloaded, 1)
        XCTAssertTrue(try text(storeB, id).contains("third"))
    }

    func testTheSameNoteWrittenTwiceIsOne() throws {
        let id = try editsA.createTextNote(title: "Same", body: "on both")
        try storeB.write(try storeA.noteFile(id))
        storeB.update { $0.notes[id] = self.storeA.loadLibrary().notes[id]; $0.nodes[id] = self.storeA.loadLibrary().nodes[id] }
        _ = try a.sync()
        // B writes its own before the service has shown it A's.
        let home = shared.appendingPathComponent("notes/\(id)"), aside = root.appendingPathComponent("aside.snote")
        let first = try XCTUnwrap(versions(id).first)
        try FileManager.default.moveItem(at: home.appendingPathComponent(first), to: aside)
        XCTAssertEqual(try b.sync().uploaded, 1)
        try FileManager.default.moveItem(at: aside, to: home.appendingPathComponent(first))
        XCTAssertEqual(versions(id).count, 2)
        let out = try a.sync()
        XCTAssertEqual(out, FolderSync.Outcome(), "two files that say the same are not two versions")
        XCTAssertEqual(versions(id).count, 1)
        XCTAssertEqual(try b.sync(), FolderSync.Outcome())
        XCTAssertEqual(storeA.loadLibrary().folderLinks?[id]?.version, storeB.loadLibrary().folderLinks?[id]?.version)
    }

    func testAnotherFolderStartsWithoutTheMemoryOfTheLast() throws {
        let id = try editsA.createTextNote(title: "Moves", body: "A's")
        _ = try a.sync()
        // A library from before folders had names was synced with iCloud Drive.
        FolderSync.settle(in: storeA, home: "icloud")
        XCTAssertNotNil(storeA.loadLibrary().folderLinks?[id])
        // Another folder already holds a note of this id that says something else.
        let elsewhere = root.appendingPathComponent("cloud/Other")
        try storeB.write(try storeA.noteFile(id))
        storeB.update { $0.notes[id] = self.storeA.loadLibrary().notes[id]; $0.nodes[id] = self.storeA.loadLibrary().nodes[id] }
        try type(editsB, id, " and B's")
        _ = try FolderSync(store: storeB, folder: elsewhere, deviceName: "Mac B").sync()
        FolderSync.settle(in: storeA, home: "google:user@example.com")
        XCTAssertNil(storeA.loadLibrary().folderLinks)
        XCTAssertEqual(storeA.loadLibrary().folderHome, "google:user@example.com")
        let moved = FolderSync(store: storeA, folder: elsewhere, deviceName: "Mac A")
        XCTAssertEqual(try moved.sync().conflicts.map(\.id), [id], "asked about, not overwritten")
        XCTAssertEqual(try text(storeA, id), "A's")
        // The same folder again keeps what was agreed.
        _ = try moved.sync(resolve: [id: .keepTheirs])
        FolderSync.settle(in: storeA, home: "google:user@example.com")
        XCTAssertNotNil(storeA.loadLibrary().folderLinks?[id])
    }

    func testLockedNotesAreSealedAndOpenOnlyWithTheKey() throws {
        let open = try editsA.createTextNote(title: "Groceries", body: "milk")
        let secret = try editsA.createTextNote(title: "Secret plan", body: "the hidden words")
        let picture = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
        _ = try editsA.addImage(secret, data: picture, fileExtension: "png", pixelSize: CGSize(width: 10, height: 10))
        try editsA.setLocked(secret, true, owner: "")
        let vault = Vault()
        a.vault = vault
        a.seals = true
        try a.writeLockedVault(try vault.locked(with: "correct horse", rounds: 1000))
        XCTAssertEqual(try a.sync().uploaded, 2)

        // Nothing of the locked note can be read in the folder: not its text, its title or its picture.
        func everything(under url: URL) -> Data {
            var all = Data()
            for case let file as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) ?? FileManager.default.enumerator(atPath: "/dev/null")! {
                if let data = try? Data(contentsOf: file) { all.append(data) }
            }
            return all
        }
        let folder = everything(under: shared)
        XCTAssertNil(folder.range(of: Data("Secret plan".utf8)))
        XCTAssertNil(folder.range(of: Data("hidden words".utf8)))
        XCTAssertNil(folder.range(of: picture))
        XCTAssertNotNil(folder.range(of: Data("Groceries".utf8)), "a note that is not locked is not sealed")
        let version = try XCTUnwrap(versions(secret).first)
        let sealed = try Data(contentsOf: shared.appendingPathComponent("notes/\(secret)/\(version)"))
        XCTAssertNil(try? Zip.read(sealed.suffix(from: sealed.count / 2)))

        // A Mac without the key gets the open note and waits for the other.
        var out = try b.sync()
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertEqual(out.sealedWithoutKey, 1)
        XCTAssertNil(storeB.loadLibrary().notes[secret])
        // The key is had with the password, from the copy of it in the folder.
        let locked = try XCTUnwrap(b.lockedVault())
        XCTAssertThrowsError(try Vault(locked, password: "wrong horse"))
        b.vault = try Vault(locked, password: "correct horse")
        b.seals = locked.active
        XCTAssertEqual(b.vault?.keyID, vault.keyID)
        out = try b.sync()
        XCTAssertEqual(out.downloaded, 1)
        XCTAssertEqual(out.sealedWithoutKey, 0)
        XCTAssertEqual(storeB.loadLibrary().notes[secret]?.title, "Secret plan")
        XCTAssertTrue(try text(storeB, secret).contains("the hidden words"))
        XCTAssertTrue(storeB.hasFile(secret, NoteFile.sha256(picture)))
        XCTAssertEqual(storeB.loadLibrary().notes[secret]?.isLocked, true)

        // Unlocked on B: written again in the clear, and the sealed files go.
        try editsB.setLocked(secret, false, owner: "")
        XCTAssertEqual(try b.sync().uploaded, 1)
        XCTAssertNotNil(everything(under: shared.appendingPathComponent("notes/\(secret)")).range(of: picture))
        XCTAssertEqual(try a.sync().downloaded, 1)
        XCTAssertEqual(storeA.loadLibrary().notes[secret]?.isLocked, false)
        _ = open
    }

    func testTheVaultsKeyAndWhatItSeals() throws {
        let vault = Vault()
        let sealed = try vault.seal(Data("words".utf8), as: "note:1")
        XCTAssertEqual(try vault.open(sealed, as: "note:1"), Data("words".utf8))
        XCTAssertThrowsError(try vault.open(sealed, as: "note:2"), "what was sealed as one thing does not open as another")
        XCTAssertThrowsError(try Vault().open(sealed, as: "note:1"))
        XCTAssertNotEqual(try vault.seal(Data("words".utf8), as: "note:1"), sealed, "sealed twice, it looks different each time")
        XCTAssertEqual(Vault(stored: vault.stored)?.keyID, vault.keyID)
        XCTAssertNil(Vault(stored: Data([1, 2, 3])))
        let locked = try vault.locked(with: "pässword", rounds: 1000)
        XCTAssertEqual(try Vault(locked, password: "pässword").keyID, vault.keyID)
        XCTAssertEqual(try Vault(locked, password: "pa\u{308}ssword").keyID, vault.keyID, "the same password however its letters are composed")
        XCTAssertThrowsError(try Vault(locked, password: "password"))
        XCTAssertNil(try JSONEncoder().encode(locked).range(of: vault.stored))
    }
}
