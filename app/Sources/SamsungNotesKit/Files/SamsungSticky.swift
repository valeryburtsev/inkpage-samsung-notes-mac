import Foundation

/// A sticky note's own document: Samsung keeps what a sticky note says in a small note file of
/// its own (an `.sdocx` archive of five binary files) beside the note it is stuck on. This
/// reads one, and writes one as the Windows client does, to the byte.
public struct StickyDocument: Equatable, Sendable {
    /// What the sticky note says.
    public var text: String
    /// The colour of its paper.
    public var paper: UInt32

    /// The moments (in microseconds) and ids of the parts of the small note.
    var created: Int64
    var modified: Int64
    var shownModified: Int64
    var saveCount: UInt32 = 1
    var titleID: String
    var titleTime: Int64
    var bodyID: String
    var bodyTime: Int64
    var pageID: String
    var pageTime: Int64
    var layerID: String
    var layerTime: Int64
    var width: UInt32 = 800
    var height: UInt32 = 2262
    var pageHeight: UInt32 = 1131
    /// The text as it was read, with all its formatting; nil for a sticky note made here.
    var record: SPen.Text?

    /// The colours the Windows client offers for the paper; the first is what a new one gets.
    /// (Yellow is from a sticky note of the Windows client; green, red and blue are that client's
    /// colour constants nearest to what its picker shows.)
    public static let papers: [UInt32] = [0xFFFF_E6AE, 0xFFDB_F0E4, 0xFFF4_DDD9, 0xFFD0_E0F4]
    /// The colour of the clip Samsung's clients draw on a sticky note of each paper.
    public static let clips: [UInt32] = [0xFFEB_A292, 0xFFCB_BFD3, 0xFF8C_7E6A, 0xFF99_C5E8]
    public static let side = 18.0

    /// A new sticky note.
    public init(text: String = "", paper: UInt32 = StickyDocument.papers[0], now: Date = Date()) {
        func id() -> String { UUID().uuidString.lowercased() }
        let time = Int64(now.timeIntervalSince1970 * 1_000_000)
        self.text = text; self.paper = paper
        created = time; modified = time; shownModified = time
        titleID = id(); titleTime = time
        bodyID = id(); bodyTime = time
        pageID = id(); pageTime = time
        layerID = id(); layerTime = time
    }

    /// The same sticky note saying something else, or on other paper, as saved now.
    public func with(text: String? = nil, paper: UInt32? = nil, now: Date = Date()) -> StickyDocument {
        var out = self
        let time = max(Int64(now.timeIntervalSince1970 * 1_000_000), modified + 1)
        if let text, text != out.text { out.text = text; out.bodyTime = time }
        if let paper, paper != out.paper { out.paper = paper; out.pageTime = time }
        out.modified = time
        out.saveCount += 1
        return out
    }

    /// The name the file is kept under in its note: the moment the sticky note was made.
    public var fileName: String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd_HH_mm_ss"
        return "stickymemo_\(format.string(from: Date(timeIntervalSince1970: Double(created) / 1_000_000))).sdocx"
    }

    // MARK: Writing

    private static let foreground: [UInt8] = [0x25, 0x25, 0x25, 0xFF, 0, 0, 0, 0]

    /// A title or body text box of a note: with no text at all, or with plain text.
    private static func textBox(id: String, time: Int64, pageWidth: UInt32, text: String?, kept: SPen.Text? = nil, autoFit: UInt8?) -> [UInt8] {
        var record: [UInt8]?
        if let kept {
            // Read from another client: its own record, saying what the note now says.
            record = kept.saying(text ?? "").bytes
        } else if let text {
            let count = UInt32(text.utf16.count)
            var size = SPen.Writer()
            size.f32(12); size.u32(0)
            var made = SPen.Text()
            made.string = text
            made.spans = [SPen.Span(type: 1, start: 0, end: count, value: foreground), SPen.Span(type: 17, start: 0, end: count, value: [UInt8](repeating: 0, count: 8)),
                          SPen.Span(type: 3, start: 0, end: count, value: size.bytes)]
            for line in 0..<UInt32(text.utf16.filter { $0 == 10 }.count + 1) {
                made.paragraphs.append(SPen.Paragraph(type: 3, start: line, end: line + 1, value: [UInt8](repeating: 0, count: 8)))
                made.paragraphs.append(SPen.Paragraph(type: 6, start: line, end: line + 1, value: [UInt8](repeating: 0, count: 8)))
            }
            made.margins = (16, 10, 16, 10)
            record = made.bytes
        }
        let none = (0.0, 0.0, 0.0, 0.0)
        return SPen.baseFrame(props: [0xBF, 0x01], formatVersion: 4000, id: id, modified: time, rect: none, ownerPage: (pageWidth, 0)).bytes
            + SPen.shapeBaseFrame(points: [], line: true).bytes
            + SPen.shapeFrame(rect: none, path: nil, text: record, autoFit: autoFit).bytes
            + SPen.textBoxFrame.bytes
    }

    private static func string16(_ text: String) -> [UInt8] {
        var out = SPen.Writer()
        out.u16(UInt16(text.utf16.count))
        for unit in text.utf16 { out.u16(unit) }
        return out.bytes
    }

    private static func sha(_ bytes: [UInt8]) -> [UInt8] { Array(NoteHash.digest(Data(bytes))) }
    /// The hash of the sync tree, in bytes: of the children's hashes and the hash of id and time.
    private static func treeHash(_ id: String, _ time: Int64, children: [UInt8] = []) -> [UInt8] { sha(children + sha(Array((id + String(time)).utf8))) }

    private var noteFile: [UInt8] {
        let title = StickyDocument.textBox(id: titleID, time: titleTime, pageWidth: width, text: nil, autoFit: nil)
        let body = StickyDocument.textBox(id: bodyID, time: bodyTime, pageWidth: width, text: text.isEmpty ? nil : text, kept: record, autoFit: 2)
        var fixed = SPen.Writer()
        fixed.u32(4000); fixed.u16(0); fixed.u32(saveCount); fixed.i64(created); fixed.i64(modified)
        fixed.u32(width); fixed.u32(height); fixed.u32(0); fixed.u32(8); fixed.u32(4000)
        fixed.sized(title); fixed.sized(body)
        fixed.u32(width); fixed.u32(pageHeight)
        var out = SPen.Writer()
        out.u32(UInt32(14 + fixed.bytes.count)); out.u8(4); out.u32(8); out.u8(4); out.u32(0x80 | 0x200 | 0x800 | 0x40000 | 0x80000)
        out.raw(fixed.bytes)
        // What the flags announce: nothing recognised, no body font size change, the text's direction, the theme.
        out.u32(0); out.i32(-1); out.i64(0); out.i32(0); out.u32(2); out.u32(2)
        return out.bytes + StickyDocument.sha(out.bytes)
    }

    private var pageFile: (bytes: [UInt8], hash: [UInt8]) {
        var fixed = SPen.Writer()
        fixed.u32(0); fixed.u32(width); fixed.u32(height); fixed.u32(0); fixed.u32(0)
        fixed.raw(StickyDocument.string16(pageID)); fixed.i64(pageTime); fixed.u32(4000); fixed.u32(4000)
        var flex = SPen.Writer()
        flex.u32(paper); flex.u32(width)
        let flexAt = 18 + fixed.bytes.count, layerAt = flexAt + flex.bytes.count
        var out = SPen.Writer()
        out.u32(UInt32(layerAt)); out.u32(UInt32(flexAt)); out.u8(4); out.u32(0); out.u8(4); out.u32(0x20 | 0x40)
        out.raw(fixed.bytes); out.raw(flex.bytes)
        out.u16(1); out.u16(0)
        // The one, empty layer; it says where in the file its own optional part begins.
        var layer = SPen.Writer()
        layer.raw(StickyDocument.string16(layerID)); layer.i64(layerTime)
        out.u32(UInt32(16 + layer.bytes.count)); out.u32(UInt32(layerAt + 4 + 16)); out.raw([0x01, 0x02, 0x01, 0x18]); out.u32(0)
        out.raw(layer.bytes)
        let layerHash = StickyDocument.treeHash(layerID, layerTime)
        out.u32(0); out.raw(layerHash)
        let hash = StickyDocument.treeHash(pageID, pageTime, children: layerHash)
        out.raw(hash)
        out.raw(Array("Page for SAMSUNG S-Pen SDK".utf8))
        return (out.bytes, hash)
    }

    private var endTag: [UInt8] {
        var out = SPen.Writer()
        out.u32(4000); out.u16(0); out.i64(modified); out.u32(0); out.u16(0)
        out.i32(Int32(width)); out.f32(Float(height)); out.u16(0); out.i32(-1); out.i32(-1); out.u16(0)
        out.u32(4000); out.i64(created); out.u32(0)
        out.u16(1); out.u16(0); out.u16(0); out.u32(0); out.u32(0)
        out.i64(created); out.i64(shownModified); out.i64(0); out.u16(0)
        out.u32(2); out.u32(2); out.i64(-1); out.u32(0); out.u32(0); out.u32(0)
        out.raw(Array("Document for S-Pen SDK".utf8))
        var sized = SPen.Writer()
        sized.u16(UInt16(out.bytes.count)); sized.raw(out.bytes)
        return sized.bytes
    }

    /// The archive: its five files, and after the archive's end the last of them once more.
    public var archive: Data {
        let note = noteFile, page = pageFile, end = endTag
        var media = SPen.Writer()
        media.u32(5500); media.u16(0); media.raw(Array("EOFX".utf8))
        var info = SPen.Writer()
        info.raw(Array(note.suffix(32))); info.u16(1); info.raw(StickyDocument.string16(pageID)); info.raw(page.hash)
        return Zip.writeAsSamsung([
            Zip.Entry(name: "media/mediaInfo.dat", data: Data(media.bytes)), Zip.Entry(name: pageID + ".page", data: Data(page.bytes)),
            Zip.Entry(name: "pageIdInfo.dat", data: Data(info.bytes)), Zip.Entry(name: "note.note", data: Data(note)), Zip.Entry(name: "end_tag.bin", data: Data(end)),
        ], after: Data(end))
    }

    // MARK: Reading

    private static func string16(_ reader: inout SPen.Reader) throws -> String {
        let units = try reader.take(Int(try reader.u16()) * 2)
        return String(decoding: stride(from: units.startIndex, to: units.endIndex, by: 2).map { UInt16(units[$0]) | UInt16(units[$0 + 1]) << 8 }, as: UTF16.self)
    }

    /// A text box's id, time and text.
    private static func textBox(_ bytes: [UInt8]) throws -> (id: String, time: Int64, text: SPen.Text?) {
        var reader = SPen.Reader(bytes)
        var id = "", time: Int64 = 0, text: SPen.Text?
        while !reader.isAtEnd {
            let frame = try SPen.Frame(&reader)
            if frame.type == 0 {
                var fixed = SPen.Reader(frame.fixed)
                _ = try fixed.u32()
                id = String(decoding: try fixed.take(Int(try fixed.u16())), as: UTF8.self)
                time = try fixed.i64()
            } else if frame.type == 7 {
                text = try SPen.text(ofShape: frame)
            }
        }
        return (id, time, text)
    }

    /// Reads a sticky note's archive: what it says and its paper. Handwriting and anything
    /// else such a note may hold is not read; `isExact(_:)` tells whether there was more.
    public init?(archive: Data) {
        guard let entries = try? Zip.read(archive, limit: 8 * 1024 * 1024) else { return nil }
        func file(_ name: String) -> [UInt8]? { entries.first { $0.name == name }.map { Array($0.data) } }
        guard let note = file("note.note"), let page = entries.first(where: { $0.name.hasSuffix(".page") }).map({ Array($0.data) }) else { return nil }
        do {
            var reader = SPen.Reader(note)
            _ = try reader.u32()
            _ = try reader.take(Int(try reader.u8()))
            _ = try reader.take(Int(try reader.u8()))
            _ = try reader.u32(); _ = try reader.u16()
            saveCount = try reader.u32()
            created = try reader.i64(); modified = try reader.i64()
            width = try reader.u32(); height = try reader.u32()
            _ = try reader.u32(); _ = try reader.u32(); _ = try reader.u32()
            let title = try StickyDocument.textBox(Array(try reader.take(try reader.count())))
            let body = try StickyDocument.textBox(Array(try reader.take(try reader.count())))
            _ = try reader.u32()
            pageHeight = try reader.u32()
            titleID = title.id; titleTime = title.time; bodyID = body.id; bodyTime = body.time
            text = body.text?.string ?? ""
            record = body.text

            var sheet = SPen.Reader(page)
            let layerAt = Int(try sheet.u32()), flexAt = Int(try sheet.u32())
            _ = try sheet.take(Int(try sheet.u8()))
            let flagBytes = try sheet.take(Int(try sheet.u8()))
            let flags = flagBytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            _ = try sheet.take(20)
            pageID = try StickyDocument.string16(&sheet)
            pageTime = try sheet.i64()
            guard flexAt >= sheet.at, layerAt >= flexAt, layerAt + 20 <= page.count else { return nil }
            // The optional fields come in the order of their flags; the paper's colour is the sixth.
            var flex = SPen.Reader(page, from: flexAt, to: layerAt)
            var colour: UInt32?
            for bit in 0..<6 where flags & (1 << UInt32(bit)) != 0 {
                guard [4, 5].contains(bit) else { return nil }
                let value = try flex.u32()
                if bit == 5 { colour = value }
            }
            paper = colour ?? StickyDocument.papers[0]
            var layer = SPen.Reader(page, from: layerAt + 4 + 16, to: page.count)
            layerID = try StickyDocument.string16(&layer)
            layerTime = try layer.i64()

            shownModified = modified
            if let end = file("end_tag.bin") {
                var tag = SPen.Reader(end)
                _ = try tag.take(6)
                _ = try StickyDocument.string16(&tag)
                _ = try tag.take(12)
                _ = try StickyDocument.string16(&tag)
                _ = try tag.take(8)
                _ = try StickyDocument.string16(&tag)
                _ = try tag.take(8)
                _ = try StickyDocument.string16(&tag)
                _ = try tag.take(20)
                _ = try StickyDocument.string16(&tag)
                _ = try tag.take(16)
                shownModified = try tag.i64()
            }
        } catch {
            return nil
        }
    }

    /// True when this client writes the archive again just as it is: then there is nothing in
    /// it but what was read, and it can be changed without loss.
    public func isExact(_ original: Data) -> Bool { archive == original }
}
