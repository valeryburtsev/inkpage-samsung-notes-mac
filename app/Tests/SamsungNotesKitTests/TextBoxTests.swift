import XCTest
@testable import SamsungNotesKit

final class TextBoxTests: XCTestCase {
    func testATextBoxIsAnObjectOfItsPage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-box-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(root: root), edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "Boxes", body: "The note's own text")
        let rect = CGRect(x: 40, y: 300, width: 283, height: NoteFile.textBoxHeight("", width: 283, pageWidth: 848))
        XCTAssertEqual(rect.height, 96, "an empty box is two lines and its margins high, as the Windows client makes it")
        let box = try XCTUnwrap(try edits.addTextBox(id, page: 0, rect: rect))
        var file = try store.noteFile(id)
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))
        var node = try XCTUnwrap(file.root.descendants("object").first { $0["id"] == box && $0["type"] == "textBox" })
        XCTAssertEqual(node["textAutoFit"], "2")
        XCTAssertEqual([node["leftMargin"], node["topMargin"], node["rightMargin"], node["bottomMargin"]], ["8", "4", "8", "4"])
        XCTAssertEqual(node.children.map(\.name), ["rect", "lineColorEffect", "lineStyleEffect", "originalRect"], "an empty box carries no text parts")
        XCTAssertNil(node["layoutType"], "it lies on its page, not among the note's floating objects")
        XCTAssertFalse(file.floatingIDs.contains(box))

        try edits.setTextBox(id, id: box, text: "Hello\nthere", rect: rect.offsetBy(dx: 10, dy: 20))
        file = try store.noteFile(id)
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))
        node = try XCTUnwrap(file.root.descendants("object").first { $0["id"] == box && $0["type"] == "textBox" })
        XCTAssertEqual(node.children.map(\.name), ["rect", "lineColorEffect", "lineStyleEffect", "originalRect", "spanOrderDataList", "text"])
        XCTAssertEqual(file.textBoxText(box), "Hello\nthere")
        // Read back, it is an object of the first page that says so, and the note's own text is untouched.
        let document = try store.load(id).document
        let read = try XCTUnwrap(document.pages[0].objects.first { $0.id == box })
        XCTAssertEqual(read.kind, .textBox)
        XCTAssertEqual(read.text?.plain, "Hello\nthere")
        XCTAssertEqual(read.rect.origin, CGPoint(x: 50, y: 320))
        XCTAssertEqual(read.margins.left, 8)
        XCTAssertEqual(document.body.plain.trimmingCharacters(in: .whitespacesAndNewlines), "The note's own text")
        XCTAssertEqual(NoteFile.textBoxHeight("Hello\nthere", width: 283, pageWidth: 848), 96)
        XCTAssertGreaterThan(NoteFile.textBoxHeight("one\ntwo\nthree\nfour", width: 283, pageWidth: 848), 150)

        try edits.removeTextBox(id, id: box)
        file = try store.noteFile(id)
        XCTAssertNil(file.textBoxText(box))
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))
    }
}
