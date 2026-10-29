import XCTest
@testable import SamsungNotesKit

/// Cropping, the note's paper, recordings and what else the note style and the picture's menu write.
final class NoteStyleTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_800_000)
    let picture = "9ed308055102c39f02c794a6b05ca63a6d2715dda5ebcd50336779cc277694c8"

    private func object(_ file: NoteFile, _ id: String) throws -> SamsungNotesKit.XMLNode {
        try XCTUnwrap(file.root.descendants("object").first { $0["id"] == id && $0["type"] != nil })
    }

    private func corners(_ node: SamsungNotesKit.XMLNode?) -> [String] { ["l", "t", "r", "b"].map { node?[$0] ?? "?" } }

    /// A crop as Samsung's clients keep it: the visible part as `rect`, the part in pixels of
    /// the file as `cropRect`, the frame of the whole picture as `imageOriginalRect`.
    func testCropIsWrittenAsTheClientsKeepIt() throws {
        let file = NoteFile.newTextNote(title: "", body: "", now: now)
        let id = file.addImage(fileHash: picture, fileExtension: "png", size: CGSize(width: 400, height: 200), placement: .onPage(0, CGRect(x: 100, y: 300, width: 400, height: 200)), now: now)
        // The right half and the lower half of a picture 1000 by 500 pixels: its quarter at the bottom right.
        let part = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        XCTAssertTrue(file.setFloatingCrop(id, crop: part, pixels: CGSize(width: 1000, height: 500), rect: CGRect(x: 300, y: 400, width: 200, height: 100), now: now.addingTimeInterval(1)))
        let cropped = try object(file, id)
        XCTAssertEqual(corners(cropped.child("rect")), ["300", "400", "500", "500"])
        XCTAssertEqual(corners(cropped.child("cropRect")), ["500", "250", "1000", "500"])
        XCTAssertEqual(corners(cropped.child("imageOriginalRect")), ["100", "300", "500", "500"])
        // The crop comes after the shape's own parts and before the whole picture's frame.
        let names = cropped.children.map(\.name)
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "fillEffect")), try XCTUnwrap(names.firstIndex(of: "cropRect")))
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "cropRect")), try XCTUnwrap(names.firstIndex(of: "imageOriginalRect")))
        // The file that fills it is the same: nothing was cut from it.
        XCTAssertEqual(cropped.child("fillEffect")?["imageId"], picture)
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))

        // Read back, the part shown is known in fractions of the whole picture.
        var document = try NoteDocument(xml: file.data())
        var read = try XCTUnwrap(document.floating.first { $0.id == id })
        XCTAssertEqual(read.cropPixels, CGRect(x: 500, y: 250, width: 500, height: 250))
        let crop = try XCTUnwrap(read.crop)
        for (found, wanted) in zip([crop.minX, crop.minY, crop.width, crop.height], [0.5, 0.5, 0.5, 0.5]) { XCTAssertEqual(found, wanted, accuracy: 0.001) }

        // Moved and made twice as large, the whole picture's frame follows; the pixels stay.
        XCTAssertTrue(file.setFloatingRect(id, CGRect(x: 10, y: 20, width: 400, height: 200), now: now.addingTimeInterval(2)))
        let moved = try object(file, id)
        XCTAssertEqual(corners(moved.child("cropRect")), ["500", "250", "1000", "500"])
        XCTAssertEqual(corners(moved.child("imageOriginalRect")), ["-390", "-180", "410", "220"])
        document = try NoteDocument(xml: file.data())
        read = try XCTUnwrap(document.floating.first { $0.id == id })
        XCTAssertEqual(try XCTUnwrap(read.crop).width, 0.5, accuracy: 0.001)

        // All of it again: both parts go.
        XCTAssertTrue(file.setFloatingCrop(id, crop: nil, pixels: CGSize(width: 1000, height: 500), rect: CGRect(x: 10, y: 20, width: 800, height: 400), now: now.addingTimeInterval(3)))
        let whole = try object(file, id)
        XCTAssertNil(whole.child("cropRect"))
        XCTAssertNil(whole.child("imageOriginalRect"))
        XCTAssertFalse(try XCTUnwrap(NoteDocument(xml: file.data()).floating.first { $0.id == id }).isCropped)
    }

    /// A picture cut out along a loop shows a copy of itself and keeps the picture it was cut
    /// from; taking the cut back gives that picture again and lets the copy go.
    func testACutOutPictureKeepsItsOriginal() throws {
        let file = NoteFile.newTextNote(title: "", body: "", now: now)
        let id = file.addImage(fileHash: picture, fileExtension: "png", size: CGSize(width: 400, height: 200), now: now)
        let copy = String(repeating: "ab", count: 32)
        XCTAssertTrue(file.setFloatingImage(id, imageID: copy, originalImageID: picture, now: now.addingTimeInterval(1)))
        var shown = try object(file, id)
        XCTAssertEqual(shown.child("fillEffect")?["imageId"], copy)
        XCTAssertEqual(shown["originalImageId"], picture)
        XCTAssertEqual(shown["isTransparency"], "True")
        XCTAssertEqual(Set(file.fileIDs), [picture, copy])
        var read = try XCTUnwrap(NoteDocument(xml: file.data()).floating.first { $0.id == id })
        XCTAssertEqual(read.imageID, copy)
        XCTAssertEqual(read.originalImageID, picture)
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))

        XCTAssertTrue(file.setFloatingImage(id, imageID: picture, originalImageID: nil, now: now.addingTimeInterval(2)))
        shown = try object(file, id)
        XCTAssertEqual(shown.child("fillEffect")?["imageId"], picture)
        XCTAssertNil(shown["originalImageId"])
        XCTAssertEqual(shown["isTransparency"], "False")
        XCTAssertEqual(file.fileIDs, [picture])
        read = try XCTUnwrap(NoteDocument(xml: file.data()).floating.first { $0.id == id })
        XCTAssertNil(read.originalImageID)

        // Deleting a cut-out picture lets both files go.
        file.setFloatingImage(id, imageID: copy, originalImageID: picture, now: now.addingTimeInterval(3))
        file.removeFloating([id], now: now.addingTimeInterval(4))
        XCTAssertEqual(file.fileIDs, [])
    }

    func testTemplatesColoursAndAPictureUnderThePage() throws {
        let file = NoteFile.newTextNote(title: "", body: "", now: now)
        func pages() throws -> [NotePage] { try NoteDocument(xml: file.data()).pages }
        func nodes() -> [SamsungNotesKit.XMLNode] { file.root.descendants("page").filter { $0["width"] != nil } }
        XCTAssertEqual(nodes().count, 2)

        // Every ruling has the number Samsung's clients know it by.
        XCTAssertEqual(PageTemplate.allCases.map(\.code), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15])
        for template in PageTemplate.allCases where template != .blank { XCTAssertEqual(PageTemplate(code: template.code), template) }
        XCTAssertNil(PageTemplate(code: 0))
        XCTAssertNil(PageTemplate(code: 12))
        XCTAssertNil(PageTemplate(code: 16))

        file.setPaper(.template(.gridMedium), now: now.addingTimeInterval(1))
        XCTAssertEqual(nodes().map { $0["templateType"] }, ["5", "5"])
        XCTAssertEqual(try pages().map(\.template), [.gridMedium, .gridMedium])
        file.setPaper(.template(.oxford), page: 0, now: now.addingTimeInterval(2))
        XCTAssertEqual(try pages().map(\.template), [.oxford, .gridMedium])
        file.setPaper(.color(0xFFFF_E984), now: now.addingTimeInterval(3))
        XCTAssertEqual(try pages().map(\.background), [0xFFFF_E984, 0xFFFF_E984])
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))

        // The spare page at the end has the paper of the page before it and is still not shown.
        file.setPaper(.template(.lineWide), now: now.addingTimeInterval(4))
        XCTAssertEqual(NoteLayout.shownPageCount(of: try NoteDocument(xml: file.data())), 1)
        // A page with a ruling of its own is a page someone made: it is shown.
        file.setPaper(.template(.todo), page: 1, now: now.addingTimeInterval(5))
        XCTAssertEqual(NoteLayout.shownPageCount(of: try NoteDocument(xml: file.data())), 2)

        // A picture of one's own: kept as a file of the note, named by the number it is bound under.
        file.setPaper(.picture(hash: picture, fileExtension: "png"), page: 0, now: now.addingTimeInterval(6))
        let first = try XCTUnwrap(nodes().first)
        XCTAssertEqual(first["templateType"], "12")
        XCTAssertEqual(first["bgImageId"], "0")
        XCTAssertEqual(first["bgImageMode"], "2")
        XCTAssertNotNil(first["templateUri"]?.decodedBase64)
        XCTAssertEqual(file.fileIDs, [picture])
        XCTAssertEqual(try pages().first?.backgroundImage, picture)
        XCTAssertNil(try pages().first?.template)
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))

        // A page added after it has the same paper, and the picture is then shown by two pages.
        XCTAssertEqual(file.addPage(after: 0, now: now.addingTimeInterval(7)), 1)
        XCTAssertEqual(try pages().map(\.backgroundImage), [picture, picture, nil])
        file.setPaper(.template(.blank), page: 0, now: now.addingTimeInterval(8))
        XCTAssertEqual(file.fileIDs, [picture], "the second page still shows it")
        file.setPaper(.template(.dotWide), page: 1, now: now.addingTimeInterval(9))
        XCTAssertEqual(file.fileIDs, [])
        XCTAssertEqual(try pages().map(\.template), [nil, .dotWide, .todo])
        XCTAssertNil(nodes().first?["bgImageId"])
        XCTAssertNil(nodes().first?["templateType"])
    }

    func testRecordingsAreWrittenAsTheClientsWriteThem() throws {
        let file = NoteFile.newTextNote(title: "", body: "", now: now)
        let sound = String(repeating: "cd", count: 32)
        file.addRecording(fileHash: sound, fileName: "68eb1c2a_a1b2c.m4a", title: "Voice001", seconds: 83.4, now: now)
        let entry = try XCTUnwrap(file.root.descendant("voiceDataList")?.child("voiceData"))
        XCTAssertEqual(entry["attachFile"], sound)
        XCTAssertEqual(entry["name"]?.decodedBase64, "Voice001")
        XCTAssertEqual(entry["playTime"]?.decodedBase64, "00:01:23")
        XCTAssertEqual(entry["recordingTime"], "83400")
        let made = try XCTUnwrap(entry["createdTime"].flatMap { Int64($0) })
        XCTAssertEqual(made, Int64(now.timeIntervalSince1970 * 1000) - 83_400)
        // When it started and when it stopped, in microseconds.
        let moments = entry.child("propertyList")?.all("property") ?? []
        XCTAssertEqual(moments.map { $0["action"] }, ["1", "4"])
        XCTAssertEqual(moments.first?["timeStamp"], String(made * 1000))
        XCTAssertEqual(moments.last?["timeStamp"], String(Int64(now.timeIntervalSince1970 * 1000) * 1000))
        XCTAssertEqual(file.fileIDs, [sound])
        // It is among the note's attributes, which every upload carries.
        let upload = try XMLTree.parse(Data(file.uploadDocument(pages: false, body: false).utf8))
        XCTAssertNotNil(upload.child("attributes")?.child("voiceDataList"))

        let read = try NoteDocument(xml: file.data()).recordings
        XCTAssertEqual(read, [NoteRecording(id: "0:" + sound, title: "Voice001", file: sound, seconds: 83.4)])
        // A length that is no length does not get in.
        entry.attributes["recordingTime"] = "1e300"
        XCTAssertEqual(try NoteDocument(xml: file.data()).recordings.first?.seconds, 1_000_000)
        entry.attributes["recordingTime"] = nil
        entry.attributes["playTime"] = Data("nan:00".utf8).base64EncodedString()
        XCTAssertEqual(try NoteDocument(xml: file.data()).recordings.first?.seconds, 0)
        // A length that comes only as text is read too.
        XCTAssertEqual(NoteFile.seconds(playTime: "01:02:03"), 3723)
        XCTAssertEqual(NoteFile.seconds(playTime: "02:05"), 125)

        XCTAssertTrue(file.removeRecording(fileHash: sound, now: now.addingTimeInterval(1)))
        XCTAssertNil(file.root.descendant("voiceDataList"))
        XCTAssertEqual(file.fileIDs, [])
        XCTAssertFalse(file.removeRecording(fileHash: sound))
    }

    /// A picture set in the text is freed to lie on its page, and set into the text again.
    func testAnchoringAPicture() throws {
        let file = NoteFile.newTextNote(title: "", body: "one\ntwo", now: now)
        let id = file.addImage(fileHash: picture, fileExtension: "png", size: CGSize(width: 200, height: 100), now: now)
        XCTAssertEqual(file.bodyText.objectIDs, [id])
        XCTAssertTrue(file.setFloatingAnchor(id, inText: false, rect: CGRect(x: 50, y: 60, width: 200, height: 100), page: 0, now: now.addingTimeInterval(1)))
        XCTAssertEqual(try object(file, id)["layoutType"], "3")
        XCTAssertEqual(file.bodyText.string, "one\ntwo")
        XCTAssertEqual(try XCTUnwrap(NoteDocument(xml: file.data()).floating.first).rect, CGRect(x: 50, y: 60, width: 200, height: 100))
        XCTAssertFalse(file.setFloatingAnchor(id, inText: false), "it is free already")
        XCTAssertTrue(file.setFloatingAnchor(id, inText: true, textOffset: 3, now: now.addingTimeInterval(2)))
        XCTAssertEqual(try object(file, id)["layoutType"], "2")
        XCTAssertEqual(file.bodyText.string, "one\n\u{FFFC}\ntwo")
        XCTAssertEqual(file.bodyText.objectIDs, [id])
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))
    }

    /// What other clients put on a page and this one cannot make: it is read, kept and shown.
    func testStickyNotesAndPDFPagesOfOtherClientsAreRead() throws {
        let file = NoteFile.newTextNote(title: "", body: "", now: now)
        let page = try XCTUnwrap(file.root.descendants("page").first { $0["width"] != nil })
        func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
        let thumbnail = String(repeating: "ef", count: 32), pdf = String(repeating: "12", count: 32)
        let sticky = SamsungNotesKit.XMLNode(name: "customObject", attributes: ["type": "1", "id": "sticky-1"])
        let files = SamsungNotesKit.XMLNode(name: "attachedFileList", attributes: [:])
        files.children = [SamsungNotesKit.XMLNode(name: "pair", attributes: ["key": b64("co_attach_file"), "value": "aa"]), SamsungNotesKit.XMLNode(name: "pair", attributes: ["key": b64("co_thumbnail_path"), "value": thumbnail])]
        let data = SamsungNotesKit.XMLNode(name: "customDataList", attributes: [:])
        data.children = [SamsungNotesKit.XMLNode(name: "pair", attributes: ["key": b64("skn_bg_color"), "value": b64("-5713")])]
        sticky.children = [files, data, SamsungNotesKit.XMLNode(name: "rect", attributes: ["l": "10", "t": "20", "r": "210", "b": "220"])]
        let list = SamsungNotesKit.XMLNode(name: "customObjectList", attributes: [:])
        list.children = [sticky]
        let pdfList = SamsungNotesKit.XMLNode(name: "pdfDataList", attributes: [:])
        let entry = SamsungNotesKit.XMLNode(name: "pdfData", attributes: ["pageIndex": "3", "hash": pdf])
        entry.children = [SamsungNotesKit.XMLNode(name: "pdfRect", attributes: ["l": "0", "t": "0", "r": "848", "b": "1200"])]
        pdfList.children = [entry]
        page.children.append(contentsOf: [pdfList, list])
        page.attributes["templateType"] = "16"

        let read = try XCTUnwrap(NoteDocument(xml: file.data()).pages.first)
        let found = try XCTUnwrap(read.objects.first { $0.kind == .sticky })
        XCTAssertEqual(found.rect, CGRect(x: 10, y: 20, width: 200, height: 200))
        XCTAssertEqual(found.thumbnailFile, thumbnail)
        XCTAssertEqual(found.paper, UInt32(bitPattern: -5713))
        XCTAssertEqual(read.pdf?.file, pdf)
        XCTAssertEqual(read.pdf?.page, 3)
        XCTAssertNil(read.template)
        XCTAssertFalse(read.isBare)
        // A page that holds a sticky note is shown, and a page added after it gets neither the
        // sticky note nor the PDF page.
        XCTAssertEqual(file.addPage(after: 0, now: now.addingTimeInterval(1)), 1)
        let pages = file.root.descendants("page").filter { $0["width"] != nil }
        XCTAssertEqual(pages.count, 3)
        XCTAssertNil(pages[1].child("customObjectList"))
        XCTAssertNil(pages[1].child("pdfDataList"))
        XCTAssertNil(pages[1]["templateType"])
        XCTAssertNotNil(pages[0].child("customObjectList"))
        // The sticky note travels with its page untouched.
        let sent = try XMLTree.parse(Data(file.uploadDocument(pages: true, body: false).utf8))
        XCTAssertEqual(sent.descendants("customObject").first?["id"], "sticky-1")
    }

    /// A cropped picture that is moved many times keeps the frame of its whole picture true:
    /// it is worked out from the part's pixels each time, not rounded again and again.
    func testTheWholePicturesFrameDoesNotDriftWhenACroppedPictureMoves() throws {
        var file = NoteFile.newTextNote(title: "", body: "", now: now)
        file.pixelSize = { _ in CGSize(width: 1000, height: 500) }
        let id = file.addImage(fileHash: picture, fileExtension: "png", size: CGSize(width: 400, height: 200), placement: .onPage(0, CGRect(x: 100, y: 300, width: 400, height: 200)), now: now)
        file.setFloatingCrop(id, crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), pixels: CGSize(width: 1000, height: 500), rect: CGRect(x: 200, y: 350, width: 200.3, height: 100.3), now: now)
        for step in 1...60 { file.setFloatingRect(id, CGRect(x: 200 + Double(step) * 0.37, y: 350 + Double(step) * 0.21, width: 200.3, height: 100.3), now: now.addingTimeInterval(Double(step))) }
        let node = try object(file, id)
        let whole = NoteDocument.rect(try XCTUnwrap(node.child("imageOriginalRect")))
        XCTAssertEqual(whole.width, 400.6, accuracy: 2)
        XCTAssertEqual(whole.height, 200.6, accuracy: 2)
        XCTAssertEqual(whole.minX, 200 + 60 * 0.37 - 100.15, accuracy: 1.5)
        XCTAssertEqual(corners(node.child("cropRect")), ["250", "125", "750", "375"])
        // A part read back from whole pixels is written as the same pixels.
        let read = try XCTUnwrap(NoteDocument(xml: file.data()).floating.first)
        let again = CGRect(x: 337 / 1000.0, y: 113 / 500.0, width: 411 / 1000.0, height: 201 / 500.0)
        file.setFloatingCrop(id, crop: again, pixels: CGSize(width: 1000, height: 500), rect: read.rect, now: now.addingTimeInterval(100))
        XCTAssertEqual(corners(try object(file, id).child("cropRect")), ["337", "113", "748", "314"])
    }

    /// A picture whose page number changes because pages were added, removed or moved is a
    /// changed object: its time and hash move, so that the service asks for it again.
    func testPicturesThatChangePageAreMarkedAsChanged() throws {
        let file = NoteFile.newTextNote(title: "", body: "", now: now)
        let id = file.addImage(fileHash: picture, fileExtension: "png", size: CGSize(width: 100, height: 50), placement: .onPage(1, CGRect(x: 10, y: 10, width: 100, height: 50)), now: now)
        func stamp() throws -> (page: String?, hash: String?, tree: String?) {
            let node = try object(file, id)
            return (node["pageIndex"], node["hash"], file.root.descendant("noteTree")?.child("floatingObjectList")?.all("object").first { $0["id"] == id }?["h"])
        }
        let first = try stamp()
        XCTAssertEqual(first.page, "1")
        XCTAssertEqual(file.addPage(after: -1, now: now.addingTimeInterval(1)), 0)
        let second = try stamp()
        XCTAssertEqual(second.page, "2")
        XCTAssertNotEqual(second.hash, first.hash)
        XCTAssertEqual(second.hash, second.tree)
        XCTAssertNotNil(file.removePage(0, now: now.addingTimeInterval(2)))
        let third = try stamp()
        XCTAssertEqual(third.page, "1")
        XCTAssertNotEqual(third.hash, second.hash)
        XCTAssertTrue(file.movePage(1, to: 0, now: now.addingTimeInterval(3)))
        let fourth = try stamp()
        XCTAssertEqual(fourth.page, "0")
        XCTAssertNotEqual(fourth.hash, third.hash)
        XCTAssertEqual(fourth.hash, fourth.tree)
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))
    }

    func testAPDFPageKeepsItsPaperAndTwoRecordingsOfOneSoundAreTwo() throws {
        let file = NoteFile.newTextNote(title: "", body: "", now: now)
        let page = try XCTUnwrap(file.root.descendants("page").first { $0["width"] != nil })
        page.attributes["templateType"] = "16"
        let list = SamsungNotesKit.XMLNode(name: "pdfDataList", attributes: [:])
        list.children = [SamsungNotesKit.XMLNode(name: "pdfData", attributes: ["pageIndex": "0", "hash": "aa"])]
        page.children.insert(list, at: 0)
        file.setPaper(.template(.lineWide), now: now.addingTimeInterval(1))
        XCTAssertEqual(page["templateType"], "16")
        file.setPaper(.template(.blank), now: now.addingTimeInterval(2))
        XCTAssertEqual(page["templateType"], "16")
        // Its colour may change: that is not its paper's kind.
        file.setPaper(.color(0xFFE5_E5E5), now: now.addingTimeInterval(3))
        XCTAssertEqual(page["bgColor"], String(Int32(bitPattern: 0xFFE5_E5E5)))

        let sound = String(repeating: "cd", count: 32)
        file.addRecording(fileHash: sound, fileName: "a.m4a", title: "Voice001", seconds: 2, now: now)
        file.addRecording(fileHash: sound, fileName: "a.m4a", title: "Voice002", seconds: 2, now: now.addingTimeInterval(1))
        XCTAssertEqual(try NoteDocument(xml: file.data()).recordings.map(\.id), ["0:" + sound, "1:" + sound])
        XCTAssertTrue(file.removeRecording(fileHash: sound, now: now.addingTimeInterval(2)))
        XCTAssertEqual(file.recordingTitles, ["Voice002"])
        XCTAssertEqual(file.fileIDs, [sound], "the other recording still plays it")
        XCTAssertTrue(file.removeRecording(fileHash: sound, now: now.addingTimeInterval(3)))
        XCTAssertEqual(file.fileIDs, [])
    }

    /// Text lines are 1.35 times the text's size apart, the measure Samsung's rulings are made
    /// to: text of size 12 sits on the narrow lines, one line of text to each.
    func testLinesOfTextAreAsFarApartAsTheNarrowRuling() throws {
        let file = NoteFile.newTextNote(title: "", body: "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten", now: now)
        let document = try NoteDocument(xml: file.data())
        let flow = try XCTUnwrap(TextFlow(document))
        let density = document.density
        XCTAssertEqual((flow.bottom - flow.column.top) / density, 10 * PageTemplate.lineNarrow.pitch, accuracy: 4)
        // Twice the lines, twice the height: every line takes the same room.
        let longer = NoteFile.newTextNote(title: "", body: Array(repeating: "line", count: 20).joined(separator: "\n"), now: now)
        let twice = try XCTUnwrap(TextFlow(try NoteDocument(xml: longer.data())))
        XCTAssertEqual((twice.bottom - flow.bottom) / density, 10 * PageTemplate.lineNarrow.pitch, accuracy: 0.5)
    }

    /// Numbers in a note that are no numbers do not get as far as arithmetic.
    func testRectanglesFromANoteAreKeptWithinReason() throws {
        let node = SamsungNotesKit.XMLNode(name: "rect", attributes: ["l": "0", "t": "1e300", "r": "nan", "b": "inf"])
        let rect = NoteDocument.rect(node)
        XCTAssertTrue(rect.minY.isFinite && rect.maxY.isFinite && rect.width.isFinite && rect.height.isFinite)
        XCTAssertLessThanOrEqual(abs(rect.minY), 10_000_000)
    }

    func testTheRulingsDrawSomethingAndBlankDrawsNothing() throws {
        for template in PageTemplate.allCases {
            let side = 180, height = 254
            let context = try XCTUnwrap(CGContext(data: nil, width: side, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            template.draw(in: context, page: CGRect(x: 0, y: 0, width: side, height: height), dark: false)
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let marked = (0..<(context.bytesPerRow * height)).contains { bytes[$0] != 0 }
            XCTAssertEqual(marked, template != .blank, template.rawValue)
        }
        // From one row to the next, as Samsung's engine sets them: a text size times 1.35.
        XCTAssertEqual(PageTemplate.lineNarrow.pitch, 16.2, accuracy: 0.001)
        XCTAssertEqual(PageTemplate.lineMedium.pitch, 22.95, accuracy: 0.001)
        XCTAssertEqual(PageTemplate.lineWide.pitch, 37.8, accuracy: 0.001)
        XCTAssertEqual(PageTemplate.todo.pitch, 35.1, accuracy: 0.001)
        XCTAssertEqual(PageTemplate.oxford.pitch, 14.85, accuracy: 0.001)
        // On a page 848 wide the ruled page has a line every 34.98 units, the first ten text
        // units down, and its margin lines at 124.8 and 131.9: measured in the Windows client.
        let width = 848, height = 1200
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        PageTemplate.oxford.draw(in: context, page: CGRect(x: 0, y: 0, width: width, height: height), dark: false)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[y * context.bytesPerRow + x * 4 + 3] }
        func red(_ x: Int, _ y: Int) -> Bool { let at = y * context.bytesPerRow + x * 4; return bytes[at] > 150 && bytes[at + 2] < bytes[at] }
        var rows: [Int] = []
        var inside = false
        for y in 0..<height { let on = alpha(700, y) > 12; if on && !inside { rows.append(y) }; inside = on }
        XCTAssertEqual(rows.count, 34)
        XCTAssertEqual(Double(rows[0]), 10 * 848 / 360.0, accuracy: 1.5)
        XCTAssertEqual(Double(rows[11] - rows[1]), 349.8, accuracy: 1.5)
        var columns: [Int] = []
        inside = false
        for x in 0..<width { let on = red(x, 40); if on && !inside { columns.append(x) }; inside = on }
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(Double(columns.first ?? 0), 124.8, accuracy: 1.5)
        XCTAssertEqual(Double(columns.last ?? 0), 131.9, accuracy: 1.5)
    }

    /// The page shapes the Windows client's settings offer for a new note.
    func testLongAndEndlessNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalStore(root: folder)
        let edits = LocalEdits(store: store)

        // Long: two pages, each twice as high as wide.
        let long = try edits.createTextNote(title: "Long", body: "a", layout: NoteFile.Layout(long: true))
        var file = try store.noteFile(long)
        XCTAssertEqual(file.pageCount, 2)
        XCTAssertEqual(file.pageSize(0).height, 1696)
        XCTAssertEqual(file.attributes["pageDefaultHeight"], "1696")
        XCTAssertEqual(file.attributes["height"], String(2 * 1696 + 8))
        XCTAssertEqual(file.attributes["pageMode"], "0")
        XCTAssertTrue(NoteHash.verify(tree: file.tree))

        // Endless: one page, which grows by its first height under text and under ink, and never gets a second.
        let endless = try edits.createTextNote(title: "Endless", body: "start", layout: NoteFile.Layout(endless: true))
        file = try store.noteFile(endless)
        XCTAssertEqual(file.pageCount, 1)
        XCTAssertEqual(file.attributes["pageMode"], "1")
        XCTAssertEqual(file.pageSize(0).height, 2400, "with something written, a first height to spare under it")
        XCTAssertEqual(try store.noteFile(try edits.createTextNote(title: "", body: "", layout: NoteFile.Layout(endless: true))).pageSize(0).height, 1200)
        XCTAssertTrue(try store.load(endless).document.isEndless)
        var body = try XCTUnwrap(edits.richText(endless)).body
        body.replace(body.length..<body.length, with: String(repeating: "\nanother line", count: 90))
        try edits.saveRich(endless, title: nil, body: body)
        file = try store.noteFile(endless)
        XCTAssertEqual(file.pageCount, 1, "no second page")
        let height = file.pageSize(0).height
        XCTAssertGreaterThan(height, 1200)
        XCTAssertEqual(height % 1200, 0, "a whole number of its first heights")
        XCTAssertEqual(file.attributes["height"], String(height))
        let bottom = try XCTUnwrap(TextFlow(try NoteDocument(xml: file.data()))).bottom
        XCTAssertLessThanOrEqual(bottom, Double(height - 1200) + 0.5, "about a first height to spare under the text")
        XCTAssertGreaterThan(bottom, Double(height - 2400))
        XCTAssertTrue(NoteHash.verify(tree: file.tree))
        XCTAssertEqual(store.loadLibrary().notes[endless]?.pagesChanged, true)
        XCTAssertNil(try edits.addPage(endless))

        let points = (0..<8).map { InkPoint(x: 100 + Double($0) * 10, y: Double(height) - 40, pressure: 1, time: $0 * 8) }
        _ = try edits.addStrokes(endless, page: 0, strokes: [NewStroke(points: points, argb: 0xFF14_47FF, penSize: 6, pen: .fountain)])
        file = try store.noteFile(endless)
        XCTAssertEqual(file.pageSize(0).height, height + 1200, "drawn at its foot, the page grows")
        XCTAssertEqual(file.pageCount, 1)
        XCTAssertTrue(NoteHash.verify(tree: file.tree))

        // A note laid out on its side counts its 360 units down the page, not across.
        let lying = NoteFile.newTextNote(title: "", body: "")
        lying.attributes.attributes["orientation"] = "2"
        lying.attributes.attributes["pageDefaultHeight"] = "599"
        XCTAssertEqual(try NoteDocument(xml: lying.data()).density, 599.0 / 360, accuracy: 0.0001)
        XCTAssertEqual(try NoteDocument(xml: NoteFile.newTextNote(title: "", body: "").data()).density, 848.0 / 360, accuracy: 0.0001)
    }
}
