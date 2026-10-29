import CoreGraphics
import XCTest
@testable import SamsungNotesKit

/// Notes made of a PDF, as Samsung's clients import one: a page of the note for every page of
/// the document, of its shape, with the document under what is written on it.
final class PDFNoteTests: XCTestCase {
    private var root: URL!
    private var store: LocalStore!
    private var edits: LocalEdits!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-pdf-\(UUID().uuidString)")
        store = LocalStore(root: root)
        edits = LocalEdits(store: store)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// A PDF whose pages are of these sizes, each filled with a colour of its own.
    private func pdf(_ sizes: [CGSize], colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 0.6, 0), (0, 0, 1), (0.5, 0.5, 0)]) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var box = CGRect(origin: .zero, size: sizes.first ?? CGSize(width: 612, height: 792))
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for (index, size) in sizes.enumerated() {
            var sheet = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &sheet, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            let color = colors[index % colors.count]
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fill(sheet)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func pixel(_ image: CGImage, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // The image's point (x, y), counted from its top left, onto the one pixel.
        context.draw(image, in: CGRect(x: -x * Double(image.width), y: -(1 - y) * Double(image.height) + 1, width: Double(image.width), height: Double(image.height)))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    func testThePagesOfAPDFAreRead() throws {
        let pages = try XCTUnwrap(PDFPages(data: pdf([CGSize(width: 612, height: 792), CGSize(width: 792, height: 612)])))
        XCTAssertEqual(pages.sizes, [CGSize(width: 612, height: 792), CGSize(width: 792, height: 612)])
        XCTAssertNil(PDFPages(data: Data("not a PDF".utf8)))
        XCTAssertNil(PDFPages(data: Data()))
    }

    func testAPDFBecomesANoteOfItsPages() throws {
        // Letter pages, as in the note the Windows client made of such a PDF: 1183 wide there, each page 1530 high.
        let document = pdf([CGSize(width: 612, height: 792), CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)])
        let hash = NoteFile.sha256(document)
        let id = try edits.createPDFNote(title: "module12", pdf: document)
        let file = try store.noteFile(id)
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))

        let pages = try XCTUnwrap(file.root.all("pageList").last).all("page")
        XCTAssertEqual(pages.count, 4, "three pages of the PDF and the spare page")
        for (index, page) in pages.prefix(3).enumerated() {
            XCTAssertEqual(page["width"], "848")
            XCTAssertEqual(page["height"], "1097", "848 × 792 / 612, the fraction dropped")
            let data = try XCTUnwrap(page.child("pdfDataList")?.child("pdfData"))
            XCTAssertEqual(data["pageIndex"], String(index), "pages are counted from 0")
            XCTAssertEqual(data["hash"], hash)
            XCTAssertEqual(["l", "t", "r", "b"].map { data.child("pdfRect")?[$0] }, ["0", "0", "848", "1097"])
            XCTAssertNil(page["templateType"])
            XCTAssertEqual(page.children.map(\.name), ["pdfDataList", "layerList"])
        }
        // The spare page is a plain page of the note's own.
        XCTAssertEqual(pages[3]["height"], "1200")
        XCTAssertNil(pages[3].child("pdfDataList"))
        // The document is a file of the note, held once for each page that shows it.
        let entry = try XCTUnwrap(file.root.descendants("contentFile").first { $0["id"] == hash && $0["bindNumber"] != nil })
        XCTAssertEqual(entry["refCount"], "3")
        XCTAssertTrue(entry["name"]?.decodedBase64?.hasSuffix(".pdf") == true)
        XCTAssertTrue(entry["name"]?.decodedBase64?.hasPrefix("0@") == true)
        XCTAssertEqual(try Data(contentsOf: store.mediaURL(id, hash)), document)
        // As high as its pages and the spaces between them.
        XCTAssertEqual(file.attributes["height"], String(3 * 1097 + 1200 + 3 * 8))

        let record = try XCTUnwrap(store.loadLibrary().notes[id])
        XCTAssertEqual(record.title, "module12")
        XCTAssertEqual(record.pending, .create)
        XCTAssertEqual(record.unsentFiles, [hash], "the document goes up with the note")
        // What is sent says all of it.
        let sent = file.uploadDocument(pages: true, body: true)
        XCTAssertEqual(sent.components(separatedBy: "<pdfData ").count - 1, 3)
        XCTAssertTrue(sent.contains(hash))

        // Read back: three pages shown, each the page of the document, and the spare page left off.
        let note = try store.load(id)
        XCTAssertEqual(note.document.pages.prefix(3).map { $0.pdf?.page }, [0, 1, 2])
        XCTAssertEqual(note.document.pages.prefix(3).compactMap { $0.pdf?.file }, [hash, hash, hash])
        XCTAssertEqual(NoteLayout.shownPageCount(of: note.document), 3)
        // Each page shows its page of the PDF.
        for (index, color) in [(0, (r: 255, g: 0, b: 0)), (2, (r: 0, g: 0, b: 255))] {
            let image = try XCTUnwrap(NoteRenderer.pageImage(note, page: index, pixelWidth: 212, dark: false, images: { _ in nil }))
            XCTAssertEqual(Double(image.height) / Double(image.width), 1097.0 / 848, accuracy: 0.02, "a page is drawn in its own shape")
            let found = pixel(image, 0.5, 0.5)
            XCTAssertEqual(found.r, color.r, accuracy: 12)
            XCTAssertEqual(found.b, color.b, accuracy: 12)
        }
    }

    func testPagesOfDifferentShapesLieOneUnderTheOther() throws {
        let id = try edits.createPDFNote(title: "Mixed", pdf: pdf([CGSize(width: 600, height: 800), CGSize(width: 800, height: 600), CGSize(width: 600, height: 600)]))
        let note = try store.load(id)
        let layout = NoteLayout(note.document, shown: NoteLayout.shownPageCount(of: note.document))
        XCTAssertEqual(layout.pageCount, 3)
        // 848 wide: 1130, 636 and 848 high, 8 between them.
        XCTAssertEqual((0..<3).map { layout.height($0) }, [1130, 636, 848])
        XCTAssertEqual((0..<3).map { layout.top($0) }, [0, 1138, 1782])
        XCTAssertEqual(layout.pageRect(1), CGRect(x: 0, y: 1138, width: 848, height: 636))
        XCTAssertEqual(layout.size.height, 1782 + 848)
        XCTAssertEqual([0, 1129, 1137, 1138, 1781, 1782, 5000, -5].map { layout.page(at: $0) }, [0, 0, 0, 1, 1, 2, 2, 0])
        // A note whose pages are all alike is laid out as it always was.
        let plain = try store.load(try edits.createTextNote(title: "Plain", body: "text"))
        let even = NoteLayout(plain.document)
        XCTAssertEqual(even.pageRect(1), CGRect(x: 0, y: 1208, width: 848, height: 1200))
        XCTAssertEqual([0, 1207, 1208, 99_999].map { even.page(at: $0) }, [0, 0, 1, 1])
    }

    func testTypedTextKeepsToPagesOfDifferentHeights() throws {
        // Enough text for several pages, in a note whose pages are a tall one, a low one and a square one.
        let body = (1...120).map { "Line \($0) of the text of a long note" }.joined(separator: "\n")
        let id = try edits.createTextNote(title: "Mixed", body: body)
        _ = try edits.addPDFPages(id, pdf: pdf([CGSize(width: 600, height: 800), CGSize(width: 800, height: 300), CGSize(width: 600, height: 600)]), at: 0, replacing: true)
        let document = try store.load(id).document
        let layout = NoteLayout(document)
        let column = TextColumn(document)
        XCTAssertEqual(Array(column.heights.prefix(3)), [1130, 318, 848])
        XCTAssertEqual(column.top(ofPage: 1), 1138)
        XCTAssertEqual(column.page(at: 1137), 0)
        XCTAssertEqual(column.page(at: 1138), 1)
        XCTAssertEqual(column.usable(onPage: 1), 318 - column.top - column.bottom, accuracy: 0.001)
        let flow = try XCTUnwrap(TextFlow(document))
        XCTAssertGreaterThan(flow.pagesUsed, 3)
        XCTAssertLessThanOrEqual(flow.pagesUsed, document.pages.count, "the note has a page for all of its text")
        var perPage: [Int: Int] = [:]
        for line in flow.lineRects {
            let page = layout.page(at: line.midY)
            perPage[page, default: 0] += 1
            let sheet = layout.pageRect(page)
            XCTAssertGreaterThanOrEqual(line.minY, sheet.minY + column.top - 1, "a line begins below its page's top margin")
            XCTAssertLessThanOrEqual(line.maxY, sheet.maxY - column.bottom + 1, "and ends above its foot: nothing lies across two pages")
        }
        XCTAssertGreaterThan(perPage[0] ?? 0, (perPage[1] ?? 0) * 2, "the low page holds far fewer lines than the tall one")
        XCTAssertGreaterThan(perPage[1] ?? 0, 0)
    }

    func testPagesOfAPDFJoinANoteAndLeaveIt() throws {
        let id = try edits.createTextNote(title: "Minutes", body: "Agenda")
        let document = pdf([CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)])
        let hash = NoteFile.sha256(document)
        // After the note's own page, before its spare page.
        let added = try edits.addPDFPages(id, pdf: document, at: 1)
        XCTAssertEqual(added.first, 1)
        XCTAssertEqual(added.count, 2)
        var note = try store.load(id)
        XCTAssertEqual(note.document.pages.map { $0.pdf?.page }, [nil, 0, 1, nil])
        XCTAssertEqual(NoteLayout.shownPageCount(of: note.document), 3)
        XCTAssertEqual(note.document.body.plain.trimmingCharacters(in: .whitespacesAndNewlines), "Agenda")
        XCTAssertEqual(store.loadLibrary().notes[id]?.unsentFiles, [hash])
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(try store.noteFile(id).root.descendant("noteTree"))))

        // A blank page added after a page of the PDF is a page of the note's own, not of the PDF's shape.
        let blank = try XCTUnwrap(try edits.addPage(id, after: 2))
        note = try store.load(id)
        XCTAssertEqual(note.document.pages[blank].height, 1200)
        XCTAssertNil(note.document.pages[blank].pdf)
        try edits.removePage(id, index: blank)

        // One page of the PDF taken away: the document stays for the other; with the last it goes.
        try edits.removePage(id, index: 1)
        var file = try store.noteFile(id)
        XCTAssertEqual(file.root.descendants("contentFile").first { $0["id"] == hash && $0["bindNumber"] != nil }?["refCount"], "1")
        XCTAssertEqual(try store.load(id).document.pages.map { $0.pdf?.page }, [nil, 1, nil])
        try edits.removePage(id, index: 1)
        file = try store.noteFile(id)
        XCTAssertFalse(file.fileIDs.contains(hash))
        XCTAssertTrue(NoteHash.verify(tree: try XCTUnwrap(file.root.descendant("noteTree"))))

        // An empty note takes the PDF in the place of its empty page.
        let empty = try edits.createTextNote(title: "", body: "")
        let taken = try edits.addPDFPages(empty, pdf: document, at: 0, replacing: true)
        XCTAssertEqual(taken.first, 0)
        XCTAssertEqual(try store.load(empty).document.pages.map { $0.pdf?.page }, [0, 1, nil])
    }

    func testWhatIsNotAPDFIsRefused() throws {
        XCTAssertThrowsError(try edits.createPDFNote(title: "No", pdf: Data("plain text".utf8)))
        XCTAssertTrue(store.loadLibrary().notes.isEmpty)
        let endless = try edits.createTextNote(title: "Scroll", body: "", layout: NoteFile.Layout(long: false, endless: true))
        XCTAssertThrowsError(try edits.addPDFPages(endless, pdf: pdf([CGSize(width: 612, height: 792)])))
        XCTAssertEqual(try store.load(endless).document.pages.count, 1)
    }

    /// The note the Windows client makes of a PDF, in the form the service passes on: pages of the
    /// PDF's shape, then a spare page of the note's own height, which is not shown.
    func testTheSparePageAfterAPDFsPagesIsNotShown() throws {
        let file = NoteFile.newTextNote(title: "module12", body: "", now: Date(timeIntervalSince1970: 1_791_900_000))
        file.addPDFPages(hash: String(repeating: "ab", count: 32), fileName: "x.pdf", sizes: Array(repeating: CGSize(width: 612, height: 792), count: 15), at: 0)
        file.removePage(15)
        var document = try NoteDocument(xml: file.data())
        XCTAssertEqual(document.pages.count, 16)
        XCTAssertNotEqual(document.pages[15].height, document.pages[14].height)
        XCTAssertEqual(NoteLayout.shownPageCount(of: document), 15)
        // A blank page the user added after the PDF is shown; only the spare one after it is not.
        file.addPage(after: 14)
        document = try NoteDocument(xml: file.data())
        XCTAssertEqual(document.pages.count, 17)
        XCTAssertEqual(NoteLayout.shownPageCount(of: document), 16)
    }
}
