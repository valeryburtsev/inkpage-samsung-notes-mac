import XCTest
@testable import SamsungNotesKit

/// Sticky notes and tables in a note's document: two test notes made in the Windows client,
/// as the service delivered them, and notes made here.
final class StickyAndTableNoteTests: XCTestCase {
    private var folder: URL!
    private var store: LocalStore!
    private var edits: LocalEdits!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-sticky-\(UUID().uuidString)")
        store = LocalStore(root: folder)
        edits = LocalEdits(store: store)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)))
    }

    /// Puts a note of the Windows client into the store, as a sync would.
    private func keep(_ name: String) throws -> String {
        let file = try NoteFile(data: try data(name))
        try store.write(file)
        return file.id
    }

    private func tables(_ id: String) throws -> [NoteObject] { try store.load(id).document.floating.filter { $0.kind == .table } }
    private func stickies(_ id: String) throws -> [NoteObject] { try store.load(id).document.pages.flatMap(\.objects).filter { $0.kind == .sticky } }
    private func xml(_ id: String) throws -> NoteFile { try store.noteFile(id) }

    // MARK: Tables

    func testTablesOfTheWindowsClientAreReadWhereTheyStand() throws {
        let id = try keep("tables-windows.xml")
        let document = try store.load(id).document
        let found = document.floating.filter { $0.kind == .table }
        XCTAssertEqual(found.map(\.id), ["c74d6044-c64b-11f1-bf6e-3b0df6ece061", "da023d90-c64b-11f1-91cd-e78127ee3ea4"])
        XCTAssertEqual(found.map(\.tableIsExact), [true, true])
        XCTAssertEqual(found.map(\.inText), [true, true])
        XCTAssertEqual(found[0].table?.texts, [["Test 1", "Test 2"], ["Test 3", "Test 4"]])
        XCTAssertEqual(found[1].table?.texts, [["Test 5", "Test 6", "Test 7"], ["Test 8", "Test 9", "Test 10"]])
        // An object's hash is that of its id and time.
        let file = try xml(id)
        for object in file.note.child("floatingObjectList")?.all("object") ?? [] {
            XCTAssertEqual(object["hash"], NoteHash.object(id: object["id"] ?? "", time: object["modifiedTime"] ?? ""))
        }
        // The text, laid out here, puts the tables where the Windows client did.
        let positions = try XCTUnwrap(TextFlow(document)).positions
        let rooms = NoteRenderer.pictureSizes(document)
        for table in found {
            let place = try XCTUnwrap(positions[table.id]), room = try XCTUnwrap(rooms[table.id])
            XCTAssertEqual(place.y + (room.height - table.rect.height) / 2, table.rect.minY, accuracy: 0.05, table.id)
            XCTAssertEqual(place.x + (room.width - table.rect.width) / 2, table.rect.minX, accuracy: 0.05, table.id)
        }
    }

    func testChangingATableOfTheWindowsClient() throws {
        let id = try keep("tables-windows.xml")
        let before = try tables(id)
        XCTAssertTrue(try edits.setTable(id, id: before[0].id, texts: [["One", "Two"], ["Three", "Four"], ["Five", ""]]))
        let after = try tables(id)
        XCTAssertEqual(after[0].table?.texts, [["One", "Two"], ["Three", "Four"], ["Five", ""]])
        XCTAssertTrue(after[0].tableIsExact)
        XCTAssertEqual(after[0].rect.minY, before[0].rect.minY, accuracy: 0.01)
        XCTAssertEqual(after[0].rect.height, before[0].rect.height * 1.5, accuracy: 0.5)
        // The table below makes way for the new row.
        XCTAssertEqual(after[1].rect.minY - before[1].rect.minY, before[0].rect.height / 2, accuracy: 0.6)
        XCTAssertEqual(after[1].table?.texts, before[1].table?.texts)
        XCTAssertEqual(after[1].table.map { $0.rect.minY } ?? 0, after[1].rect.minY, accuracy: 0.01)
        let file = try xml(id)
        XCTAssertTrue(NoteHash.verify(tree: file.tree))
        for object in file.note.child("floatingObjectList")?.all("object") ?? [] {
            XCTAssertEqual(object["hash"], NoteHash.object(id: object["id"] ?? "", time: object["modifiedTime"] ?? ""))
            // The record carries the same time as its object.
            XCTAssertEqual(file.table(object["id"] ?? "").map { String($0.modified) }, object["modifiedTime"])
        }
        XCTAssertEqual(store.loadLibrary().notes[id]?.pending, .create)
    }

    func testATableMadeHere() throws {
        let id = try edits.createTextNote(title: "Plan", body: "Above\nBelow")
        let made = try XCTUnwrap(try edits.addTable(id, rows: 2, columns: 3, textOffset: 6))
        var found = try tables(id)
        XCTAssertEqual(found.map(\.id), [made])
        XCTAssertTrue(found[0].tableIsExact)
        XCTAssertTrue(found[0].inText)
        XCTAssertEqual(found[0].table?.texts, [["", "", ""], ["", "", ""]])
        var file = try xml(id)
        XCTAssertEqual(file.attributes["formatVersion"], "5400")
        XCTAssertEqual(file.attributes["minFormatVersion"], "5400")
        XCTAssertTrue(NoteHash.verify(tree: file.tree))
        XCTAssertEqual(file.bodyText.objectIDs, [made])
        let object = try XCTUnwrap(file.note.child("floatingObjectList")?.all("object").first)
        // Every attribute and part the Windows client writes for a table is there.
        let model = try XCTUnwrap(try NoteFile(data: try data("tables-windows.xml")).note.child("floatingObjectList")?.all("object").first)
        XCTAssertEqual(Set(object.attributes.keys), Set(model.attributes.keys))
        XCTAssertEqual(object.children.map(\.name), model.children.map(\.name))
        // The table lies under the first line, as wide as the text.
        let column = file.textColumn
        XCTAssertEqual(found[0].rect.minX, column.left, accuracy: 1)
        XCTAssertEqual(found[0].rect.width, column.width, accuracy: 2)
        XCTAssertGreaterThan(found[0].rect.minY, column.top + 10)

        XCTAssertTrue(try edits.setTable(id, id: made, texts: [["a", "b", "c"], ["d", "e", "f"]]))
        found = try tables(id)
        XCTAssertEqual(found[0].table?.texts, [["a", "b", "c"], ["d", "e", "f"]])
        XCTAssertFalse(try edits.setTable(id, id: "no-such-table", texts: [["x"]]))

        // Text typed above pushes the table down; the table's record follows.
        let top = found[0].rect.minY
        var body = try XCTUnwrap(edits.richText(id)).body
        body.replace(0..<0, with: "One more line\n")
        try edits.saveRich(id, title: nil, body: body)
        found = try tables(id)
        XCTAssertGreaterThan(found[0].rect.minY, top + 10)
        XCTAssertEqual(found[0].table.map { $0.rect.minY } ?? 0, found[0].rect.minY, accuracy: 0.01)
        XCTAssertTrue(found[0].tableIsExact)
        XCTAssertEqual(found[0].table?.texts, [["a", "b", "c"], ["d", "e", "f"]])

        try edits.removeFloating(id, ids: [made])
        file = try xml(id)
        XCTAssertTrue(try tables(id).isEmpty)
        XCTAssertTrue(file.bodyText.objectIDs.isEmpty)
        XCTAssertTrue(NoteHash.verify(tree: file.tree))
    }

    // MARK: Sticky notes

    func testAStickyNoteOfTheWindowsClientIsRead() throws {
        let id = try keep("sticky-windows.xml")
        let hash = "4054004f50105b0072afb65301cc4008842e397c491875116e45975dc8d123ca"
        store.writeFile(id, hash, try data("sticky-windows.sdocx"))
        let found = try stickies(id)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].id, "ff97f23e-c64b-11f1-bb14-8fb1e67e33a3")
        XCTAssertEqual(found[0].attachFile, hash)
        XCTAssertEqual(found[0].paper, 0xFFFF_E6AE)
        XCTAssertEqual(found[0].sticky?.text, "Here we go Test \n\n\n1123\n\n\n555")
        XCTAssertTrue(found[0].stickyIsExact)
        // Its square is eighteen units of text size wide, and written twice in two ways.
        XCTAssertEqual(found[0].rect.width, LocalEdits.stickySide(pageWidth: 1183), accuracy: 0.01)
        let file = try xml(id)
        let node = try XCTUnwrap(file.stickyNode(found[0].id)?.node)
        let kept = node.child("customDataList")?.all("pair").first { $0["key"]?.decodedBase64 == "skn_collapse_rect" }?["value"]?.decodedBase64
        XCTAssertEqual(kept, NoteFile.stickyRect(found[0].rect))
        // The entry of its file is hashed as this client hashes the entries it makes.
        let entry = try XCTUnwrap(file.note.child("contentFileList")?.all("contentFile").first)
        XCTAssertEqual(entry["hash"], NoteHash.contentFile(id: hash, bindNumber: 6, name: "6@stickymemo_2026-10-12_15_48_33.sdocx", refCount: 1, time: entry["modifiedTime"] ?? ""))
        XCTAssertEqual(found[0].sticky?.fileName.count, "stickymemo_2026-10-12_15_48_33.sdocx".count)

        // Changed here: a new file under the next number and the old name, and the old file gone.
        XCTAssertTrue(try edits.setSticky(id, id: found[0].id, text: "Changed on the Mac", paper: StickyDocument.papers[3]))
        let after = try stickies(id)
        XCTAssertEqual(after[0].sticky?.text, "Changed on the Mac")
        XCTAssertEqual(after[0].paper, 0xFFD0_E0F4)
        XCTAssertEqual(after[0].rect, found[0].rect)
        XCTAssertTrue(after[0].stickyIsExact)
        let changed = try xml(id)
        let entries = changed.note.child("contentFileList")?.all("contentFile") ?? []
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["id"], after[0].attachFile)
        XCTAssertNotEqual(after[0].attachFile, hash)
        XCTAssertEqual(entries.first?["name"]?.decodedBase64.map { String($0.dropFirst(2)) }, found[0].sticky?.fileName)
        XCTAssertEqual(entries.first?["bindNumber"], "7")
        XCTAssertTrue(NoteHash.verify(tree: changed.tree))
        XCTAssertEqual(store.loadLibrary().notes[id]?.unsentFiles, [try XCTUnwrap(after[0].attachFile)])
        XCTAssertFalse(try edits.setSticky(id, id: found[0].id, text: "Changed on the Mac"), "the same again changes nothing")
    }

    func testAStickyNoteMadeHere() throws {
        let id = try edits.createTextNote(title: "Shopping", body: "List")
        let width = Double(try xml(id).pageSize(0).width)
        let made = try XCTUnwrap(try edits.addSticky(id, page: 0, origin: CGPoint(x: 300, y: 200), text: "Buy milk"))
        var found = try stickies(id)
        XCTAssertEqual(found.map(\.id), [made])
        XCTAssertEqual(found[0].sticky?.text, "Buy milk")
        XCTAssertEqual(found[0].paper, StickyDocument.papers[0])
        XCTAssertTrue(found[0].stickyIsExact)
        XCTAssertEqual(found[0].rect.origin.x, 300, accuracy: 0.01)
        XCTAssertEqual(found[0].rect.width, 18 * width / 360, accuracy: 0.01)
        var file = try xml(id)
        XCTAssertEqual(file.attributes["formatVersion"], "5303")
        XCTAssertEqual(file.attributes["minFormatVersion"], "5303")
        let pages = file.note.all("pageList").last?.all("page") ?? []
        XCTAssertEqual(pages.map { $0["formatVersion"] }, ["5303", "4000"])
        XCTAssertEqual(pages[0].children.map(\.name).filter { $0 == "customObjectList" || $0 == "layerList" }, ["customObjectList", "layerList"])
        XCTAssertTrue(NoteHash.verify(tree: file.tree))
        XCTAssertEqual(pages[0]["hash"], file.tree.child("pageList")?.all("page").first?["h"])
        // Written in the form of the Windows client's own, part for part.
        let model = try XCTUnwrap(try NoteFile(data: try data("sticky-windows.xml")).stickyNode("ff97f23e-c64b-11f1-bb14-8fb1e67e33a3")?.node)
        let node = try XCTUnwrap(file.stickyNode(made)?.node)
        XCTAssertEqual(node.children.map(\.name), model.children.map(\.name))
        XCTAssertEqual(node.descendants("pair").map { $0["key"] }, model.descendants("pair").map { $0["key"] })
        XCTAssertEqual(Set(node.attributes.keys), Set(model.attributes.keys))
        XCTAssertEqual(file.fileIDs, [try XCTUnwrap(found[0].attachFile)])
        XCTAssertTrue(store.hasFile(id, try XCTUnwrap(found[0].attachFile)))
        XCTAssertEqual(store.loadLibrary().notes[id]?.pagesChanged, true)

        // Moved to the second page.
        let side = found[0].rect.width
        try edits.moveSticky(id, id: made, to: CGRect(x: 40, y: 60, width: side, height: side), page: 1)
        let document = try store.load(id).document
        XCTAssertTrue(document.pages[0].objects.isEmpty)
        XCTAssertEqual(document.pages[1].objects.first?.id, made)
        XCTAssertEqual(document.pages[1].objects.first?.rect.origin.y ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(document.pages[1].objects.first?.sticky?.text, "Buy milk")
        file = try xml(id)
        XCTAssertTrue(NoteHash.verify(tree: file.tree))
        XCTAssertNil(file.note.all("pageList").last?.all("page").first?.child("customObjectList"))

        // The page it is on goes: its file goes with it.
        let second = try XCTUnwrap(try edits.addSticky(id, page: 0, origin: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(try xml(id).fileIDs.count, 2)
        XCTAssertEqual(try stickies(id).first { $0.id == second }?.sticky?.text, "")
        try edits.removePage(id, index: 1)
        found = try stickies(id)
        XCTAssertEqual(found.map(\.id), [second])
        XCTAssertEqual(try xml(id).fileIDs.count, 1)

        try edits.removeSticky(id, id: second)
        file = try xml(id)
        XCTAssertTrue(try stickies(id).isEmpty)
        XCTAssertTrue(file.fileIDs.isEmpty)
        XCTAssertNil(file.note.descendants("customObjectList").first)
        XCTAssertTrue(NoteHash.verify(tree: file.tree))
    }
}
