import XCTest
@testable import SamsungNotesKit

func fixture(_ name: String) throws -> Data {
    let folder = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try Data(contentsOf: folder.appendingPathComponent(name))
}

final class NoteFormatTests: XCTestCase {
    func testPhoneInkNoteParses() throws {
        let parts = Multipart.parse(try fixture("downsync-ink-phone.multipart"))
        XCTAssertEqual(parts.map(\.name), ["noteResource", "strokeResource", "strokeResource"])
        XCTAssertEqual(parts[1].filename?.split(separator: "_").first.map(String.init), "9aac3664-c50b-11f1-8cc5-f3e90122fd91")
        let document = try NoteDocument(xml: parts[0].body)
        XCTAssertEqual(document.id, "eeaee3f2-83de-03d4-0000-01a12862677e")
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertEqual(document.pages[0].objects.map(\.kind), [.stroke, .stroke])
        XCTAssertEqual(document.width, 1080)
        XCTAssertEqual(document.density, 3)
        XCTAssertEqual(document.penNames[0], "com.samsung.android.sdk.pen.pen.preload.FountainPen")
        XCTAssertTrue(document.hasInk)
        XCTAssertEqual(document.commitID, "179167891271018e4fddbae559544")
        XCTAssertEqual(document.downloadURLs.count, 1)
        XCTAssertEqual(document.files.first?.name, "0@page_0000009.spi")
    }

    func testWindowsUploadsParse() throws {
        let ink = Multipart.parse(try fixture("create-ink-windows.multipart"))
        XCTAssertEqual(ink.count, 4)
        XCTAssertEqual(ink.filter { $0.name == "strokeResource" }.count, 3)
        XCTAssertEqual(try NoteDocument(xml: ink[0].body).density, 848.0 / 360, accuracy: 1e-9)
        let text = try NoteDocument(xml: Multipart.parse(try fixture("create-text-windows.multipart"))[0].body)
        XCTAssertEqual(text.title.plain, "Hello world!")
        XCTAssertTrue(text.body.isEmpty)
        XCTAssertFalse(text.hasInk)
        let picture = try NoteDocument(xml: Multipart.parse(try fixture("update-image-painting-windows.multipart"))[0].body)
        XCTAssertEqual(picture.floating.first?.kind, .painting)
        XCTAssertNotNil(picture.floating.first?.thumbnailFile)
    }

    func testHashChainOfRealNotes() throws {
        for name in ["downsync-ink-phone.xml", "create-ink-windows.xml"] {
            let root = try XMLTree.parse(try fixture(name))
            let tree = try XCTUnwrap(root.descendant("noteTree"), name)
            XCTAssertTrue(NoteHash.verify(tree: tree), name)
        }
    }

    func testFolderFeedParses() throws {
        let root = try XMLTree.parse(try fixture("folder-changes-initial.xml"))
        let nodes = try XCTUnwrap(root.descendant("nodeList")).all("node").compactMap(TreeNode.init)
        XCTAssertEqual(nodes.count, 17)
        XCTAssertEqual(nodes.filter { $0.state == .normal }.count, 2)
        XCTAssertTrue(nodes.allSatisfy { $0.kind == .note && $0.parentID == "root" })
        XCTAssertEqual(nodes.first { $0.state == .deleted }?.restorePath, "uncategorized:///")
        XCTAssertNotNil(root.value("lastChangePoint"))
        let change = try XCTUnwrap(XMLTree.parse(try fixture("note-changes-page.xml")).all("changes").compactMap(NoteChange.init).first)
        XCTAssertEqual(change.serverID, "16952941042510dac801d5d98a034")
        XCTAssertFalse(change.isDeleted)
    }

    func testTitleEncodingEqualsWindows() throws {
        let xml = String(decoding: Multipart.parse(try fixture("create-text-windows.multipart"))[0].body, as: UTF8.self)
        let encoded = TextStyle.newTitle.title("Hello world!")
        XCTAssertTrue(xml.contains("<text>\(encoded.text)</text>"))
        XCTAssertTrue(xml.contains("val=\"\(Data(encoded.spans[0].utf8).base64EncodedString())\""))
    }

    func testBodyEncodingRoundTrips() {
        for text in ["one line", "two\nlines", "a\n\n\nb\n", "ünïcode ✓ 日本語\nsecond"] {
            XCTAssertEqual(RichText(encoded: TextStyle.newBody.body(text).text).plain, text)
            XCTAssertTrue(TextStyle.read(encoded: TextStyle.newBody.body(text).text).editable)
        }
        XCTAssertEqual(TextStyle.newBody.body("ab\ncd").spans, ["1,0,5,1,-14342875", "17,0,5,1,0", "3,0,5,1,12"])
    }

    /// The text of a note edited in the Windows client, encoded here, must equal what the client sent.
    /// Runs only where the capture is: it holds private notes and is not part of the fixtures.
    func testBodyEncodingEqualsWindowsCapture() throws {
        let flows = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../captures/s1-first-launch/flows.jsonl").standardizedFileURL
        guard let text = try? String(contentsOf: flows, encoding: .utf8) else { throw XCTSkip("no capture here") }
        var checked = 0
        for line in text.split(separator: "\n") where line.contains("/update\"") || line.contains("/samsungnotes/v1/notes\"") {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], record["method"] as? String == "POST",
                  let body = record["request_body"] as? [String: Any], let xml = (body["text"] as? String) ?? (body["b64"] as? String).flatMap({ Data(base64Encoded: $0) }).map({ String(decoding: $0, as: UTF8.self) }),
                  let part = Multipart.parse(Data(xml.utf8)).first, let root = try? XMLTree.parse(part.body),
                  let object = root.all("bodyText").compactMap({ $0.child("object") }).first, let sent = object.value("text"), !sent.isEmpty else { continue }
            // Texts in several styles or with pictures in them are not written by this client.
            let read = TextStyle.read(encoded: sent)
            guard read.editable, let style = read.style else { continue }
            let plain = RichText(encoded: sent).plain
            let ours = style.body(plain)
            XCTAssertEqual(ours.text, sent, "note text of \(plain.count) characters")
            let spans = object.child("spanOrderDataList")?.all("spanOrderData").compactMap { $0["val"]?.decodedBase64 } ?? []
            XCTAssertEqual(ours.spans, spans)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testNewTextNoteIsShapedLikeWindows() throws {
        let file = NoteFile.newTextNote(title: "Shopping", body: "milk\neggs", now: Date(timeIntervalSince1970: 1_791_680_000))
        let document = try NoteDocument(xml: file.data())
        XCTAssertEqual(document.title.plain, "Shopping")
        XCTAssertEqual(document.body.plain, "milk\neggs")
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertEqual(document.density, 848.0 / 360, accuracy: 1e-9)
        let upload = try XMLTree.parse(Data(file.uploadDocument(pages: true, body: true).utf8))
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(upload.child("noteTree"))))
        // Every element and attribute the Windows client sends for a new text note is there, and no other.
        let theirs = try XMLTree.parse(Multipart.parse(try fixture("create-text-windows.multipart"))[0].body)
        func shape(_ node: SamsungNotesKit.XMLNode, _ path: String, into out: inout Set<String>) {
            let here = path + "/" + node.name
            out.insert(here)
            for key in node.attributes.keys { out.insert(here + "@" + key) }
            for child in node.children { shape(child, here, into: &out) }
        }
        var mine: Set<String> = [], windows: Set<String> = []
        shape(upload, "", into: &mine)
        shape(theirs, "", into: &windows)
        // The Windows note has a title and no body text; ours has both.
        let bodyText = Set(mine.filter { $0.contains("/bodyText/object/spanOrderDataList") || $0.contains("/bodyText/object/text") })
        XCTAssertEqual(mine.subtracting(bodyText), windows)
        // The hashes in the tree are the ones on the objects themselves.
        XCTAssertEqual(upload.child("noteTree")?.child("bodyText")?["h"], upload.all("bodyText").last?.child("object")?["hash"])
        XCTAssertEqual(upload.child("noteTree")?.child("pageList")?.all("page").map { $0["h"] }, upload.all("pageList").last?.all("page").map { $0["hash"] })
    }

    func testEditingKeepsTheTreeConsistent() throws {
        let file = try NoteFile(data: Multipart.parse(try fixture("create-text-windows.multipart"))[0].body)
        let before = try XMLTree.parse(Data(file.treeDocument().utf8)).child("bodyText")?["h"]
        file.setBody("first\nsecond", now: Date(timeIntervalSince1970: 1_791_690_000))
        file.setTitle("Renamed", now: Date(timeIntervalSince1970: 1_791_690_001))
        let tree = try XMLTree.parse(Data(file.treeDocument().utf8))
        XCTAssertTrue(NoteHash.verify(tree: tree))
        XCTAssertNotEqual(tree.child("bodyText")?["h"], before)
        XCTAssertEqual(tree["ver"], "4000")
        let document = try NoteDocument(xml: file.data())
        XCTAssertEqual(document.title.plain, "Renamed")
        XCTAssertEqual(document.body.plain, "first\nsecond")
        XCTAssertEqual(document.attributes["fileRevision"], "3")
        let metadataOnly = try XMLTree.parse(Data(file.uploadDocument(pages: false, body: false).utf8))
        XCTAssertEqual(metadataOnly.children.map(\.name), ["noteTree", "attributes"])
        file.setState(.trashed)
        XCTAssertEqual(try NoteDocument(xml: file.data()).attributes["state"], "trashed")
    }

    /// Formatting in the values the client's own code writes: the Windows spelling and the phone's.
    func testFormattingIsRead() {
        func encode(_ stream: String) -> String { Data(stream.utf8).base64EncodedString() }
        func chunk(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
        let bold = encode("<?a 'span/fontSize'='1,17.0' 'span/bold'='3,true' 'paragraph/parsingState'='false'?>\(chunk("strong"))<?a 'span/bold'?>\(chunk(" plain"))<?a 'span/fontSize' 'paragraph/parsingState'?>")
        let text = RichText(encoded: bold)
        XCTAssertEqual(text.runs.map(\.bold), [true, false])
        XCTAssertEqual(text.runs.map(\.fontSize), [17, 17])
        XCTAssertEqual(text.plain, "strong plain")
        XCTAssertFalse(TextStyle.read(encoded: bold).editable)
        // A second colour inside the first: when it ends, the first is back.
        let nested = encode("<?a 'span/foregroundColor'='1,-14342875' 'paragraph/parsingState'='False'?>\(chunk("a "))<?a 'span/foregroundColor'='3,-51658'?>\(chunk("red"))<?a 'span/foregroundColor'?>\(chunk(" z"))<?a 'span/foregroundColor' 'paragraph/parsingState'?>")
        XCTAssertEqual(RichText(encoded: nested).runs.map(\.color), [UInt32(bitPattern: -14342875), UInt32(bitPattern: -51658), UInt32(bitPattern: -14342875)])
        let list = encode("<?a 'span/fontSize'='1,12' 'paragraph/bullet'='2,True' 'paragraph/parsingState'='False'?>\(chunk("done"))<?a 'paragraph/bullet' 'paragraph/parsingState' 'paragraph/bullet'='2,False' 'paragraph/parsingState'='False'?>\(chunk("\ntodo"))<?a 'paragraph/bullet' 'paragraph/parsingState' 'paragraph/indentLevel'='1,1' 'paragraph/bullet'='4,7' 'paragraph/parsingState'='False'?>\(chunk("\nfirst"))<?a 'paragraph/indentLevel' 'paragraph/bullet' 'paragraph/parsingState' 'paragraph/bullet'='8,0'?>\(chunk("\ndot"))<?a 'span/fontSize' 'paragraph/bullet'?>")
        let items = RichText(encoded: list)
        XCTAssertEqual(items.runs.map(\.bullet), [.checkbox(checked: true), .checkbox(checked: false), .number(1), .dot])
        XCTAssertEqual(items.runs.map(\.indent), [0, 0, 1, 0])
        XCTAssertFalse(TextStyle.read(encoded: list).editable)
        var start = true, counter = 0
        XCTAssertEqual(items.runs.map { NoteRenderer.marked($0, atParagraphStart: &start, counter: &counter) }.joined(), "\u{2611}\u{2002}done\n\u{2610}\u{2002}todo\n1.\u{2002}first\n\u{2022}\u{2002}dot")
        XCTAssertTrue(TextStyle.read(encoded: TextStyle.newBody.body("plain\ntext").text).editable)
        // Read and written back, the lists are the same bytes.
        let stored = NoteText(encoded: list)
        XCTAssertEqual(stored.encoded().text.decodedBase64, list.decodedBase64)
    }

    /// Every real stroke, decoded and written again, is the same bytes.
    func testStrokesReencodeByteForByte() throws {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("strokes")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "bin" }
        XCTAssertEqual(files.count, 5)
        for file in files {
            let original = try Data(contentsOf: file)
            let stroke = try StrokeDecoder.decode(original)
            func integer<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
                original.subdata(in: offset..<offset + MemoryLayout<T>.size).withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
            }
            let again = StrokeEncoder.encode(stroke, modifiedMicros: integer(72, Int64.self), drawnMicros: integer(117, Int64.self),
                                             pageWidth: Int(integer(125, UInt32.self)), pageHeight: Int(integer(129, UInt32.self)))
            XCTAssertEqual(again, original, file.lastPathComponent)
            XCTAssertEqual(StrokeEncoder.bounds(of: stroke.points), stroke.bounds, file.lastPathComponent)
        }
    }

    func testAStrokeDrawnHereDecodesAsDrawn() throws {
        let drawn = (0..<40).map { InkPoint(x: 100.3 + Double($0) * 3.37, y: 200.9 + sin(Double($0) / 4) * 41.2, pressure: 1, time: $0 * 16) }
        let points = StrokeEncoder.quantized(drawn)
        var stroke = InkStroke(id: UUID().uuidString.lowercased(), bounds: StrokeEncoder.bounds(of: points), points: points)
        stroke.argb = 0xFF20_5CF5
        stroke.penSize = 6
        stroke.penNameID = 0
        let decoded = try StrokeDecoder.decode(StrokeEncoder.encode(stroke, modifiedMicros: 1_791_680_000_000_000, drawnMicros: 1_791_679_999_000_000, pageWidth: 848, pageHeight: 1200))
        XCTAssertEqual(decoded.id, stroke.id)
        XCTAssertEqual(decoded.points.map(\.x), points.map(\.x))
        XCTAssertEqual(decoded.points.map(\.y), points.map(\.y))
        XCTAssertEqual(decoded.points.map(\.time), points.map(\.time))
        XCTAssertEqual(decoded.argb, 0xFF20_5CF5)
        XCTAssertEqual(decoded.penSize, 6)
        XCTAssertEqual(decoded.bounds, stroke.bounds)
        // No point strays from where it was drawn by more than the format's step.
        for (a, b) in zip(points, drawn) { XCTAssertLessThan(hypot(a.x - b.x, a.y - b.y), 0.05) }
    }

    /// Every text object in the fixtures, and in the capture where it is at hand, reads into a
    /// `NoteText` and writes back as the very same encoding and span list.
    func testStoredTextRoundTripsExactly() throws {
        var documents: [(String, Data)] = []
        for name in ["create-text-windows.multipart", "create-ink-windows.multipart", "update-image-painting-windows.multipart", "downsync-ink-phone.multipart"] {
            if let part = Multipart.parse(try fixture(name)).first { documents.append((name, part.body)) }
        }
        let flows = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../captures/s1-first-launch/flows.jsonl").standardizedFileURL
        if let text = try? String(contentsOf: flows, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.contains("samsungnotes/v1/notes") {
                guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                for side in ["request_body", "response_body"] {
                    guard let body = record[side] as? [String: Any], let raw = (body["text"] as? String).map({ Data($0.utf8) }) ?? (body["b64"] as? String).flatMap({ Data(base64Encoded: $0) }),
                          let part = Multipart.parse(raw).first(where: { $0.name == "noteResource" }) else { continue }
                    documents.append(("capture \(record["seq"] ?? 0)", part.body))
                }
            }
        }
        var checked = 0, styled = 0
        for (name, data) in documents {
            guard let root = try? XMLTree.parse(data) else { continue }
            for object in root.descendants("object") {
                guard let encoded = object.value("text"), !encoded.isEmpty else { continue }
                let list = object.child("spanOrderDataList")?.all("spanOrderData").compactMap { $0["val"]?.decodedBase64 } ?? []
                let text = NoteText(encoded: encoded, spanList: list)
                let again = text.encoded()
                if again.text.decodedBase64 != encoded.decodedBase64 || again.spanList != list {
                    func shape(_ s: String?) -> String {
                        var out = "", rest = Substring(s ?? "")
                        while !rest.isEmpty {
                            if rest.hasPrefix("<?a"), let end = rest.range(of: "?>") { out += rest[..<end.upperBound]; rest = rest[end.upperBound...]; continue }
                            let next = rest.range(of: "<?a")?.lowerBound ?? rest.endIndex
                            let n = Data(base64Encoded: String(rest[..<next])).flatMap { String(data: $0, encoding: .utf8) }.map { t in "[\(t.utf16.count)\(t.contains("\n") ? " nl@\(t.utf16.firstIndex(of: 10).map { t.utf16.distance(from: t.utf16.startIndex, to: $0) } ?? -1)" : "")]" } ?? "[?\(rest[..<next].count)]"
                            out += n; rest = rest[next...]
                        }
                        return out
                    }
                    print("SHAPE want:", shape(encoded.decodedBase64)); print("SHAPE  got:", shape(again.text.decodedBase64)); print("SHAPE list want:", list.map { $0.split(separator: ",").prefix(3).joined(separator: ",") }, "got:", again.spanList.map { $0.split(separator: ",").prefix(3).joined(separator: ",") })
                }
                XCTAssertEqual(again.text.decodedBase64, encoded.decodedBase64, name)
                XCTAssertEqual(again.spanList, list, name)
                XCTAssertEqual(text.paragraphs.count, text.string.components(separatedBy: "\n").count, name)
                checked += 1
                if text.spans.count > 3 { styled += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 2)
        print("NoteText round trips: \(checked) texts, \(styled) with more than three spans")
    }

    func testTextTypedHereAndPicturesInIt() throws {
        let file = NoteFile.newTextNote(title: "", body: "", now: Date(timeIntervalSince1970: 1_791_700_000))
        var text = NoteText.uniform("first\nsecond", like: nil, body: true)
        XCTAssertEqual(text.encoded().text, TextStyle.newBody.body("first\nsecond").text, "the general writer agrees with the plain one")
        text.appendObject(id: "4a3deb78-c50b-11f1-a335-8f1f85ec7632")
        file.setBodyText(text)
        let back = file.bodyText
        XCTAssertEqual(back.string, "first\nsecond\n\u{FFFC}")
        XCTAssertEqual(back.objectIDs, ["4a3deb78-c50b-11f1-a335-8f1f85ec7632"])
        XCTAssertEqual(back.plain, "first\nsecond\n")
        XCTAssertEqual(back, NoteText(encoded: back.encoded().text, spanList: back.encoded().spanList))
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(XMLTree.parse(Data(file.treeDocument().utf8)))))
        // A picture alone, as the Windows client writes a note that holds nothing else.
        var alone = NoteText(hasSection: true)
        alone.appendObject(id: "4a3deb78-c50b-11f1-a335-8f1f85ec7632")
        XCTAssertEqual(alone.encoded().text.decodedBase64, "<?a 'span/foregroundColor'='1,-14342875' 'span/backgroundColor'='1,0' 'span/fontSize'='1,12' 'objectSpan/objectSpan'='4a3deb78-c50b-11f1-a335-8f1f85ec7632,0,0' 'paragraph/alignment'='0' 'paragraph/parsingState'='False' 'sectionData/sectionData'='1'?>77+8<?a 'span/foregroundColor' 'span/backgroundColor' 'span/fontSize' 'objectSpan/objectSpan' 'paragraph/alignment' 'paragraph/parsingState' 'sectionData/sectionData'?><?a 'sectionData/sectionData'='0' 'sectionData/sectionData'?>")
        XCTAssertEqual(alone.encoded().spanList, ["1,0,1,1,-14342875", "17,0,1,1,0", "3,0,1,1,12"])
    }

    func testGzipRoundTrips() throws {
        let data = Data((0..<5000).map { UInt8($0 % 251) })
        XCTAssertEqual(Gzip.decompress(try XCTUnwrap(Gzip.compress(data))), data)
    }

    func testRenderingProducesPictures() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalStore(root: folder)
        let parts = Multipart.parse(try fixture("downsync-ink-phone.multipart"))
        var strokes: [String: Data] = [:]
        for part in parts where part.name == "strokeResource" { strokes[String(part.filename!.split(separator: "_")[0])] = part.body }
        let record = try store.ingest(serverID: "s", commitID: "c", deviceName: "phone", xml: parts[0].body, strokes: strokes)
        XCTAssertTrue(record.hasInk)
        let note = try store.load(record.id)
        XCTAssertEqual(note.strokes.count, 2)
        XCTAssertEqual(note.strokes.values.first?.penName, "com.samsung.android.sdk.pen.pen.preload.FountainPen")
        let thumbnail = try XCTUnwrap(NoteRenderer.thumbnail(note, side: 200, dark: false))
        XCTAssertEqual(thumbnail.width, 200)
        XCTAssertNotNil(NoteRenderer.pageImage(note, page: 0, pixelWidth: 400, dark: true) { _ in nil })
    }
}
