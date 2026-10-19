import CoreGraphics
import XCTest
@testable import SamsungNotesKit

/// The spare page at the end of every note is left off the screen only when it is shown to be
/// empty. These tests are the safeguard: nothing that holds anything may ever be hidden.
final class PageVisibilityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_700_000)
    let fileHash = String(repeating: "ab", count: 32)

    func shown(_ file: NoteFile) throws -> Int { NoteLayout.shownPageCount(of: try NoteDocument(xml: file.data())) }

    func note(pages: Int = 2, body: String = "") -> NoteFile {
        let file = NoteFile.newTextNote(title: "T", body: body, now: now)
        while file.pageCount < pages { file.addPage(now: now) }
        return file
    }

    func page(_ file: NoteFile, _ index: Int) -> SamsungNotesKit.XMLNode { file.root.descendants("pageList").last!.all("page")[index] }

    func stroke(_ file: NoteFile, page: Int, _ id: String = UUID().uuidString.lowercased()) {
        file.addStrokes([(id, 1_791_700_000_000_000, CGRect(x: 10, y: 10, width: 50, height: 20))], page: page, argb: 0xFF00_0000, penSize: 6, now: now)
    }

    // MARK: What is shown

    func testANewNoteShowsOnePage() throws {
        let file = note()
        XCTAssertEqual(file.pageCount, 2, "the file keeps its spare page, as the other clients write it")
        XCTAssertEqual(try shown(file), 1)
        XCTAssertEqual(try shown(note(pages: 1)), 1)
    }

    func testTextThatRunsOntoThePageShowsIt() throws {
        XCTAssertEqual(try shown(note(body: (0..<20).map { "line \($0)" }.joined(separator: "\n"))), 1)
        XCTAssertEqual(try shown(note(body: (0..<80).map { "line \($0)" }.joined(separator: "\n"))), 2)
        // Text that ends exactly where the live view says it ends.
        let file = note(pages: 3)
        let document = try NoteDocument(xml: file.data())
        XCTAssertEqual(NoteLayout.shownPageCount(of: document, textBottom: 100), 1)
        XCTAssertEqual(NoteLayout.shownPageCount(of: document, textBottom: 1205), 1, "ending in the gap between the pages is still the first page")
        XCTAssertEqual(NoteLayout.shownPageCount(of: document, textBottom: 1250), 2, "a line on the second page")
        XCTAssertEqual(NoteLayout.shownPageCount(of: document, textBottom: 2500), 3)
        XCTAssertEqual(NoteLayout.shownPageCount(of: document, textBottom: .nan), 1)
    }

    func testInkKeepsItsPage() throws {
        let file = note(pages: 3)
        stroke(file, page: 0)
        XCTAssertEqual(try shown(file), 1)
        stroke(file, page: 1)
        XCTAssertEqual(try shown(file), 2)
        stroke(file, page: 2)
        XCTAssertEqual(try shown(file), 3)
    }

    func testEmptyPagesBetweenContentStayVisible() throws {
        let file = note(pages: 4)
        stroke(file, page: 0)
        stroke(file, page: 2)
        XCTAssertEqual(try shown(file), 3, "page 2 is empty but lies between")
        let blank = note(pages: 3)
        stroke(blank, page: 2)
        XCTAssertEqual(try shown(blank), 3)
    }

    func testPicturesKeepTheirPageAndWhatTheyReachOnto() throws {
        let onFirst = note(pages: 3)
        _ = onFirst.addImage(fileHash: fileHash, fileExtension: "png", size: CGSize(width: 100, height: 80), placement: .onPage(0, CGRect(x: 10, y: 10, width: 100, height: 80)), now: now)
        XCTAssertEqual(try shown(onFirst), 1)
        let onSecond = note(pages: 3)
        _ = onSecond.addImage(fileHash: fileHash, fileExtension: "png", size: CGSize(width: 100, height: 80), placement: .onPage(1, CGRect(x: 10, y: 10, width: 100, height: 80)), now: now)
        XCTAssertEqual(try shown(onSecond), 2)
        // A tall picture on the first page that runs down over the page break.
        let tall = note(pages: 3)
        _ = tall.addImage(fileHash: fileHash, fileExtension: "png", size: CGSize(width: 100, height: 1500), placement: .onPage(0, CGRect(x: 10, y: 100, width: 100, height: 1500)), now: now)
        XCTAssertEqual(try shown(tall), 2)
    }

    // MARK: What is never hidden because it cannot be judged

    func testAnObjectOfAnyKindKeepsItsPage() throws {
        for kind in ["voice", "shape", "textBox", "table", "somethingNew"] {
            let file = note(pages: 2)
            let layer = try XCTUnwrap(page(file, 1).child("layerList")?.all("layer").first)
            let list = layer.ensureChild("objectList")
            list.children.append(SamsungNotesKit.XMLNode(name: "object", attributes: ["type": kind, "id": UUID().uuidString.lowercased()]))
            XCTAssertEqual(try shown(file), 2, "a \(kind) on the second page")
        }
    }

    func testAPageThatIsNotBareIsKept() throws {
        // A drawn area recorded, though no object is listed.
        let drawn = note()
        page(drawn, 1).children.insert(SamsungNotesKit.XMLNode(name: "drawnRect", attributes: ["l": "1", "t": "1", "r": "20", "b": "20"]), at: 0)
        XCTAssertEqual(try shown(drawn), 2)
        // An attribute this client has never seen (a template or a PDF page, perhaps).
        let attribute = note()
        page(attribute, 1).attributes["pdfPageIndex"] = "3"
        XCTAssertEqual(try shown(attribute), 2)
        // A part of the page it does not know.
        let part = note()
        page(part, 1).children.append(SamsungNotesKit.XMLNode(name: "templateInfo", attributes: [:]))
        XCTAssertEqual(try shown(part), 2)
        // A cached picture of the page.
        let cache = note()
        page(cache, 1).children.append(SamsungNotesKit.XMLNode(name: "canvasCacheDataMap", attributes: [:]))
        XCTAssertEqual(try shown(cache), 2)
        // A layer that is hidden or locked, or with a picture of its own.
        for (key, value) in [("visible", "False"), ("lockState", "True"), ("thumbnail", "12")] {
            let layered = note()
            page(layered, 1).child("layerList")?.all("layer").first?.attributes[key] = value
            XCTAssertEqual(try shown(layered), 2, "layer \(key)=\(value)")
        }
        // A different paper than the page before.
        let paper = note()
        page(paper, 1).attributes["bgColor"] = "-1000"
        XCTAssertEqual(try shown(paper), 2)
        let size = note()
        page(size, 1).attributes["height"] = "1600"
        XCTAssertEqual(try shown(size), 2)
    }

    func testEdgesDoNotTrap() throws {
        XCTAssertEqual(try shown(note(pages: 1)), 1)
        let none = note()
        none.root.children.removeAll { $0.name == "pageList" }
        XCTAssertEqual(try shown(none), 1)
        let odd = note(pages: 3)
        for index in 0..<3 { page(odd, index).attributes["height"] = index == 1 ? "nan" : "0" }
        XCTAssertGreaterThanOrEqual(try shown(odd), 1)
    }

    // MARK: Captured notes

    func testCapturedNotes() throws {
        func document(_ name: String) throws -> NoteDocument {
            let raw = try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent(name))
            if name.hasSuffix(".xml") { return try NoteDocument(xml: raw) }
            return try NoteDocument(xml: try XCTUnwrap(Multipart.parse(raw).first { $0.name == "noteResource" }).body)
        }
        // Made on Windows: a text note and a handwritten one, each with its spare page.
        let text = try document("create-text-windows.multipart")
        XCTAssertEqual(text.pages.count, 2)
        XCTAssertTrue(text.pages.allSatisfy(\.isBare))
        XCTAssertEqual(NoteLayout.shownPageCount(of: text), 1)
        let ink = try document("create-ink-windows.multipart")
        XCTAssertEqual(ink.pages.count, 2)
        XCTAssertFalse(ink.pages[0].isBare)
        XCTAssertTrue(ink.pages[1].isBare)
        XCTAssertEqual(NoteLayout.shownPageCount(of: ink), 1)
        // Made on the phone.
        let phone = try document("downsync-ink-phone.xml")
        let inkPages = phone.pages.indices.filter { !phone.pages[$0].objects.isEmpty }
        XCTAssertFalse(inkPages.isEmpty)
        XCTAssertGreaterThan(NoteLayout.shownPageCount(of: phone), inkPages.max() ?? 0, "the page with the ink is shown")
    }

    // MARK: The safeguard itself

    /// Random notes: whatever is put on a page, that page and every one above it are shown.
    func testNothingThatHoldsSomethingIsEverHidden() throws {
        var state: UInt64 = 20_261_011
        func random(_ below: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(below, 1)))
        }
        for round in 0..<400 {
            let file = note(pages: 1 + random(6))
            let pages = file.pageCount
            var mustShow = 0
            var log: [String] = ["pages \(pages)"]
            for _ in 0..<random(5) {
                let target = random(pages)
                switch random(5) {
                case 0:
                    stroke(file, page: target)
                    mustShow = max(mustShow, target)
                    log.append("stroke on \(target)")
                case 1:
                    let y = Double(random(1200)), height = Double(20 + random(1500))
                    _ = file.addImage(fileHash: fileHash, fileExtension: "png", size: CGSize(width: 60, height: height), placement: .onPage(target, CGRect(x: 10, y: y, width: 60, height: height)), now: now)
                    mustShow = max(mustShow, min(target, pages - 1))
                    // Reaching down onto the next page counts too.
                    let reach = Int((y + height - 1) / 1208)
                    mustShow = max(mustShow, min(target + reach, pages - 1))
                    log.append("picture on \(target) at \(y), \(height) tall")
                case 2:
                    page(file, target).attributes["extra"] = "1"
                    mustShow = max(mustShow, target)
                    log.append("unknown attribute on \(target)")
                case 3:
                    page(file, target).children.append(SamsungNotesKit.XMLNode(name: "other", attributes: [:]))
                    mustShow = max(mustShow, target)
                    log.append("unknown part on \(target)")
                default:
                    if target > 0 {
                        page(file, target).attributes["bgColor"] = String(-1000 - random(50))
                        mustShow = max(mustShow, target)
                        log.append("other paper on \(target)")
                    }
                }
            }
            let count = try shown(file)
            XCTAssertGreaterThanOrEqual(count, mustShow + 1, "round \(round): \(log.joined(separator: "; ")) -> shown \(count)")
            XCTAssertLessThanOrEqual(count, pages)
            XCTAssertGreaterThanOrEqual(count, 1)
        }
    }
}
