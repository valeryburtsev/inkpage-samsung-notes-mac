import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SamsungNotesKit

/// Defects an independent review of the write paths found on 2026-10-11, each as the case that showed it.
final class RegressionTests: XCTestCase {
    var folder: URL!
    var store: LocalStore!
    var edits: LocalEdits!
    let fileHash = String(repeating: "ab", count: 32)

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-regress-\(UUID().uuidString)")
        store = LocalStore(root: folder)
        edits = LocalEdits(store: store)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    /// Puts a note in the store as if it had been downloaded.
    func arrive(_ file: NoteFile, commit: String) throws -> String {
        let record = try store.ingest(serverID: "SRV", commitID: commit, deviceName: "Phone", xml: file.data(), strokes: [:])
        store.update { $0.notes[record.id] = record; $0.nodes[record.id] = TreeNode(id: record.id, kind: .note, name: record.title, now: Date()) }
        return record.id
    }

    func base(_ string: String) -> NoteText { NoteText.uniform(string, like: nil, body: true) }

    /// Two spans of one kind that cross cannot be written: closing is last-opened-first.
    func crossing(_ text: NoteText) -> String? {
        let spans = text.spans
        for i in spans.indices {
            for j in spans.indices where j > i && spans[i].key == spans[j].key {
                let a = spans[i], b = spans[j]
                if (a.start < b.start && b.start < a.end && a.end < b.end) || (b.start < a.start && a.start < b.end && b.end < a.end) { return "\(a.key) \(a.start)-\(a.end) x \(b.start)-\(b.end)" }
            }
        }
        return nil
    }

    func testTypingOverTheStartOfARunDoesNotStretchTheRunBefore() {
        var text = base("Hello World")
        text.setProperty(NoteText.foreground, "-65536", in: 0..<6)
        text.setProperty(NoteText.foreground, "-16776961", in: 6..<11)
        text.replace(6..<8, with: "xy")
        XCTAssertNil(crossing(text))
        let back = NoteText(encoded: text.encoded().text, spanList: text.encoded().spanList)
        for offset in 0..<text.length { XCTAssertEqual(back.property(NoteText.foreground, at: offset), text.property(NoteText.foreground, at: offset), "at \(offset)") }
        XCTAssertEqual(text.property(NoteText.foreground, at: 7), "-16776961", "typed over blue text, it is blue")
        XCTAssertEqual(text.property(NoteText.foreground, at: 9), "-16776961")
    }

    func testTextThatBeginsWithALineBreak() throws {
        // As the plain writer (checked against the Windows client) puts it: two instructions before the text.
        let plain = TextStyle.newBody.body("\nabc")
        let read = NoteText(encoded: plain.text, spanList: plain.spans)
        XCTAssertEqual(read.string, "\nabc")
        XCTAssertEqual(read.paragraphs, [NoteText.firstParagraph, NoteText.laterParagraph])
        XCTAssertEqual(read.encoded().text.decodedBase64, plain.text.decodedBase64)
        // A checkbox on the second and a bullet on the empty first line stay where they are.
        var text = base("\nabc\ndef")
        text.setMark(.dot, 0)
        text.setMark(.checkbox(checked: false), 2)
        let back = NoteText(encoded: text.encoded().text, spanList: text.encoded().spanList)
        XCTAssertEqual(back.paragraphs, text.paragraphs)
        XCTAssertEqual([back.mark(0), back.mark(1), back.mark(2)], [.dot, .none, .checkbox(checked: false)])
        XCTAssertEqual(back.encoded().text, text.encoded().text)
        // Return in a centred heading keeps the next line centred.
        var centred = base("Title\nx")
        centred.setAlignment(2, 0)
        centred.replace(5..<5, with: "\n")
        XCTAssertEqual([centred.alignment(0), centred.alignment(1), centred.alignment(2)], [2, 2, 0])
    }

    /// Thousands of random edits: after each, the spans can be written, the paragraphs match the
    /// lines, and what is written reads back as the same text with the same look, and writes
    /// again as the same bytes.
    func testRandomEditsAlwaysLeaveATextThatCanBeWritten() {
        var state: UInt64 = 42
        func random(_ below: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(below, 1)))
        }
        let keys = [NoteText.bold, NoteText.foreground, NoteText.fontSize, NoteText.italic]
        let pieces = ["a", "bc", "\n", "x\ny", "", "\u{1F600}", "\n\n", "hello ", "Z"]
        var failures: [String] = []
        for round in 0..<6000 where failures.count < 3 {
            var text = base(["hello world", "ab\ncd\nef", "a\n\nb", "x", "one two\nthree", "\nlead"][random(6)])
            var log = [text.string.debugDescription]
            for _ in 0..<(1 + random(8)) {
                let units = Array(text.string.utf16)
                let a = random(units.count + 1), b = min(units.count, a + random(5))
                func whole(_ offset: Int) -> Bool { offset == 0 || offset >= units.count || !UTF16.isTrailSurrogate(units[offset]) }
                guard whole(a), whole(b) else { continue }
                if random(2) == 0 {
                    let piece = pieces[random(pieces.count)]
                    text.replace(a..<b, with: piece)
                    log.append("replace \(a)..<\(b) with \(piece.debugDescription)")
                } else if random(5) == 0 {
                    let line = random(text.paragraphStarts.count)
                    text.setMark([.dot, .number, .checkbox(checked: true), .none][random(4)], line)
                    log.append("mark line \(line)")
                } else {
                    let key = keys[random(keys.count)]
                    let value: String? = random(4) == 0 ? nil : (key == NoteText.bold || key == NoteText.italic ? "True" : ["-65536", "-16776961", "20"][random(3)])
                    text.setProperty(key, value, in: a..<b)
                    log.append("set \(key) \(value ?? "nil") \(a)..<\(b)")
                }
                var problem: String?
                if let crossed = crossing(text) { problem = "spans cross: \(crossed)" }
                if problem == nil, !text.isEmpty, text.paragraphs.count != text.string.components(separatedBy: "\n").count { problem = "\(text.paragraphs.count) paragraphs for \(text.string.components(separatedBy: "\n").count) lines" }
                if problem == nil, !text.isEmpty {
                    let written = text.encoded()
                    let back = NoteText(encoded: written.text, spanList: written.spanList)
                    if back.string != text.string { problem = "text changed in writing" } else if back.paragraphs != text.paragraphs { problem = "paragraphs changed in writing" } else if back.encoded().text != written.text || back.encoded().spanList != written.spanList { problem = "written twice, two results" } else {
                        for key in keys { for offset in 0..<text.length where back.property(key, at: offset) != text.property(key, at: offset) { problem = "\(key) differs at \(offset) after writing" } }
                    }
                }
                if let problem {
                    failures.append("round \(round): \(problem)\n  " + log.joined(separator: "\n  "))
                    break
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testAPictureThatNeedsANewPageSendsThePage() throws {
        let id = try arrive(NoteFile.newTextNote(title: "T", body: (0..<95).map { "line \($0)" }.joined(separator: "\n")), commit: "C1")
        let before = try store.noteFile(id).pageCount
        _ = try edits.addImage(id, data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]), fileExtension: "jpg", pixelSize: CGSize(width: 2000, height: 3000))
        let file = try store.noteFile(id)
        XCTAssertGreaterThan(file.pageCount, before)
        let record = try XCTUnwrap(store.loadLibrary().notes[id])
        XCTAssertEqual(record.pagesChanged, true)
        XCTAssertEqual(record.unsentFiles?.count, 1)
        XCTAssertEqual(file.pageAndLayerIDs.count, file.pageCount * 2)
        XCTAssertNotNil(try XMLTree.parse(Data(file.uploadDocument(pages: record.pagesChanged == true, body: true).utf8)).child("pageList"))
    }

    func testMovingAnObjectKeepsWhatAnotherDeviceSetOnIt() throws {
        let file = NoteFile.newTextNote(title: "T", body: "text")
        let picture = file.addImage(fileHash: fileHash, fileExtension: "jpg", size: CGSize(width: 100, height: 80))
        let object = try XCTUnwrap(file.root.descendants("object").first { $0["id"] == picture && $0["type"] != nil })
        object.child("fillEffect")?.attributes["transparency"] = "50"
        object.child("fillEffect")?.child("stretchOffset")?.attributes = ["l": "0.1", "t": "0.2", "r": "0.1", "b": "0"]
        object.child("lineStyleEffect")?.attributes["width"] = "4"
        object.child("originalRect")?.attributes = ["l": "0", "t": "0", "r": "400", "b": "320"]
        let id = try arrive(file, commit: "C1")
        var text = try XCTUnwrap(edits.richText(id)).body
        text.replace(0..<0, with: "one more line above\n")
        try edits.saveRich(id, title: nil, body: text)
        let after = try XCTUnwrap(try store.noteFile(id).root.descendants("object").first { $0["id"] == picture && $0["type"] != nil })
        XCTAssertEqual(after.child("fillEffect")?["transparency"], "50")
        XCTAssertEqual(after.child("fillEffect")?.child("stretchOffset")?["t"], "0.2")
        XCTAssertEqual(after.child("lineStyleEffect")?["width"], "4")
        XCTAssertEqual(after.child("originalRect")?["r"], "400", "a rectangle of its own is left alone")
        let rect = try XCTUnwrap(after.child("rect").map(NoteDocument.rect))
        XCTAssertGreaterThan(rect.minY, 40, "the picture moved down with the text")
        // Its outline and the points lines attach to moved with it.
        XCTAssertEqual(after.child("path")?.child("segmentList")?.all("segment").first?.double("y") ?? 0, rect.minY, accuracy: 0.01)
        XCTAssertEqual(after.child("connectionPointList")?.all("point").first?.double("y") ?? 0, rect.minY, accuracy: 0.01)
        // Something that is not a picture is not made into one by a move.
        let other = NoteFile.newTextNote(title: "T", body: "text")
        let shape = other.addImage(fileHash: fileHash, fileExtension: "jpg", size: CGSize(width: 50, height: 50), placement: .onPage(0, CGRect(x: 10, y: 10, width: 50, height: 50)))
        let node = try XCTUnwrap(other.root.descendants("object").first { $0["id"] == shape && $0["type"] != nil })
        node.attributes["type"] = "shape"
        node.child("fillEffect")?.attributes = ["type": "color", "solidColor": "-65536"]
        XCTAssertTrue(other.setFloatingRect(shape, CGRect(x: 20, y: 30, width: 100, height: 50)))
        XCTAssertEqual(node.child("fillEffect")?.attributes, ["type": "color", "solidColor": "-65536"])
        XCTAssertEqual(node.child("rect").map(NoteDocument.rect), CGRect(x: 20, y: 30, width: 100, height: 50))
    }

    func testPagesAndThePicturesInTheText() throws {
        // A new page takes no cached picture of the page before it.
        let phone = try NoteFile(data: try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("downsync-ink-phone.xml")))
        let at = try XCTUnwrap(phone.addPage())
        let added = try XCTUnwrap(phone.root.descendants("pageList").last?.all("page")[safe: at])
        XCTAssertNil(added.child("canvasCacheDataMap"))
        XCTAssertNil(added.child("drawnRect"))
        // A picture in the text is placed by the text: removing a page does not renumber it blindly.
        let id = try arrive(NoteFile.newTextNote(title: "T", body: "text"), commit: "C1")
        let picture = try XCTUnwrap(try edits.addImage(id, data: Data([0xFF, 0xD8, 0xFF, 0xE0, 9]), fileExtension: "jpg", pixelSize: CGSize(width: 100, height: 80)))
        try edits.removePage(id, index: 1)
        let document = try store.load(id).document
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertEqual(document.floating.first { $0.id == picture }?.pageIndex, 0)
        XCTAssertEqual(try XCTUnwrap(edits.richText(id)).body.objectIDs, [picture])
        // A note without a page list does not hang the save.
        let bare = NoteFile.newTextNote(title: "T", body: "text")
        bare.root.children.removeAll { $0.name == "pageList" }
        let bareID = try arrive(bare, commit: "C1")
        var text = try XCTUnwrap(edits.richText(bareID)).body
        text.replace(0..<0, with: String(repeating: "line\n", count: 300))
        let done = expectation(description: "saved")
        let edits = self.edits!
        let body = text
        Thread.detachNewThread { _ = try? edits.saveRich(bareID, title: nil, body: body); done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    func testFilesAndPlaceholders() throws {
        // One file shown twice stays while one picture of it does, whatever its count says.
        let file = NoteFile.newTextNote(title: "T", body: "text")
        let first = file.addImage(fileHash: fileHash, fileExtension: "jpg", size: CGSize(width: 100, height: 80))
        let second = file.addImage(fileHash: fileHash, fileExtension: "jpg", size: CGSize(width: 100, height: 80))
        for entry in file.root.descendants("contentFile") where entry["refCount"] != nil { entry.attributes["refCount"] = "1" }
        file.removeFloating([first])
        XCTAssertEqual(file.fileIDs, [fileHash])
        file.removeFloating([second])
        XCTAssertTrue(file.fileIDs.isEmpty)
        // Text that names a picture the note no longer holds is saved without that place.
        let source = NoteFile.newTextNote(title: "T", body: "text")
        let picture = source.addImage(fileHash: fileHash, fileExtension: "jpg", size: CGSize(width: 100, height: 80))
        let id = try arrive(source, commit: "C1")
        var typed = try XCTUnwrap(edits.richTextAndArrivals(id))
        typed.body.replace(0..<0, with: "typed ")
        let newer = try NoteFile(data: source.data())
        newer.removeFloating([picture])
        _ = try arrive(newer, commit: "C2")
        let copy = try XCTUnwrap(try edits.saveRich(id, title: nil, body: typed.body, typedInto: typed.arrivals))
        let kept = try store.noteFile(copy)
        XCTAssertTrue(kept.bodyText.objectIDs.isEmpty)
        XCTAssertTrue(kept.bodyText.string.hasPrefix("typed text"))
        XCTAssertTrue(kept.floatingIDs.isEmpty)
    }

    func testStrokesWithPointsThatAreNoNumbers() throws {
        let stroke = NewStroke(points: [InkPoint(x: 1, y: 1), InkPoint(x: .nan, y: 2), InkPoint(x: 3, y: .infinity), InkPoint(x: 4, y: 4, pressure: .nan)], argb: 0xFF00_0000, penSize: 6)
        let prepared = try XCTUnwrap(LocalEdits.prepared(stroke))
        XCTAssertEqual(prepared.points.count, 2)
        XCTAssertEqual(prepared.points.last?.pressure, 1)
        XCTAssertNil(LocalEdits.prepared(NewStroke(points: [InkPoint(x: .nan, y: 1)], argb: 0, penSize: 6)))
        XCTAssertNil(LocalEdits.prepared(NewStroke(points: [InkPoint(x: 1, y: 1)], argb: 0, penSize: .nan)))
        _ = StrokeEncoder.encode(prepared, modifiedMicros: 1, drawnMicros: 0, pageWidth: 848, pageHeight: 1200)
    }

    /// A picture set in the text never lies across the break between two pages: when what is
    /// left of a page has no room for it, it starts the next page. Text lines likewise.
    func testNothingIsSetAcrossAPageBreak() throws {
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 4, 2])
        for lines in [0, 1, 5, 12, 20, 24, 25, 26, 27, 28, 29, 30, 31, 33, 40, 55, 70] {
            let body = (0..<lines).map { "line \($0)" }.joined(separator: "\n")
            let id = try edits.createTextNote(title: "T", body: body)
            _ = try edits.addImage(id, data: picture + Data([UInt8(lines)]), fileExtension: "jpg", pixelSize: CGSize(width: 800, height: 600))
            let document = try store.load(id).document
            let column = TextColumn(document)
            let object = try XCTUnwrap(document.floating.first)
            XCTAssertGreaterThanOrEqual(object.rect.minY, column.top - 1, "\(lines) lines: starts below the page's top margin")
            XCTAssertLessThanOrEqual(object.rect.maxY, column.pageHeight - column.bottom + 1, "\(lines) lines: ends above the page's foot, on page \(object.pageIndex ?? -1)")
            XCTAssertLessThan(object.pageIndex ?? 0, document.pages.count, "\(lines) lines: its page exists")
            // The text itself: every piece of it lies within one page's room.
            let flow = try XCTUnwrap(TextFlow(document))
            for piece in flow.pieces {
                let page = (piece.rect.minY / column.stride).rounded(.down)
                XCTAssertGreaterThanOrEqual(piece.rect.minY, page * column.stride + column.top - 0.5)
                XCTAssertLessThanOrEqual(piece.rect.maxY, page * column.stride + column.pageHeight - column.bottom + 0.5)
            }
            XCTAssertGreaterThanOrEqual(document.pages.count, flow.pagesUsed, "\(lines) lines: the note has the pages its text needs")
        }
        // The case in the picture: text that leaves less room than the picture needs.
        let id = try edits.createTextNote(title: "T", body: (0..<26).map { "line \($0)" }.joined(separator: "\n"))
        _ = try edits.addImage(id, data: picture, fileExtension: "jpg", pixelSize: CGSize(width: 800, height: 600))
        let document = try store.load(id).document
        let object = try XCTUnwrap(document.floating.first)
        XCTAssertEqual(object.pageIndex, 1, "it went to the second page whole")
        XCTAssertEqual(object.rect.minY, TextColumn(document).top, accuracy: 2)
        XCTAssertEqual(NoteLayout.shownPageCount(of: document), 2)
    }

    /// A red picture as a PNG file.
    func redPicture(_ width: Int, _ height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// Whether a point of a page, in the page's units, is drawn red.
    func isRed(_ note: LoadedNote, page: Int, x: Double, y: Double) throws -> Bool {
        let width = 424
        let image = try XCTUnwrap(NoteRenderer.pageImage(note, page: page, pixelWidth: width, dark: false, images: { note.image($0) }))
        let scale = Double(width) / NoteLayout(note.document).pageWidth
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // The picture's rows run down from its top; a bitmap context's y runs up.
        context.draw(image, in: CGRect(x: -(x * scale).rounded(), y: -(Double(image.height) - (y * scale).rounded() - 1), width: Double(image.width), height: Double(image.height)))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60
    }

    /// A note saved before text was set page by page has its picture's place stored across the
    /// break. It is drawn where the text puts it now, without being saved again.
    func testANoteSavedWithAPictureAcrossTheBreakIsDrawnRight() throws {
        let id = try edits.createTextNote(title: "T", body: (0..<26).map { "line \($0)" }.joined(separator: "\n"))
        let object = try XCTUnwrap(try edits.addImage(id, data: try redPicture(800, 600), fileExtension: "png", pixelSize: CGSize(width: 800, height: 600)))
        // As the older build left it: on the first page, running over its foot.
        let file = try store.noteFile(id)
        XCTAssertTrue(file.setFloatingRect(object, CGRect(x: 37.7, y: 893, width: 660, height: 495), page: 0))
        try store.write(file)
        let note = try store.load(id)
        let stale = try XCTUnwrap(note.document.floating.first)
        XCTAssertEqual(stale.pageIndex, 0)
        XCTAssertGreaterThan(stale.rect.maxY, 1200, "the stored place crosses the break")
        XCTAssertFalse(try isRed(note, page: 0, x: 300, y: 1100), "nothing of it at the foot of the first page")
        XCTAssertTrue(try isRed(note, page: 1, x: 300, y: 200), "it is whole at the top of the second")
        XCTAssertFalse(try isRed(note, page: 1, x: 300, y: 700))
    }

    func testTurningAPicture() throws {
        let id = try edits.createTextNote(title: "T", body: "above\nbelow")
        let object = try XCTUnwrap(try edits.addImage(id, data: try redPicture(400, 100), fileExtension: "png", pixelSize: CGSize(width: 400, height: 100)))
        let flat = try XCTUnwrap(try store.load(id).document.floating.first)
        XCTAssertEqual(flat.rotation, 0)
        XCTAssertNil(try store.noteFile(id).root.descendants("object").first { $0["id"] == object && $0["type"] != nil }?["rotationDegree"], "an object that is not turned says nothing of it")

        try edits.setFloatingRotation(id, id: object, degrees: 90)
        let node = try XCTUnwrap(try store.noteFile(id).root.descendants("object").first { $0["id"] == object && $0["type"] != nil })
        XCTAssertEqual(node["rotationDegree"], "90")
        XCTAssertEqual(node["hash"], NoteHash.object(id: object, time: node["modifiedTime"] ?? ""))
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(XMLTree.parse(Data(try store.noteFile(id).treeDocument().utf8)))))
        var note = try store.load(id)
        let turned = try XCTUnwrap(note.document.floating.first)
        XCTAssertEqual(turned.rotation, 90)
        XCTAssertEqual(turned.rect.width, 400, accuracy: 0.01, "its own size is as it was")
        XCTAssertEqual(turned.rect.height, 100, accuracy: 0.01)
        XCTAssertEqual(turned.turnedSize.width, 100, accuracy: 0.01)
        XCTAssertEqual(turned.turnedSize.height, 400, accuracy: 0.01)
        // The text made room for it standing on end: its middle moved down by half the difference.
        XCTAssertEqual(turned.rect.midY - flat.rect.midY, 150, accuracy: 2)
        XCTAssertEqual(turned.rect.midX, flat.rect.minX + 50, accuracy: 2, "and it stands at the left of the column")
        // Drawn turned: red where it stands now, not where it lay.
        XCTAssertTrue(try isRed(note, page: 0, x: turned.rect.midX, y: turned.rect.midY - 180))
        XCTAssertFalse(try isRed(note, page: 0, x: turned.rect.midX + 150, y: turned.rect.midY))
        // Angles are kept between -180 and 180, and none at all is written as none.
        try edits.setFloatingRotation(id, id: object, degrees: 405)
        XCTAssertEqual(try store.load(id).document.floating.first?.rotation, 45)
        try edits.setFloatingRotation(id, id: object, degrees: 360)
        note = try store.load(id)
        XCTAssertEqual(note.document.floating.first?.rotation, 0)
        XCTAssertNil(try store.noteFile(id).root.descendants("object").first { $0["id"] == object && $0["type"] != nil }?["rotationDegree"])
        XCTAssertEqual(try XCTUnwrap(note.document.floating.first).rect.midY, flat.rect.midY, accuracy: 2, "back where it was")
        XCTAssertEqual(NoteObject.turned(CGSize(width: 30, height: 40), by: 0), CGSize(width: 30, height: 40))
        XCTAssertEqual(NoteObject.turned(CGSize(width: 30, height: 40), by: .nan), CGSize(width: 30, height: 40))
    }
}
