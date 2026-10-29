import XCTest
@testable import SamsungNotesKit

final class ZipTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)))
    }

    /// The nested document of a sticky note made in the Windows client: five small files.
    func testReadsADocumentTheWindowsClientWrote() throws {
        let entries = try Zip.read(try fixture("sticky-windows.sdocx"))
        XCTAssertEqual(Set(entries.map(\.name)), ["media/mediaInfo.dat", "ff911702-c64b-11f1-b791-977929222c41.page", "pageIdInfo.dat", "note.note", "end_tag.bin"])
        XCTAssertEqual(entries.first { $0.name == "note.note" }?.data.count, 1136)
        XCTAssertEqual(entries.first { $0.name == "end_tag.bin" }?.data.suffix(22), Data("Document for S-Pen SDK".utf8))
    }

    func testWhatIsWrittenIsReadBack() throws {
        let entries = [
            Zip.Entry(name: "note.note", data: Data((0..<5000).map { UInt8($0 % 7) })),
            Zip.Entry(name: "media/mediaInfo.dat", data: Data([1, 2, 3])),
            Zip.Entry(name: "empty.bin", data: Data()),
            Zip.Entry(name: "ünïcödé.page", data: Data("Page for SAMSUNG S-Pen SDK".utf8)),
        ]
        XCTAssertEqual(try Zip.read(Zip.write(entries)), entries)
        // The system's own unzip reads it too (names as a document has them: plain letters).
        let archive = Zip.write(Array(entries.prefix(3)))
        XCTAssertLessThan(archive.count, 1000, "what repeats is deflated")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.zip")
        try archive.write(to: file)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", file.path, "-d", folder.path]
        FileManager.default.createFile(atPath: folder.appendingPathComponent("unzip.log").path, contents: nil)
        let log = try FileHandle(forWritingTo: folder.appendingPathComponent("unzip.log"))
        unzip.standardOutput = log
        unzip.standardError = log
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0, (try? String(contentsOf: folder.appendingPathComponent("unzip.log"), encoding: .utf8)) ?? "")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("note.note")), entries[0].data)
    }

    func testWhatIsNoArchiveIsRefused() {
        XCTAssertThrowsError(try Zip.read(Data("not a zip".utf8)))
        XCTAssertThrowsError(try Zip.read(Data(count: 100)))
        var broken = Zip.write([Zip.Entry(name: "a", data: Data(count: 2000))])
        broken.removeSubrange(10..<40)
        XCTAssertThrowsError(try Zip.read(broken))
    }
}

final class StickyDocumentTests: XCTestCase {
    private func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sticky-windows.sdocx"))
    }

    /// A sticky note written on Windows is read, and written again to the last byte.
    func testReadsAndRewritesTheWindowsStickyNote() throws {
        let original = try fixture()
        let sticky = try XCTUnwrap(StickyDocument(archive: original))
        XCTAssertEqual(sticky.text, "Here we go Test \n\n\n1123\n\n\n555")
        XCTAssertEqual(sticky.paper, 0xFFFF_E6AE)
        XCTAssertEqual(sticky.archive, original)
        XCTAssertTrue(sticky.isExact(original))
        XCTAssertEqual(NoteFile.sha256(original), "4054004f50105b0072afb65301cc4008842e397c491875116e45975dc8d123ca")
    }

    /// One made here is an archive any zip reader opens, and reads back as it was written.
    func testNewStickyNoteReadsBack() throws {
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        let made = StickyDocument(text: "Buy milk\nCall Anna — завтра", paper: StickyDocument.papers[2], now: now)
        let archive = made.archive
        XCTAssertEqual(try Zip.read(archive).map(\.name).filter { !$0.hasSuffix(".page") }, ["media/mediaInfo.dat", "pageIdInfo.dat", "note.note", "end_tag.bin"])
        let back = try XCTUnwrap(StickyDocument(archive: archive))
        XCTAssertEqual(back.text, made.text)
        XCTAssertEqual(back.paper, made.paper)
        XCTAssertEqual(back.archive, archive)
        XCTAssertTrue(back.isExact(archive))
        // The note file ends with the hash of all that comes before it.
        let note = try XCTUnwrap(try Zip.read(archive).first { $0.name == "note.note" }?.data)
        XCTAssertEqual(NoteFile.sha256(note.dropLast(32)), note.suffix(32).map { String(format: "%02x", $0) }.joined())

        let changed = back.with(text: "Buy bread", paper: nil, now: now.addingTimeInterval(60))
        let again = try XCTUnwrap(StickyDocument(archive: changed.archive))
        XCTAssertEqual(again.text, "Buy bread")
        XCTAssertEqual(again.paper, StickyDocument.papers[2])
        XCTAssertEqual(again.fileName, made.fileName)
        XCTAssertNotEqual(changed.archive, archive)

        let empty = try XCTUnwrap(StickyDocument(archive: StickyDocument(now: now).archive))
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(StickyDocument.papers.count, 4)
    }

    /// A sticky note whose text another client formatted in parts keeps that formatting when
    /// it is written again, and through a change of its words.
    func testFormattingOfAStickyNoteIsKept() throws {
        var sticky = try XCTUnwrap(StickyDocument(archive: try fixture()))
        var record = try XCTUnwrap(sticky.record)
        // "Here" in bold, as another client would mark it.
        record.spans.append(SPen.Span(type: 5, start: 0, end: 4, value: [1, 0, 0, 0, 0, 0, 0, 0]))
        sticky.record = record
        let formatted = sticky.archive
        let read = try XCTUnwrap(StickyDocument(archive: formatted))
        XCTAssertTrue(read.isExact(formatted), "a sticky note with formatting can be changed here")
        XCTAssertEqual(read.record?.runs.first, SPen.Text.Run(text: "Here", bold: true, size: 12, color: 0xFF25_2525))
        let changed = try XCTUnwrap(StickyDocument(archive: read.with(text: read.text + "\nand more", now: Date(timeIntervalSince1970: 1_800_000_000)).archive))
        XCTAssertEqual(changed.text, read.text + "\nand more")
        XCTAssertEqual(changed.record?.runs.first?.text, "Here")
        XCTAssertEqual(changed.record?.runs.first?.bold, true)
        XCTAssertEqual(changed.record?.runs.last?.bold, false)
        // Every line still says how it is aligned and that it was read.
        XCTAssertEqual(changed.record?.paragraphs.count, 2 * (changed.text.filter { $0 == "\n" }.count + 1))
    }

    func testATextRecordTakesNewWordsAndKeepsItsSpans() {
        var text = SPen.Text()
        text.string = "one two three"
        let on: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0]
        text.spans = [SPen.Span(type: 1, start: 0, end: 13, value: on), SPen.Span(type: 5, start: 4, end: 7, value: on), SPen.Span(type: 6, start: 8, end: 13, value: on)]
        text.paragraphs = [SPen.Paragraph(type: 3, start: 0, end: 1, value: on), SPen.Paragraph(type: 6, start: 0, end: 1, value: on)]
        XCTAssertEqual(text.saying("one two three"), text)
        // Typed before, inside and after the bold word.
        var now = text.saying("ONE two three")
        XCTAssertEqual(now.spans.map { [$0.start, $0.end] }, [[0, 13], [4, 7], [8, 13]])
        now = text.saying("one twoo three")
        XCTAssertEqual(now.spans.map { [$0.start, $0.end] }, [[0, 14], [4, 8], [9, 14]], "typing at the end of a bold word is bold")
        now = text.saying("one  three")
        XCTAssertEqual(now.spans.map { [$0.start, $0.end] }, [[0, 10], [5, 10]], "the bold word is gone and its span with it")
        now = text.saying("one two three\nfour")
        XCTAssertEqual(now.spans.map { [$0.start, $0.end] }, [[0, 18], [4, 7], [8, 18]])
        XCTAssertEqual(now.paragraphs.map { [$0.type, $0.start, $0.end] }, [[3, 0, 1], [6, 0, 1], [3, 1, 2], [6, 1, 2]])
        now = text.saying("")
        XCTAssertEqual(now.spans.first.map { [$0.start, $0.end] }, [0, 0])
        XCTAssertEqual(now.runs, [])
        XCTAssertEqual(text.runs.map(\.text), ["one ", "two", " ", "three"])
        XCTAssertEqual(text.runs.map(\.bold), [false, true, false, false])
        XCTAssertEqual(text.runs.map(\.italic), [false, false, false, true])
    }
}
