import XCTest
@testable import SamsungNotesKit

final class NoteContentTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_700_000)

    /// The three uploads in the capture share one mask, which is what the formula predicts:
    /// key = file hash XOR SHA-256(token).
    func testValidationKey() throws {
        let samples = [
            ("9ed308055102c39f02c794a6b05ca63a6d2715dda5ebcd50336779cc277694c8", "8b945f075252c3f6941ed4889b079a57b060c0a077fcda0c8342352797bf95e1"),
            ("4194cf35d03ebec5af1e22c78412dcb9d52db90f006405d9626c0878c181da64", "54d39837d36ebeac39c762e9af49e0d4086a6c72d2731285d24944937148db4d"),
            ("f086c4020575f57806aab80862f85cea22166fc7f30cc2acce45434298570a44", "e5c193000625f5119073f82649a36087ff51baba211bd5f07e600fa9289e0b6d"),
        ]
        let masks = try samples.map { hash, key in
            NoteHash.hex(Data(zip(try XCTUnwrap(AccountCrypto.data(hex: hash)), try XCTUnwrap(AccountCrypto.data(hex: key))).map { $0 ^ $1 }))
        }
        XCTAssertEqual(Set(masks), ["154757020350006996d9402e2b5b3c6ddd47d57dd217175cb0254cebb0c90129"])
        let key = try XCTUnwrap(NotesAPI.validationKey(fileHash: samples[0].0, token: "token"))
        let mask = NoteHash.digest(Data("token".utf8))
        XCTAssertEqual(key, NoteHash.hex(Data(zip(try XCTUnwrap(AccountCrypto.data(hex: samples[0].0)), mask).map { $0 ^ $1 })))
        XCTAssertNil(NotesAPI.validationKey(fileHash: "nonsense", token: "token"))
    }

    func testPictureInTextIsWrittenAsTheWindowsClientWritesIt() throws {
        let file = NoteFile.newTextNote(title: "", body: "", now: now)
        let hash = "9ed308055102c39f02c794a6b05ca63a6d2715dda5ebcd50336779cc277694c8"
        XCTAssertEqual(file.fittedSize(CGSize(width: 1080, height: 2400)), CGSize(width: 222.75, height: 495))
        let id = file.addImage(fileHash: hash, fileExtension: "jpg", size: CGSize(width: 222.75, height: 495), top: 23.5565796, now: now)
        let root = try XMLTree.parse(Data(file.uploadDocument(pages: true, body: true).utf8))
        XCTAssertEqual(root.children.map(\.name), ["noteTree", "contentFileList", "attributes", "pageList", "floatingObjectList", "bodyText"])
        XCTAssertEqual(root.child("noteTree")?.children.map(\.name), ["pageList", "contentFileList", "floatingObjectList", "bodyText"])
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(root.child("noteTree"))))
        let object = try XCTUnwrap(root.child("floatingObjectList")?.child("object"))
        XCTAssertEqual(object["type"], "image")
        XCTAssertEqual(object["id"], id)
        XCTAssertEqual(object["layoutType"], "2")
        XCTAssertEqual(object["hash"], NoteHash.object(id: id, time: object["modifiedTime"] ?? ""))
        XCTAssertEqual(root.child("noteTree")?.child("floatingObjectList")?.child("object")?["h"], object["hash"])
        // The geometry, as captured for a picture of this size at this place.
        XCTAssertEqual(object.child("rect")?.attributes, ["l": "37.6888885", "t": "23.5565796", "r": "260.438904", "b": "518.55658"])
        XCTAssertEqual(object.child("originalRect")?.attributes, object.child("rect")?.attributes)
        let points = object.child("connectionPointList")?.all("point").map { "\($0["x"] ?? ""),\($0["y"] ?? "")" }
        XCTAssertEqual(points, ["149.063903808594,23.5565795898438", "260.438903808594,271.056579589844", "149.063903808594,518.556579589844", "37.6888885498047,271.056579589844"])
        let segments = object.child("path")?.child("segmentList")?.all("segment").map { "\($0["type"] ?? "") \($0["x"] ?? "") \($0["y"] ?? "")" }
        XCTAssertEqual(segments, ["1 37.6888885 23.5565796", "2 260.438904 23.5565796", "2 260.438904 518.55658", "2 37.6888885 518.55658", "6  "])
        XCTAssertEqual(object.child("fillEffect")?["imageId"], hash)
        XCTAssertEqual(object.child("fillEffect")?["ninePatchWidth"], "848")
        XCTAssertEqual(object.children.map(\.name), ["rect", "connectionPointList", "lineColorEffect", "lineStyleEffect", "originalRect", "path", "fillEffect"])
        // The file's entry, in full and in the tree.
        let entry = try XCTUnwrap(root.child("contentFileList")?.child("contentFile"))
        XCTAssertEqual(entry["id"], hash)
        XCTAssertEqual(entry["bindNumber"], "0")
        XCTAssertEqual(entry["refCount"], "1")
        XCTAssertEqual(entry.value("fileHash"), hash)
        XCTAssertTrue(entry["name"]?.decodedBase64?.hasPrefix("0@image_") == true)
        XCTAssertTrue(entry["name"]?.decodedBase64?.hasSuffix(".jpg") == true)
        XCTAssertEqual(root.child("noteTree")?.child("contentFileList")?.child("contentFile")?["h"], entry["hash"])
        // Its place in the text.
        XCTAssertEqual(file.bodyText.objectIDs, [id])
        XCTAssertEqual(file.bodyText.string, "\u{FFFC}")
        // What the reader makes of it.
        let document = try NoteDocument(xml: file.data())
        XCTAssertEqual(document.floating.first?.kind, .image)
        XCTAssertEqual(document.floating.first?.imageID, hash)
        XCTAssertEqual(document.firstImage, hash)
        XCTAssertEqual(document.files.map(\.id), [hash])

        // A second file takes the next number; an update sends only what the service asks for.
        let second = file.addImage(fileHash: String(repeating: "ab", count: 32), fileExtension: "png", size: CGSize(width: 100, height: 50), now: now.addingTimeInterval(5))
        let update = try XMLTree.parse(Data(file.uploadDocument(pages: false, body: true, files: [String(repeating: "ab", count: 32)], floating: [second]).utf8))
        XCTAssertEqual(update.child("contentFileList")?.all("contentFile").map { $0["bindNumber"] ?? "" }, ["1"])
        XCTAssertEqual(update.child("floatingObjectList")?.all("object").compactMap { $0["id"] }, [second])
        XCTAssertEqual(update.child("noteTree")?.child("floatingObjectList")?.all("object").count, 2)
        XCTAssertNil(update.child("pageList"))
        XCTAssertEqual(file.bodyText.string, "\u{FFFC}\n\u{FFFC}")

        // Taking the first picture out takes its file and its place in the text along.
        XCTAssertEqual(file.removeFloating([id], now: now.addingTimeInterval(9)), [id])
        XCTAssertEqual(file.fileIDs, [String(repeating: "ab", count: 32)])
        XCTAssertEqual(file.bodyText.objectIDs, [second])
        XCTAssertEqual(file.bodyText.string, "\u{FFFC}")
        XCTAssertTrue(file.setFloatingRect(second, CGRect(x: 10, y: 20, width: 300, height: 150), now: now.addingTimeInterval(12)))
        XCTAssertEqual(try NoteDocument(xml: file.data()).floating.first?.rect, CGRect(x: 10, y: 20, width: 300, height: 150))
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(XMLTree.parse(Data(file.treeDocument().utf8)))))
        file.removeFloating([second])
        XCTAssertNil(try XMLTree.parse(Data(file.uploadDocument(pages: true, body: true).utf8)).child("floatingObjectList"))
        XCTAssertTrue(file.bodyText.isEmpty)
    }

    func testPages() throws {
        let file = NoteFile.newTextNote(title: "T", body: "b", now: now)
        func ids() -> [String] { (try? NoteDocument(xml: file.data()).pages.map(\.id)) ?? [] }
        func tree() throws -> SamsungNotesKit.XMLNode { try XMLTree.parse(Data(file.treeDocument().utf8)) }
        let before = ids()
        XCTAssertEqual(file.addPage(now: now.addingTimeInterval(1)), 2)
        XCTAssertEqual(file.pageCount, 3)
        XCTAssertEqual(file.attributes["height"], "3616")
        XCTAssertEqual(Array(ids().prefix(2)), before)
        XCTAssertEqual(try tree().child("pageList")?.all("page").compactMap { $0["id"] }, ids())
        XCTAssertTrue(NoteHash.verify(tree: try tree()))
        XCTAssertEqual(file.addPage(after: 0, now: now.addingTimeInterval(2)), 1)
        XCTAssertEqual(ids().count, 4)
        XCTAssertEqual(ids()[0], before[0])
        XCTAssertEqual(ids()[2], before[1])
        // Ink on the new page, then the page moves and goes.
        file.addStrokes([("s1", 1_791_700_003_000_000, CGRect(x: 1, y: 2, width: 30, height: 40))], page: 1, argb: 0xFF00_0000, penSize: 6, now: now.addingTimeInterval(3))
        let inked = ids()[1]
        XCTAssertTrue(file.movePage(1, to: 3, now: now.addingTimeInterval(4)))
        XCTAssertEqual(ids()[3], inked)
        XCTAssertEqual(try tree().child("pageList")?.all("page").compactMap { $0["id"] }, ids())
        XCTAssertTrue(NoteHash.verify(tree: try tree()))
        XCTAssertEqual(file.removePage(3, now: now.addingTimeInterval(5)), ["s1"])
        XCTAssertEqual(ids().count, 3)
        XCTAssertEqual(file.attributes["height"], "3616")
        file.setPageColor(0, 0xFFFF_F4C2, now: now.addingTimeInterval(6))
        XCTAssertEqual(try NoteDocument(xml: file.data()).pages[0].background, 0xFFFF_F4C2)
        XCTAssertTrue(NoteHash.verify(tree: try tree()))
        XCTAssertNotNil(file.removePage(0)); XCTAssertNotNil(file.removePage(0))
        XCTAssertNil(file.removePage(0), "the last page stays")
    }

    func testTypingKeepsTheEncodingTheWindowsClientWrites() throws {
        // Typed character by character, a text comes out as if written in one go.
        var text = NoteText(hasSection: true)
        text.replace(0..<0, with: "h")
        XCTAssertTrue(text.spans.isEmpty, "an empty text has no style of its own yet")
        var typed = NoteText.uniform("h", like: nil, body: true)
        for (offset, character) in "ello\nworld\n\nend".enumerated() { typed.replace((offset + 1)..<(offset + 1), with: String(character)) }
        let whole = TextStyle.newBody.body("hello\nworld\n\nend")
        XCTAssertEqual(typed.encoded().text.decodedBase64, whole.text.decodedBase64)
        XCTAssertEqual(typed.encoded().spanList, whole.spans)
        // Typing in the middle, deleting across lines, replacing everything.
        typed.replace(5..<5, with: ",")
        XCTAssertEqual(typed.string, "hello,\nworld\n\nend")
        typed.replace(3..<9, with: "")
        XCTAssertEqual(typed.string, "helrld\n\nend")
        XCTAssertEqual(typed.encoded().text.decodedBase64, TextStyle.newBody.body("helrld\n\nend").text.decodedBase64)
        typed.replace(0..<typed.length, with: "x\ny")
        XCTAssertEqual(typed.encoded().text.decodedBase64, TextStyle.newBody.body("x\ny").text.decodedBase64)
        typed.replace(0..<0, with: "A")
        XCTAssertEqual(typed.encoded().text.decodedBase64, TextStyle.newBody.body("Ax\ny").text.decodedBase64)
        typed.replace(0..<typed.length, with: "")
        XCTAssertEqual(typed.encoded().text, "")

        // A second colour inside the first stays where it was when text is typed before it.
        var mixed = NoteText.uniform("plain red plain", like: nil, body: true)
        mixed.spans.append(NoteText.Span(key: "span/foregroundColor", value: "3,-51658", start: 6, end: 9))
        mixed.replace(0..<0, with: ">> ")
        XCTAssertEqual(mixed.spans.last.map { [$0.start, $0.end] }, [9, 12])
        mixed.replace(12..<12, with: "der")
        XCTAssertEqual(mixed.spans.last.map { [$0.start, $0.end] }, [9, 15], "typing at the end of a run continues it")
        XCTAssertEqual(mixed.spans.first.map { [$0.start, $0.end] }, [0, mixed.length])
        let again = NoteText(encoded: mixed.encoded().text, spanList: mixed.encoded().spanList)
        XCTAssertEqual(again.string, mixed.string)
        XCTAssertEqual(again.encoded().text, mixed.encoded().text)
        XCTAssertEqual(mixed.encoded().spanList.last, "1,9,15,3,-51658")
    }

    func testFormattingIsWrittenAsTheClientDoes() throws {
        var text = NoteText.uniform("plain bold tail", like: nil, body: true)
        text.setProperty(NoteText.bold, "True", in: 6..<10)
        XCTAssertEqual(text.encoded().spanList, ["1,0,15,1,-14342875", "17,0,15,1,0", "3,0,15,1,12", "5,6,10,3,True"])
        XCTAssertEqual(text.encoded().text.decodedBase64, "<?a 'span/foregroundColor'='1,-14342875' 'span/backgroundColor'='1,0' 'span/fontSize'='1,12' 'paragraph/alignment'='0' 'paragraph/parsingState'='False' 'sectionData/sectionData'='15'?>cGxhaW4g<?a 'span/bold'='3,True'?>Ym9sZA==<?a 'span/bold'?>IHRhaWw=<?a 'span/foregroundColor' 'span/backgroundColor' 'span/fontSize' 'paragraph/alignment' 'paragraph/parsingState' 'sectionData/sectionData'?><?a 'sectionData/sectionData'='0' 'sectionData/sectionData'?>")
        XCTAssertEqual(text.runs.map(\.text), ["plain ", "bold", " tail"])
        XCTAssertEqual(text.runs.map(\.bold), [false, true, false])
        XCTAssertEqual(text.property(NoteText.bold, over: 6..<10), "True")
        XCTAssertNil(text.property(NoteText.bold, over: 4..<10))
        // Typing at the end of the bold run continues it; before it, not.
        text.replace(10..<10, with: "er")
        text.replace(6..<6, with: "(")
        XCTAssertEqual(text.runs.map(\.text), ["plain (", "bolder", " tail"])
        // Taking bold off the middle splits the run; a colour inside the default colour nests.
        text.setProperty(NoteText.bold, nil, in: 9..<11)
        XCTAssertEqual(text.runs.filter(\.bold).map(\.text), ["bo", "er"])
        text.setProperty(NoteText.foreground, "-51658", in: 0..<5)
        XCTAssertEqual(text.runs.first?.color, UInt32(bitPattern: -51658))
        XCTAssertEqual(text.runs.dropFirst().first?.color, UInt32(bitPattern: -14342875))
        XCTAssertTrue(text.encoded().spanList.contains("1,0,5,3,-51658"))
        XCTAssertEqual(text.spans.first?.value, "1,-14342875", "the default colour still spans the whole text")
        // A colour across the edge of another cuts that one back; the same colour again changes nothing.
        text.setProperty(NoteText.foreground, "-16776961", in: 3..<8)
        XCTAssertEqual(text.spans.filter { $0.key == NoteText.foreground }.map { "\($0.start)-\($0.end)" }, ["0-18", "0-3", "3-8"])
        let before = text
        text.setProperty(NoteText.foreground, "-16776961", in: 4..<7)
        XCTAssertEqual(text, before)
        // The whole text in a new size replaces the default span rather than nesting in it.
        text.setProperty(NoteText.fontSize, "20", in: 0..<text.length)
        XCTAssertEqual(text.spans.filter { $0.key == NoteText.fontSize }.map(\.value), ["1,20"])
        // Everything written reads back the same.
        let again = NoteText(encoded: text.encoded().text, spanList: text.encoded().spanList)
        XCTAssertEqual(again.encoded().text.decodedBase64, text.encoded().text.decodedBase64)
        XCTAssertEqual(again.encoded().spanList, text.encoded().spanList)
        XCTAssertEqual(again.runs, text.runs)
    }

    func testListsAndParagraphs() throws {
        var text = NoteText.uniform("shopping\nmilk\neggs\n\ndone", like: nil, body: true)
        XCTAssertEqual(text.paragraphs(touching: 0..<0), 0...0)
        XCTAssertEqual(text.paragraphs(touching: 9..<9), 1...1, "a caret after a line break is in the new paragraph")
        XCTAssertEqual(text.paragraphs(touching: 9..<14), 1...1, "a selection ending after the break stays in its line")
        XCTAssertEqual(text.paragraphs(touching: 10..<16), 1...2)
        XCTAssertEqual(text.paragraphRange(2), 14..<18)
        for index in 1...2 { text.setMark(.number, index) }
        text.setMark(.checkbox(checked: true), 4)
        text.setIndentLevel(1, 2)
        text.setAlignment(2, 0)
        XCTAssertEqual(text.paragraphs[1], [NoteText.Attribute("paragraph/bullet", "4,1"), NoteText.Attribute("paragraph/parsingState", "False")])
        XCTAssertEqual(text.paragraphs[2], [NoteText.Attribute("paragraph/indentLevel", "1,1"), NoteText.Attribute("paragraph/bullet", "4,1"), NoteText.Attribute("paragraph/parsingState", "False")])
        text.setIndentLevel(0, 2)
        XCTAssertEqual(text.paragraphValue(NoteText.bullet, 2), "4,2", "numbers follow along a run of numbered lines")
        XCTAssertEqual(text.paragraphs[0].first, NoteText.Attribute("paragraph/alignment", "2"))
        XCTAssertEqual(text.mark(4), .checkbox(checked: true))
        let stream = try XCTUnwrap(text.encoded().text.decodedBase64)
        XCTAssertTrue(stream.contains("<?a 'paragraph/alignment' 'paragraph/parsingState' 'paragraph/bullet'='4,1' 'paragraph/parsingState'='False'?>"), stream)
        XCTAssertTrue(stream.contains("<?a 'paragraph/parsingState' 'paragraph/bullet'='2,True' 'paragraph/parsingState'='False'?>"), stream)
        let again = NoteText(encoded: text.encoded().text, spanList: text.encoded().spanList)
        XCTAssertEqual(again.paragraphs, text.paragraphs)
        XCTAssertEqual(again.runs.map(\.bullet), text.runs.map(\.bullet))
        XCTAssertEqual(again.runs.compactMap(\.bullet), [.number(1), .number(2), .checkbox(checked: true)])
        // A new line typed in a list is a list line too; joining lines drops the second's marks.
        text.replace(13..<13, with: "\nbread")
        XCTAssertEqual(text.mark(2), .number)
        text.renumber()
        XCTAssertEqual((1...3).map { text.paragraphValue(NoteText.bullet, $0) ?? "" }, ["4,1", "4,2", "4,3"])
        text.replace(8..<9, with: " ")
        XCTAssertEqual(text.mark(0), .none)
        XCTAssertEqual(text.alignment(0), 2)
        XCTAssertEqual(text.paragraphs.count, text.paragraphStarts.count)
        // A span over no text is kept in the span list, where the client put it.
        let pending = NoteText(encoded: NoteText.uniform("ab", like: nil, body: true).encoded().text, spanList: ["1,0,2,1,-14342875", "5,2,2,3,True", "17,0,2,1,0", "3,0,2,1,12"])
        XCTAssertEqual(pending.zeroLength, [NoteText.ZeroLength(index: 1, line: "5,2,2,3,True")])
        XCTAssertEqual(pending.encoded().spanList, ["1,0,2,1,-14342875", "5,2,2,3,True", "17,0,2,1,0", "3,0,2,1,12"])
    }

    func testFormattedTextAndPicturesAreSavedTogether() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-rich-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalStore(root: folder)
        let edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "", body: "")
        var body = NoteText.uniform("Heading\nfirst line\nsecond line", like: nil, body: true)
        body.setProperty(NoteText.bold, "True", in: 0..<7)
        body.setMark(.dot, 1); body.setMark(.dot, 2)
        var title = NoteText.uniform("Trip", like: nil, body: false)
        try edits.saveRich(id, title: title, body: body)
        var library = store.loadLibrary()
        XCTAssertEqual(library.notes[id]?.title, "Trip")
        XCTAssertEqual(library.nodes[id]?.name, "Trip")
        XCTAssertEqual(library.notes[id]?.fullText, "Heading\nfirst line\nsecond line")
        let revision = library.notes[id]?.revision
        try edits.saveRich(id, title: title, body: body)
        XCTAssertEqual(store.loadLibrary().notes[id]?.revision, revision, "saving the same again changes nothing")
        let stored = try XCTUnwrap(edits.richText(id))
        XCTAssertEqual(stored.body, body)
        XCTAssertEqual(stored.title.string, "Trip")

        // A picture goes below the text; text typed above it pushes it down.
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let object = try XCTUnwrap(try edits.addImage(id, data: picture, fileExtension: "jpg", pixelSize: CGSize(width: 300, height: 200)))
        var document = try store.load(id).document
        let first = try XCTUnwrap(document.floating.first)
        XCTAssertTrue(first.inText)
        XCTAssertEqual(first.rect.minX, 16 * 848.0 / 360, accuracy: 0.01)
        XCTAssertGreaterThan(first.rect.minY, 3 * 12 * 848.0 / 360, "below three lines of text")
        XCTAssertEqual(first.rect.width, 300, accuracy: 0.001)
        XCTAssertEqual(first.rect.height, 200, accuracy: 0.001)
        var longer = try XCTUnwrap(edits.richText(id)).body
        XCTAssertEqual(longer.objectIDs, [object])
        longer.replace(0..<0, with: "One more line\nand another\n")
        try edits.saveRich(id, title: nil, body: longer)
        document = try store.load(id).document
        XCTAssertGreaterThan(try XCTUnwrap(document.floating.first).rect.minY, first.rect.minY + 40)
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(XMLTree.parse(Data(try store.noteFile(id).treeDocument().utf8)))))

        // Text long enough to run off the last page adds pages.
        var long = longer
        long.replace(long.length..<long.length, with: String(repeating: "\nline", count: 90))
        try edits.saveRich(id, title: nil, body: long)
        XCTAssertGreaterThan(try store.load(id).document.pages.count, 2)
        XCTAssertEqual(store.loadLibrary().notes[id]?.pagesChanged, true)

        // Deleting the picture's place in the text deletes the picture and its file's entry.
        var without = long
        XCTAssertTrue(without.removeObjects([object]))
        try edits.saveRich(id, title: nil, body: without)
        document = try store.load(id).document
        XCTAssertTrue(document.floating.isEmpty)
        XCTAssertTrue(document.files.isEmpty)
        title.replace(4..<4, with: " notes")
        try edits.saveRich(id, title: title, body: nil)
        library = store.loadLibrary()
        XCTAssertEqual(library.notes[id]?.title, "Trip notes")
    }

    /// The file entries the Windows client wrote in the capture, hashed again.
    func testContentFileHash() {
        XCTAssertEqual(NoteHash.contentFile(id: "9ed308055102c39f02c794a6b05ca63a6d2715dda5ebcd50336779cc277694c8", bindNumber: 0, name: "0@image_01305fa6-ed4c-4de3-bb9f-11714ba4ed75.jpg", refCount: 1, time: "1791678770627291"),
                       "272f8232117c0fbbbfee025089cf4edb394092d91cc79ef80c36f918829721e8")
        XCTAssertEqual(NoteHash.contentFile(id: "4194cf35d03ebec5af1e22c78412dcb9d52db90f006405d9626c0878c181da64", bindNumber: 2, name: "2@639272791996022246.spp", refCount: 1, time: "1791678799843370"),
                       "e8bb24851c900dcc355a108fe01b29cf318b392c5c091abf81f6938424e74ff1")
        XCTAssertEqual(NoteHash.contentFile(id: "f086c4020575f57806aab80862f85cea22166fc7f30cc2acce45434298570a44", bindNumber: 1, name: "1@639272791996022246.png", refCount: 1, time: "1791678799825404"),
                       "7cf7c5b6750db3e374f440b4b829028aaa634ad58da6d3de5b4a3be2d487fe45")
        // What this client writes follows the same rule, also after a file gains a second use.
        let file = NoteFile.newTextNote(title: "", body: "", now: now)
        let hash = String(repeating: "cd", count: 32)
        file.addFile(hash: hash, name: "image_x.png", now: now)
        file.addFile(hash: hash, name: "image_x.png", now: now.addingTimeInterval(1))
        let entry = file.fileList.child("contentFile")
        XCTAssertEqual(entry?["refCount"], "2")
        XCTAssertEqual(entry?["hash"], NoteHash.contentFile(id: hash, bindNumber: 0, name: "0@image_x.png", refCount: 2, time: entry?["modifiedTime"] ?? ""))
        XCTAssertEqual(file.treeFileList.child("contentFile")?["h"], entry?["hash"])
    }

    func testPens() throws {
        XCTAssertEqual(Pen.fountain.size(level: 30, pageWidth: 848), 6.00667, accuracy: 0.001)
        XCTAssertEqual(Pen.fountain.size(level: 1, pageWidth: 360), 0.228, accuracy: 1e-9)
        XCTAssertEqual(Pen.highlighter.size(level: 100, pageWidth: 360), 12.908, accuracy: 1e-9)
        XCTAssertEqual(Pen.highlighter.ink(0xFFFF_CB30), 0x73FF_CB30)
        XCTAssertEqual(Pen.fountain.ink(0x0025_2525), 0xFF25_2525)
        XCTAssertEqual(Pen.kind(named: "com.samsung.android.sdk.pen.pen.preload.Marker2"), .highlighter)
        XCTAssertEqual(Pen.kind(named: "com.samsung.android.sdk.pen.pen.preload.ObliquePen"), .calligraphy)
        XCTAssertEqual(Pen.kind(named: nil), .fountain)
        // A highlighter stroke keeps its pen, its setting and its see-through colour through a save.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-pens-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalStore(root: folder)
        let edits = LocalEdits(store: store)
        let id = try edits.createTextNote(title: "", body: "")
        let points = (0..<12).map { InkPoint(x: 100 + Double($0) * 9.3, y: 200 + Double($0 % 3), pressure: 1, time: $0 * 8) }
        let size = Pen.highlighter.size(level: 50, pageWidth: 848)
        let saved = try edits.addStrokes(id, page: 0, strokes: [
            NewStroke(points: points, argb: Pen.highlighter.ink(0xFFFF_CB30), penSize: size, pen: .highlighter),
            NewStroke(points: points, argb: 0xFF14_47FF, penSize: 6, pen: .fountain),
        ])
        XCTAssertEqual(saved.count, 2)
        let note = try store.load(id)
        let marker = try XCTUnwrap(note.strokes[saved[0].id]), ink = try XCTUnwrap(note.strokes[saved[1].id])
        XCTAssertEqual(marker.pen, .highlighter)
        XCTAssertEqual(marker.setting, "8;")
        XCTAssertEqual(marker.argb, 0x73FF_CB30)
        XCTAssertEqual(marker.penSize, size, accuracy: 0.001)
        XCTAssertEqual(marker.points.count, 12)
        XCTAssertEqual(ink.pen, .fountain)
        XCTAssertEqual(ink.setting, "18;0;100;")
        XCTAssertEqual(Set(note.document.penNames.values), [Pen.highlighter.name, "8;", Pen.fountain.name, "18;0;100;"])
        // The pen without a tolerance writes a record four bytes shorter and says so in its field mask.
        let withIt = StrokeEncoder.encode(ink, modifiedMicros: 1, drawnMicros: 0, pageWidth: 848, pageHeight: 1200, settingID: 1, tolerance: 2.6)
        let without = StrokeEncoder.encode(ink, modifiedMicros: 1, drawnMicros: 0, pageWidth: 848, pageHeight: 1200, settingID: 1, tolerance: nil)
        XCTAssertEqual(withIt.count - without.count, 4)
        XCTAssertEqual(try StrokeDecoder.decode(without).points.count, 12)
        XCTAssertEqual(try StrokeDecoder.decode(without).argb, 0xFF14_47FF)
    }

    func testTypingOverASelectionTakesTheStyleOfItsFirstCharacter() {
        var text = NoteText.uniform("plain bold plain", like: nil, body: true)
        text.setProperty(NoteText.bold, "True", in: 6..<10)
        text.setProperty(NoteText.foreground, "-51658", in: 11..<16)
        var typed = text
        typed.replace(0..<16, with: "new")
        XCTAssertEqual(typed.runs.map(\.text), ["new"])
        XCTAssertEqual(typed.runs.first?.bold, false)
        XCTAssertEqual(typed.runs.first?.color, UInt32(bitPattern: -14342875))
        XCTAssertEqual(typed.encoded().text.decodedBase64, TextStyle.newBody.body("new").text.decodedBase64)
        // Starting inside the bold run: the new text is bold, and the red run begins after it.
        typed = text
        typed.replace(8..<13, with: "XY")
        XCTAssertEqual(typed.string, "plain boXYain")
        XCTAssertEqual(typed.runs.map(\.text), ["plain ", "boXY", "ain"])
        XCTAssertEqual(typed.runs.map(\.bold), [false, true, false])
        XCTAssertEqual(typed.runs.last?.color, UInt32(bitPattern: -51658))
        let again = NoteText(encoded: typed.encoded().text, spanList: typed.encoded().spanList)
        XCTAssertEqual(again.encoded().text, typed.encoded().text)
        // Emoji are two units each; offsets count units.
        var faces = NoteText.uniform("a\u{1F600}b", like: nil, body: true)
        faces.replace(1..<3, with: "\u{1F601}")
        XCTAssertEqual(faces.string, "a\u{1F601}b")
        XCTAssertEqual(faces.length, 4)
        // Return after a ticked box starts an unticked one.
        var list = NoteText.uniform("done", like: nil, body: true)
        list.setMark(.checkbox(checked: true), 0)
        list.replace(4..<4, with: "\nnext")
        XCTAssertEqual(list.mark(0), .checkbox(checked: true))
        XCTAssertEqual(list.mark(1), .checkbox(checked: false))
        // A dot is kept as the shortest stroke.
        XCTAssertEqual(LocalEdits.prepared(NewStroke(points: [InkPoint(x: 5, y: 5)], argb: 0xFF00_0000, penSize: 3))?.points.count, 2)
    }
}
