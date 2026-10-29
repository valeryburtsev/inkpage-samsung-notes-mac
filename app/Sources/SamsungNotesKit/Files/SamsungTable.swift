import CoreGraphics
import CoreText
import Foundation

/// A table of a note, as Samsung's clients keep it: a binary record (`tableBinary` in the sync
/// document) holding the columns' widths and, row by row, cells that are small text boxes.
///
/// Everything read is kept as it was read, down to fields this client has no name for, so a
/// table is written again byte for byte until something about it is changed; then only what
/// changed is written anew (a cell's text, the places of the cells). A cell's text keeps
/// whatever formatting it came with (`SPen.Text.saying`). Only a table with merged cells is
/// not read: this client keeps a table as a plain grid.
public struct SamsungTable: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public var id: String
        public var text: String
        public var bold = false
        public var italic = false
        public var underline = false
        public var strikethrough = false
        /// In units of text size.
        public var fontSize: Float = 15
        public var color: UInt32 = 0xFF25_2525
        /// 0 left, 1 right, 2 centre, 3 justified.
        public var alignment = 0
        /// The cell's own paper, 0 for none. A cell given one says so in its properties (even
        /// when it is given none: "no fill" is a paper of its own too).
        public var background: UInt32 = 0 { didSet { if background != oldValue { ownsBackground = true } } }
        public var ownsBackground: Bool {
            get { (props.first ?? 0) & 1 != 0 }
            set { if props.isEmpty { props = [0] }; props[0] = newValue ? props[0] | 1 : props[0] & ~1 }
        }

        /// The text as it was read, with all its formatting; nil for a cell made here.
        var record: SPen.Text?
        /// Read without any text record at all.
        var blank = false
        /// The cell's own properties and flags, and what its flags announce after its text box
        /// (a border of its own), as read.
        var props: [UInt8] = [0]
        var flagBytes = 2
        var flags: UInt64 = 0
        var extra: [UInt8] = []
        var mark: UInt8 = 1
        /// The cell's rectangle on its page.
        var place: (l: Double, t: Double, r: Double, b: Double) = (0, 0, 0, 0)
        /// The frames of its text box as read; nil for a cell made here.
        var frames: [SPen.Frame]?

        public init(id: String = UUID().uuidString.lowercased(), text: String = "") { self.id = id; self.text = text }

        public static func == (a: Cell, b: Cell) -> Bool {
            a.id == b.id && a.text == b.text && a.bold == b.bold && a.italic == b.italic && a.underline == b.underline && a.strikethrough == b.strikethrough
                && a.fontSize == b.fontSize && a.color == b.color && a.alignment == b.alignment && a.background == b.background && a.record == b.record && a.blank == b.blank
                && a.props == b.props && a.flagBytes == b.flagBytes && a.flags == b.flags && a.extra == b.extra && a.mark == b.mark && a.frames == b.frames
                && [a.place.l, a.place.t, a.place.r, a.place.b] == [b.place.l, b.place.t, b.place.r, b.place.b]
        }

        /// A stretch of the cell's text in one style.
        public struct Run: Equatable, Sendable {
            public var text: String
            public var bold: Bool
            public var italic: Bool
            public var underline: Bool
            public var strikethrough: Bool
            public var fontSize: Float
            public var color: UInt32
        }

        private static func bytes(_ value: Float) -> [UInt8] { var out = SPen.Writer(); out.f32(value); out.u32(0); return out.bytes }
        private static func bytes(_ value: UInt32) -> [UInt8] { var out = SPen.Writer(); out.u32(value); out.u32(0); return out.bytes }
        private static func number(_ value: [UInt8]?) -> UInt32? {
            guard let value, value.count >= 4 else { return nil }
            return UInt32(value[0]) | UInt32(value[1]) << 8 | UInt32(value[2]) << 16 | UInt32(value[3]) << 24
        }

        /// Takes the cell's style from a text record: what its first character is set in.
        mutating func adopt(_ text: SPen.Text) {
            record = text
            self.text = text.string
            if let size = Cell.number(text.value(of: 3)) { fontSize = Float(bitPattern: size) }
            if let ink = Cell.number(text.value(of: 1)) { color = ink }
            bold = text.value(of: 5)?.first == 1
            italic = text.value(of: 6)?.first == 1
            underline = text.value(of: 7)?.first == 1
            strikethrough = text.value(of: 20)?.first == 1
            alignment = text.alignment
        }

        /// The record that is written for the cell. One read from another client says what the
        /// cell now says, and whatever of the cell's style was changed here holds for all of it.
        var written: SPen.Text? {
            if let record {
                var model = Cell()
                model.adopt(record)
                var text = record.saying(text)
                if bold != model.bold { text.set(5, on: bold) }
                if italic != model.italic { text.set(6, on: italic) }
                if underline != model.underline { text.set(7, on: underline) }
                if strikethrough != model.strikethrough { text.set(20, on: strikethrough) }
                if fontSize != model.fontSize { text.set(3, value: Cell.bytes(fontSize)) }
                if color != model.color { text.set(1, value: Cell.bytes(color), interval: 3) }
                if alignment != model.alignment { text.setAlignment(alignment) }
                return text
            }
            if blank, text.isEmpty { return nil }
            var made = SPen.Text()
            made.string = text
            let length = UInt32(text.utf16.count)
            made.spans = [SPen.Span(type: 3, start: 0, end: length, value: Cell.bytes(fontSize)), SPen.Span(type: 1, start: 0, end: length, value: Cell.bytes(color))]
            for (type, set) in [(UInt32(5), bold), (6, italic), (7, underline), (20, strikethrough)] where set { made.spans.append(SPen.Span(type: type, start: 0, end: length, value: SPen.Text.on(type))) }
            // Every line says how it is aligned and, once something was written in the cell, that it has been read.
            for line in 0..<UInt32(text.utf16.filter { $0 == 0x0A }.count + 1) {
                made.paragraphs.append(SPen.Paragraph(type: 3, start: line, end: line + 1, value: [UInt8(min(max(alignment, 0), 3)), 0, 0, 0, 0, 0, 0, 0]))
                if !text.isEmpty { made.paragraphs.append(SPen.Paragraph(type: 6, start: line, end: line + 1, value: [UInt8](repeating: 0, count: 8))) }
            }
            made.margins = (8, 4, 8, 4)
            return made
        }

        /// The cell's text piece by piece, each in its own style: more than one piece only for
        /// a cell that another client formatted in parts.
        public var runs: [Run] {
            guard !text.isEmpty else { return [] }
            guard let written else { return [Run(text: text, bold: bold, italic: italic, underline: underline, strikethrough: strikethrough, fontSize: fontSize, color: color)] }
            return written.runs.map { Run(text: $0.text, bold: $0.bold, italic: $0.italic, underline: $0.underline, strikethrough: $0.strikethrough, fontSize: $0.size ?? fontSize, color: $0.color ?? color) }
        }
    }

    /// What a row says of itself besides its cells.
    struct Row: Equatable, Sendable {
        var props: [UInt8] = [0]
        var flagBytes = 2
        var flags: UInt64 = 0
        /// The height the row is given by name: its drawn height, rounded up.
        var height: Float = 0
        /// What the flags announce after the cells (a least or greatest height), as read.
        var extra: [UInt8] = []
    }

    public var id: String
    /// Microseconds since 1970.
    public var modified: Int64
    public var appended: Int64
    public var pageWidth: Int
    public var pageIndex: Int
    /// The widths of the columns, in page units.
    public var columnWidths: [Float]
    public var rows: [[Cell]]
    var rowInfo: [Row]
    /// The lines between the rows and between the columns (one more than there are of each),
    /// in page units on the table's page.
    var ys: [Double]
    var xs: [Double]
    /// The table's rectangle on its page.
    public private(set) var rect: CGRect
    /// The rectangle it was first made at, which its outline keeps.
    var madeAt: (Double, Double, Double, Double)

    // The table's own fields, each there only when the record has it.
    var tableProps: [UInt8] = [0x04]
    var leastColumnWidth: Float?
    var leastRowHeight: Float?
    var border: [UInt8]?
    var autoFit: UInt8?
    var columnLeast: [Float]?
    var columnMost: [Float]?
    var mostHeight: Float?
    var mostWidth: Float?
    var cellBorder: [UInt8]?
    var headingBackground: UInt32?
    var defaultBackground: UInt32?

    /// The frames of the object as read (what every object has, its outline, its shape); nil
    /// for a table made here.
    var baseFrame: SPen.Frame?
    var outlineFrame: SPen.Frame?
    var shapeFrame: SPen.Frame?
    /// Where in the first frame's optional part its time of adding and its page stand.
    var appendedAt: Int?
    var pageIndexAt: Int?
    /// True once the cells were given new places here: until then every rectangle is written as it was read.
    var relaid = false

    public static func == (a: SamsungTable, b: SamsungTable) -> Bool { a.binary == b.binary }

    public var columns: Int { columnWidths.count }
    /// The cells' texts, row by row.
    public var texts: [[String]] { rows.map { $0.map(\.text) } }

    /// The twelve bytes every record of the sync document begins with.
    static let header: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x04, 0, 0, 0, 0xA0, 0x0F, 0, 0]
    static let plainBorderColor: UInt32 = 0xFFB1_AC98

    /// The margin the cells keep from the table's rectangle: half the width of the widest side
    /// of its outer border that is drawn (0.15 with the hairline of a new table, nothing
    /// without an outer border).
    private var hairline: Double {
        let widest = SamsungTable.sides(border).filter { $0.color != 0 && $0.width > 0 }.map(\.width).max() ?? 0
        return SPen.single(Double(widest / 2))
    }

    // MARK: Looks

    /// One side of a border: its colour, its width, and how round its two ends are.
    struct Side: Equatable { var color: UInt32; var width: Float; var start: Float; var end: Float }

    /// The four sides of a border record: left, top, right, bottom.
    static func sides(_ record: [UInt8]?) -> [Side] {
        guard let record, record.count >= 9 + 64 else { return [] }
        var reader = SPen.Reader(record, from: 9, to: record.count)
        return (0..<4).compactMap { _ in
            guard let color = try? reader.u32(), let width = try? reader.f32(), let start = try? reader.f32(), let end = try? reader.f32() else { return nil }
            return Side(color: color, width: width, start: start, end: end)
        }
    }

    static func record(_ sides: [Side]) -> [UInt8] {
        var out = SPen.Writer()
        out.u32(0); out.raw([1, 0]); out.raw([2, 0, 0])
        for side in sides { out.u32(side.color); out.f32(side.width); out.f32(side.start); out.f32(side.end) }
        return out.bytes
    }

    /// The first row is set apart as the table's heading, and so the first column: Samsung's
    /// clients then draw it on the heading's paper, and set its text bold in a colour that goes with it.
    public var headingRow: Bool { (tableProps.first ?? 0) & 2 != 0 }
    public var headingColumn: Bool { (tableProps.first ?? 0) & 1 != 0 }

    public mutating func setHeading(row: Bool? = nil, column: Bool? = nil) {
        if tableProps.isEmpty { tableProps = [0x04] }
        let wasRow = headingRow, wasColumn = headingColumn
        if let row { tableProps[0] = row ? tableProps[0] | 2 : tableProps[0] & ~2 }
        if let column { tableProps[0] = column ? tableProps[0] | 1 : tableProps[0] & ~1 }
        let ink = SamsungTable.headingInk(for: headingBackground ?? SamsungTable.headings[0])
        // The cells that became part of a heading, or ceased to be, are set as the clients set them.
        for rowIndex in rows.indices {
            for columnIndex in rows[rowIndex].indices {
                let was = (wasRow && rowIndex == 0) || (wasColumn && columnIndex == 0)
                let now = (headingRow && rowIndex == 0) || (headingColumn && columnIndex == 0)
                guard was != now else { continue }
                rows[rowIndex][columnIndex].bold = now
                rows[rowIndex][columnIndex].color = now ? ink : 0xFF25_2525
                if now { rows[rowIndex][columnIndex].italic = false; rows[rowIndex][columnIndex].underline = false; rows[rowIndex][columnIndex].strikethrough = false }
            }
        }
        settle()
    }

    /// The papers the clients offer for cells, and for each the paper of a heading and the
    /// colour of a heading's text that go with it; the first of each goes with no paper at all.
    public static let papers: [UInt32] = [0xFFF9_F9DE, 0xFFFA_EFDC, 0xFFF9_E7E1, 0xFFEA_E1FB, 0xFFDA_ECFB, 0xFFE6_F5E0]
    static let headings: [UInt32] = [0xFFEE_EBE7, 0xFFF4_F0C4, 0xFFF4_E3C6, 0xFFF3_D7CD, 0xFFDB_CEF5, 0xFFC5_E0F5, 0xFFD6_ECCC]
    static let headingInks: [UInt32] = [0xFF3A_3A3D, 0xFF83_7B2A, 0xFFA0_6110, 0xFFC4_613D, 0xFF6E_2A83, 0xFF2F_528B, 0xFF5B_7B41]

    /// The paper of a heading in a table whose cells are on this paper.
    static func heading(for paper: UInt32) -> UInt32 {
        if paper >> 24 == 0 { return headings[0] }
        if let index = papers.firstIndex(of: paper) { return headings[index + 1] }
        // A colour of one's own: a tenth of the way to a warm grey.
        func mixed(_ shift: UInt32, _ toward: Double) -> UInt32 { UInt32((0.9 * Double((paper >> shift) & 0xFF) + 0.1 * toward).rounded(.down)) << shift }
        return (paper & 0xFF00_0000) | mixed(16, 0x46) | mixed(8, 0x40) | mixed(0, 0x2E)
    }

    static func headingInk(for heading: UInt32) -> UInt32 { headings.firstIndex(of: heading).map { headingInks[$0] } ?? 0xFF25_2525 }

    /// Gives every cell one paper (0 for none), and the heading the paper that goes with it.
    public mutating func setPaper(_ paper: UInt32) {
        for row in rows.indices { for column in rows[row].indices { rows[row][column].background = paper; rows[row][column].ownsBackground = true } }
        headingBackground = SamsungTable.heading(for: paper)
        let ink = SamsungTable.headingInk(for: headingBackground ?? 0)
        for row in rows.indices { for column in rows[row].indices where (headingRow && row == 0) || (headingColumn && column == 0) { rows[row][column].color = ink } }
        settle()
    }

    /// The paper a cell is drawn on: a heading's, its own, or the table's; 0 for none.
    public func paper(row: Int, column: Int) -> UInt32 {
        if (headingRow && row == 0) || (headingColumn && column == 0) { return headingBackground ?? 0 }
        guard let cell = rows[safe: row]?[safe: column] else { return 0 }
        return cell.ownsBackground ? cell.background : (defaultBackground ?? 0)
    }

    /// How a table's lines are drawn: the five ways the clients offer.
    public enum Lines: Int, CaseIterable, Sendable {
        /// All lines, the outer edge rounded: what a new table has.
        case rounded
        /// All lines, square corners.
        case grid
        /// Lines above and below every row, none between columns.
        case horizontal
        /// A line above the table and one below it.
        case topAndBottom
        case none
    }

    /// Read from the two borders as the Windows client reads it.
    public var lines: Lines {
        let outer = SamsungTable.sides(border), inner = SamsungTable.sides(cellBorder)
        guard outer.count == 4 else { return inner.count == 4 && inner[1].width > 0 ? .horizontal : .none }
        if outer[0].start > 0 { return .rounded }
        if outer[1].width > 0 { return outer[0].width > 0 ? .grid : .topAndBottom }
        if inner.count == 4, inner[1].width > 0 { return .horizontal }
        return .none
    }

    public mutating func setLines(_ lines: Lines) {
        let color = SamsungTable.plainBorderColor
        let line = Side(color: color, width: 0.3, start: 0, end: 0), none = Side(color: 0, width: 0, start: 0, end: 0)
        switch lines {
        case .rounded: border = SamsungTable.record(Array(repeating: Side(color: color, width: 0.3, start: 12, end: 12), count: 4)); cellBorder = SamsungTable.record([line, line, line, line])
        case .grid: border = SamsungTable.record([line, line, line, line]); cellBorder = SamsungTable.record([line, line, line, line])
        case .horizontal: border = SamsungTable.record([none, none, none, none]); cellBorder = SamsungTable.record([none, line, none, line])
        case .topAndBottom: border = SamsungTable.record([none, line, none, line]); cellBorder = SamsungTable.record([none, none, none, none])
        case .none: border = SamsungTable.record([none, none, none, none]); cellBorder = SamsungTable.record([none, none, none, none])
        }
        settle()
    }

    /// Page units per unit of text size on a page this wide.
    static func density(_ pageWidth: Int) -> Double { Double(pageWidth) / 360 }

    /// The widest the table may be, and the narrowest a column.
    public var maxWidth: Float { mostWidth ?? columnMost?.first ?? columnWidths.reduce(0, +) }
    public var minColumnWidth: Float { columnLeast?.first ?? leastColumnWidth ?? maxWidth / 10 }

    // MARK: Reading

    /// Reads a table from its record. Nil when it is no table record this client can follow.
    public init?(binary: Data) {
        do { try self.init(record: [UInt8](binary)) } catch { return nil }
    }

    private static func head(_ reader: inout SPen.Reader) throws -> (flexAt: Int, props: [UInt8], flagBytes: Int, flags: UInt64) {
        let flexAt = Int(try reader.u32())
        let props = Array(try reader.take(Int(try reader.u8())))
        let count = Int(try reader.u8())
        guard count <= 8 else { throw SPen.Failure.unexpected("flags") }
        let flags = try reader.take(count).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        return (flexAt, props, count, flags)
    }

    private init(record all: [UInt8]) throws {
        guard all.count > 12, Array(all[0..<12]) == SamsungTable.header else { throw SPen.Failure.unexpected("no record header") }
        var reader = SPen.Reader(all, from: 12, to: all.count)
        let base = try SPen.Frame(&reader), outline = try SPen.Frame(&reader), shape = try SPen.Frame(&reader), table = try SPen.Frame(&reader)
        guard base.type == 0, outline.type == 6, shape.type == 7, table.type == 22, reader.isAtEnd else { throw SPen.Failure.unexpected("frames") }
        baseFrame = base; outlineFrame = outline; shapeFrame = shape

        // What every object has.
        var fixed = SPen.Reader(base.fixed)
        _ = try fixed.u32()
        id = String(decoding: try fixed.take(Int(try fixed.u16())), as: UTF8.self)
        modified = try fixed.i64()
        let box = try fixed.rect()
        rect = CGRect(x: box.l, y: box.t, width: box.r - box.l, height: box.b - box.t)
        var flex = SPen.Reader(base.flex)
        appended = 0; pageWidth = 0; pageIndex = 0
        // The optional fields come in the order of their flags; those this client has no use for are stepped over.
        let sizes: [(UInt64, Int)] = [(0x1, 4), (0x40, 4), (0x80, 8), (0x100, 8)]
        for (flag, size) in sizes where base.flags & flag != 0 { _ = try flex.take(size) }
        guard base.flags & (0x4 | 0x8 | 0x10 | 0x20) == 0 else { throw SPen.Failure.unexpected("base flags") }
        if base.flags & 0x2000 != 0 { appendedAt = flex.at; appended = try flex.i64() }
        if base.flags & 0x4000 != 0 { pageWidth = Int(try flex.u32()); _ = try flex.u32() }
        if base.flags & 0x8000 != 0 { _ = try flex.u8() }
        if base.flags & 0x10000 != 0 { _ = try flex.take(20) }
        if base.flags & 0x20000 != 0 { _ = try flex.take(4) }
        if base.flags & 0x40000 != 0 { _ = try flex.take(16) }
        guard base.flags & 0x80000 == 0 else { throw SPen.Failure.unexpected("base flags") }
        if base.flags & 0x100000 != 0 { pageIndexAt = flex.at; pageIndex = Int(try flex.i32()) }

        // The outline it was made with.
        var made = SPen.Reader(shape.fixed)
        _ = try made.take(4 + 32 + 4)
        madeAt = (box.l, box.t, box.r, box.b)
        var path = try made.sub(try made.count())
        if path.left >= 4 + 1 + 16 + 1 + 16 + 1 + 16 {
            _ = try path.u32(); _ = try path.u8()
            let left = try path.f64(), top = try path.f64()
            _ = try path.u8()
            let right = try path.f64()
            _ = try path.f64(); _ = try path.u8(); _ = try path.f64()
            let bottom = try path.f64()
            madeAt = (left, top, right, bottom)
        }

        // The table itself.
        tableProps = table.props
        var body = SPen.Reader(table.flex)
        columnWidths = []; rows = []; rowInfo = []; xs = []; ys = []
        let flags = table.flags
        guard table.flagBytes == 2, flags & ~0x3FFF == 0, flags & 0x1C == 0x1C else { throw SPen.Failure.unexpected("table flags") }
        if flags & 0x1 != 0 { leastColumnWidth = try body.f32() }
        if flags & 0x2 != 0 { leastRowHeight = try body.f32() }
        columnWidths = try (0..<(try body.count(each: 4))).map { _ in try body.f32() }
        for _ in 0..<(try body.count(each: 21)) {
            var row = try body.sub(try body.count())
            let start = row.at
            let rowHead = try SamsungTable.head(&row)
            var info = Row(props: rowHead.props, flagBytes: rowHead.flagBytes, flags: rowHead.flags)
            info.height = try row.f32()
            _ = try row.u32()
            var cells: [Cell] = []
            for _ in 0..<(try row.count(each: 60)) {
                var cell = try row.sub(try row.count())
                let cellStart = cell.at
                let cellHead = try SamsungTable.head(&cell)
                _ = try cell.u32()
                let rowSpan = try cell.u32(), columnSpan = try cell.u32()
                guard rowSpan == 1, columnSpan == 1 else { throw SPen.Failure.unexpected("merged cells") }
                let background = try cell.u32()
                let place = try cell.rect()
                let mark = try cell.u8()
                var content = try cell.sub(try cell.count())
                var frames: [SPen.Frame] = []
                while !content.isAtEnd { frames.append(try SPen.Frame(&content)) }
                guard let cellBase = frames.first(where: { $0.type == 0 }) else { throw SPen.Failure.unexpected("cell without a text box") }
                var name = SPen.Reader(cellBase.fixed)
                _ = try name.u32()
                var made = Cell(id: String(decoding: try name.take(Int(try name.u16())), as: UTF8.self))
                made.background = background
                made.props = cellHead.props; made.flagBytes = cellHead.flagBytes; made.flags = cellHead.flags
                made.place = place
                made.mark = mark
                made.frames = frames
                if let cellShape = frames.first(where: { $0.type == 7 }), let text = try SPen.text(ofShape: cellShape) { made.adopt(text) } else { made.blank = true }
                // What follows the text box is there only when a flag says so, and begins where the cell says.
                if cellHead.flags != 0 { guard cell.at - cellStart == cellHead.flexAt else { throw SPen.Failure.unexpected("cell layout") } }
                made.extra = Array(try cell.take(cell.left))
                cells.append(made)
            }
            if rowHead.flags != 0 { guard row.at - start == rowHead.flexAt else { throw SPen.Failure.unexpected("row layout") } }
            info.extra = Array(try row.take(row.left))
            rows.append(cells)
            rowInfo.append(info)
        }
        _ = try body.rect()
        if flags & 0x20 != 0 { border = Array(try body.take(try body.count())) }
        if flags & 0x40 != 0 { autoFit = try body.u8() }
        if flags & 0x80 != 0 { columnLeast = try (0..<(try body.count(each: 4))).map { _ in try body.f32() } }
        if flags & 0x100 != 0 { columnMost = try (0..<(try body.count(each: 4))).map { _ in try body.f32() } }
        if flags & 0x200 != 0 { mostHeight = try body.f32() }
        if flags & 0x400 != 0 { mostWidth = try body.f32() }
        if flags & 0x800 != 0 { cellBorder = Array(try body.take(try body.count())) }
        if flags & 0x1000 != 0 { headingBackground = try body.u32() }
        if flags & 0x2000 != 0 { defaultBackground = try body.u32() }
        guard body.isAtEnd else { throw SPen.Failure.unexpected("table tail") }

        guard !rows.isEmpty, let first = rows.first, !first.isEmpty, rows.allSatisfy({ $0.count == first.count }) else { throw SPen.Failure.unexpected("no cells") }
        if columnWidths.count != first.count { columnWidths = first.map { Float($0.place.r - $0.place.l) } }
        xs = first.map(\.place.l) + [first[first.count - 1].place.r]
        ys = rows.map { $0[0].place.t } + [rows[rows.count - 1][0].place.b]
    }

    // MARK: Making

    /// A border as the clients give a new table: four sides of a colour, a hairline wide, and
    /// two measures more (twelve and twelve for the table's own, rounded, edge).
    static func plainBorder(_ second: Float, _ third: Float, color: UInt32 = SamsungTable.plainBorderColor) -> [UInt8] {
        var out = SPen.Writer()
        out.u32(0); out.raw([1, 0]); out.raw([2, 0, 0])
        for _ in 0..<4 { out.u32(color); out.f32(0.3); out.f32(second); out.f32(third) }
        return out.bytes
    }

    /// A new table of empty cells: as wide as the text's column on a page `pageWidth` wide,
    /// its columns of one width, set with its top at `top`.
    public init(rows: Int, columns: Int, pageWidth: Int, pageIndex: Int = 0, top: Double, now: Date = Date()) {
        let count = min(max(columns, 1), SamsungTable.most)
        let stamp = Int64(now.timeIntervalSince1970 * 1_000_000)
        id = UUID().uuidString.lowercased()
        modified = stamp
        appended = stamp
        self.pageWidth = pageWidth
        self.pageIndex = pageIndex
        let density = SamsungTable.density(pageWidth)
        // The column of the text, to whole units: sixteen units of text size in from either edge.
        let margin = (16 * density).rounded()
        let width = Float(Double(pageWidth) - 2 * margin)
        mostWidth = width
        columnLeast = Array(repeating: width / 10, count: count)
        columnMost = Array(repeating: width, count: count)
        border = SamsungTable.plainBorder(12, 12)
        cellBorder = SamsungTable.plainBorder(0, 0)
        headingBackground = 0xFFEE_EBE7
        columnWidths = Array(repeating: width / Float(count), count: count)
        self.rows = (0..<min(max(rows, 1), SamsungTable.most)).map { _ in (0..<count).map { _ in Cell() } }
        rowInfo = self.rows.map { _ in Row() }
        xs = []; ys = []
        rect = .zero
        madeAt = (0, 0, 0, 0)
        layOut(left: 16 * density + hairline, top: top)
        let height = Double(rowInfo.map(\.height).reduce(0, +))
        madeAt = (margin, (10 * density).rounded(), Double(pageWidth) - margin, (10 * density).rounded() + height)
    }

    /// The height a row needs for its tallest cell: the cell's lines at 1.35 times its text's
    /// size, and four units above and below. Summed as the engine sums it, in 32-bit floats:
    /// a table laid out here comes out to the last bit as Samsung's clients lay it out.
    private func extent(ofRow cells: [Cell]) -> Float {
        let density = Float(SamsungTable.density(pageWidth))
        let margin = 4 * density
        var tallest: Float = 0
        for (column, cell) in cells.enumerated() {
            // A cell formatted in parts is measured by its largest text.
            let size = (cell.runs.map(\.fontSize).max() ?? cell.fontSize) * density
            let line = size * 1.35
            let width = max(Double(columnWidths[safe: column] ?? 0) - Double(4 * margin), Double(size))
            let lines = SamsungTable.lineCount(cell.text, size: Double(size), bold: cell.bold, italic: cell.italic, width: width)
            tallest = max(tallest, (Float(lines) * line + margin) + margin)
        }
        return tallest
    }

    /// How many lines a text takes when it is set this wide.
    static func lineCount(_ text: String, size: Double, bold: Bool, italic: Bool, width: Double) -> Int {
        guard !text.isEmpty else { return 1 }
        var font = CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil) ?? CTFontCreateWithName("Helvetica Neue" as CFString, CGFloat(size), nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, CGFloat(size), nil, traits, traits) { font = styled }
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let setter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil), nil)
        return max((CTFrameGetLines(frame) as? [CTLine])?.count ?? 1, 1)
    }

    /// Works out the lines between the cells and the table's rectangle from its place, its
    /// columns' widths and what its rows hold, with the engine's own 32-bit sums.
    public mutating func layOut(left: Double, top: Double) {
        let hair = hairline
        let l = SPen.single(left), t = SPen.single(top)
        while rowInfo.count < rows.count { rowInfo.append(Row()) }
        if rowInfo.count > rows.count { rowInfo.removeLast(rowInfo.count - rows.count) }
        var across = [hair]
        for width in columnWidths { across.append(SPen.single(across[across.count - 1] + Double(width))) }
        var down = [hair]
        for (index, row) in rows.enumerated() {
            let extent = extent(ofRow: row)
            down.append(SPen.single(down[down.count - 1] + Double(extent)))
            rowInfo[index].height = extent.rounded(.up)
        }
        xs = across.map { SPen.single(l + $0) }
        ys = down.map { SPen.single(t + $0) }
        let right = SPen.single(l + SPen.single(across[across.count - 1] - hair)), bottom = SPen.single(t + SPen.single(down[down.count - 1] - hair))
        rect = CGRect(x: l, y: t, width: right - l, height: bottom - t)
        for row in rows.indices {
            for column in rows[row].indices { rows[row][column].place = (xs[safe: column] ?? 0, ys[safe: row] ?? 0, xs[safe: column + 1] ?? 0, ys[safe: row + 1] ?? 0) }
        }
        relaid = true
    }

    /// Lays the table out again where it stands: after its texts, its columns or its rows changed.
    public mutating func settle() { layOut(left: rect.minX, top: rect.minY) }

    /// Moves the table so that its top left corner is at a place on its page.
    public mutating func move(to origin: CGPoint) {
        guard origin.x.isFinite, origin.y.isFinite else { return }
        layOut(left: origin.x, top: origin.y)
    }

    /// The height the table has once laid out anew: for making room for it before it is placed.
    public var laidOutHeight: Double {
        var copy = self
        copy.settle()
        return copy.rect.height
    }

    // MARK: Changing

    /// A cell for a new row or column: empty, set like the cell beside it.
    private func fresh(like model: Cell?) -> Cell {
        var cell = Cell()
        if let model {
            cell.fontSize = model.fontSize; cell.color = model.color; cell.alignment = model.alignment
            cell.background = model.background
            cell.ownsBackground = model.ownsBackground
        }
        return cell
    }

    /// The same table with other texts in its cells, row by row; rows and columns come and go
    /// at the end with the texts. Cells that stay keep their ids and styles. The table is laid out anew.
    /// `bold` and `italic`, where given, say for each cell whether all of its text is.
    public func with(texts: [[String]], bold: [[Bool]]? = nil, italic: [[Bool]]? = nil, now: Date = Date()) -> SamsungTable {
        var out = self
        let count = min(max(texts.map(\.count).max() ?? 1, 1), SamsungTable.most)
        let model = rows.first?.first
        out.rows = texts.prefix(SamsungTable.most).enumerated().map { rowIndex, row in
            (0..<count).map { column in
                var cell = rows[safe: rowIndex]?[safe: column] ?? fresh(like: model)
                cell.text = row[safe: column] ?? ""
                if let on = bold?[safe: rowIndex]?[safe: column] { cell.bold = on }
                if let on = italic?[safe: rowIndex]?[safe: column] { cell.italic = on }
                return cell
            }
        }
        if out.rows.isEmpty { out.rows = [(0..<count).map { _ in fresh(like: model) }] }
        if count != columns { out.columnWidths = Array(repeating: maxWidth / Float(count), count: count) }
        out.modified = Int64(now.timeIntervalSince1970 * 1_000_000)
        out.settle()
        return out
    }

    public mutating func insertRow(at index: Int) {
        let at = min(max(index, 0), rows.count)
        guard rows.count < SamsungTable.most else { return }
        let model = rows[safe: at == 0 ? 0 : at - 1] ?? []
        rows.insert((0..<columns).map { fresh(like: model[safe: $0]) }, at: at)
        rowInfo.insert(Row(), at: min(at, rowInfo.count))
        settle()
    }

    public mutating func removeRow(at index: Int) {
        guard rows.count > 1, rows.indices.contains(index) else { return }
        rows.remove(at: index)
        if rowInfo.indices.contains(index) { rowInfo.remove(at: index) }
        settle()
    }

    /// A new column takes the width of the one beside it; when the table would grow wider
    /// than it may be, all columns give way in proportion.
    public mutating func insertColumn(at index: Int) {
        let at = min(max(index, 0), columns)
        guard columns < SamsungTable.most else { return }
        let beside = at == 0 ? 0 : at - 1
        columnWidths.insert(columnWidths[safe: beside] ?? maxWidth / 4, at: at)
        for row in rows.indices { rows[row].insert(fresh(like: rows[row][safe: beside]), at: min(at, rows[row].count)) }
        fitWithin()
        settle()
    }

    public mutating func removeColumn(at index: Int) {
        guard columns > 1, columnWidths.indices.contains(index) else { return }
        columnWidths.remove(at: index)
        for row in rows.indices where rows[row].indices.contains(index) { rows[row].remove(at: index) }
        settle()
    }

    private mutating func fitWithin() {
        let total = columnWidths.reduce(0, +), most = maxWidth
        guard total > most, total > 0 else { return }
        columnWidths = columnWidths.map { max($0 * most / total, 1) }
    }

    /// Gives a column another width: not narrower than a column may be, and not so wide that
    /// the table would be wider than it may be.
    public mutating func setWidth(_ width: Float, ofColumn index: Int) {
        guard columnWidths.indices.contains(index), width.isFinite else { return }
        let others = columnWidths.enumerated().filter { $0.offset != index }.map(\.element).reduce(0, +)
        columnWidths[index] = min(max(width, minColumnWidth), max(maxWidth - others, minColumnWidth))
        settle()
    }

    /// Makes the table as wide as it may be, all its columns of one width: what the clients'
    /// "fit" does.
    public mutating func fitToWidth() {
        guard columns > 0 else { return }
        columnWidths = Array(repeating: maxWidth / Float(columns), count: columns)
        settle()
    }

    /// True when "fit" would change something.
    public var canFit: Bool { Set(columnWidths).count > 1 || abs(columnWidths.reduce(0, +) - maxWidth) >= 1 }

    /// The most rows, and the most columns, the clients let a table have.
    public static let most = 30

    /// Changes cells in place and lays the table out again. `where` picks the cells by row and column.
    public mutating func change(where picked: (Int, Int) -> Bool = { _, _ in true }, _ change: (inout Cell) -> Void) {
        for row in rows.indices { for column in rows[row].indices where picked(row, column) { change(&rows[row][column]) } }
        settle()
    }

    public mutating func touch(_ now: Date = Date()) { modified = Int64(now.timeIntervalSince1970 * 1_000_000) }

    // MARK: Writing

    private static func head(_ out: inout SPen.Writer, props: [UInt8], flagBytes: Int, flags: UInt64, fixed: Int) {
        let header = 4 + 1 + props.count + 1 + flagBytes
        out.u32(flags == 0 ? 0 : UInt32(header + fixed))
        out.u8(UInt8(props.count)); out.raw(props)
        out.u8(UInt8(flagBytes))
        for index in 0..<flagBytes { out.u8(UInt8((flags >> UInt64(8 * index)) & 0xFF)) }
    }

    private static func put(_ rect: (Double, Double, Double, Double), into bytes: inout [UInt8], at offset: Int) {
        var out = SPen.Writer()
        out.rect(rect.0, rect.1, rect.2, rect.3)
        guard offset >= 0, offset + 32 <= bytes.count else { return }
        bytes.replaceSubrange(offset..<(offset + 32), with: out.bytes)
    }

    private func textBox(_ cell: Cell) -> [UInt8] {
        let box = (cell.place.l, cell.place.t, cell.place.r, cell.place.b)
        let record = cell.written?.bytes
        guard var frames = cell.frames else {
            return SPen.baseFrame(props: [0xBF, 0x01], formatVersion: 4000, id: cell.id, modified: 0, rect: box, ownerPage: (UInt32(pageWidth), 0)).bytes
                + SPen.shapeBaseFrame(points: SPen.connectionPoints(box.0, box.1, box.2, box.3), line: true).bytes
                + SPen.shapeFrame(rect: box, path: SPen.rectPath(box.0, box.1, box.2, box.3), text: record, ellipsis: 0, autoFit: 2).bytes
                + SPen.textBoxFrame.bytes
        }
        // As it was read, but for its text and, once the table was laid out here, its place.
        for index in frames.indices {
            switch frames[index].type {
            case 0 where relaid:
                let name = Int(frames[index].fixed[safe: 4] ?? 0) | Int(frames[index].fixed[safe: 5] ?? 0) << 8
                SamsungTable.put(box, into: &frames[index].fixed, at: 6 + name + 8)
            case 6 where relaid:
                // Its four points, when it has four: the middles of its sides.
                guard frames[index].fixed.count >= 4 + 64, frames[index].fixed[0] == 4, frames[index].fixed[1] == 0 else { break }
                var points = SPen.Writer()
                for point in SPen.connectionPoints(box.0, box.1, box.2, box.3) { points.f64(point.0); points.f64(point.1) }
                frames[index].fixed.replaceSubrange(4..<68, with: points.bytes)
            case 7:
                if relaid {
                    SamsungTable.put(box, into: &frames[index].fixed, at: 4)
                    // Its outline, when it is the plain rectangle of five steps.
                    let path = SPen.rectPath(box.0, box.1, box.2, box.3)
                    if frames[index].fixed.count >= 44 + path.count, Array(frames[index].fixed[40..<44]) == [UInt8(path.count), 0, 0, 0] {
                        frames[index].fixed.replaceSubrange(44..<(44 + path.count), with: path)
                    }
                }
                // Its text is the first of its optional fields.
                var rest = frames[index].flex
                if frames[index].flags & 1 != 0, rest.count >= 4 {
                    let length = Int(rest[0]) | Int(rest[1]) << 8 | Int(rest[2]) << 16 | Int(rest[3]) << 24
                    rest = Array(rest.dropFirst(4 + min(max(length, 0), rest.count - 4)))
                }
                if let record {
                    var text = SPen.Writer()
                    text.sized(record)
                    frames[index].flex = text.bytes + rest
                    frames[index].flags |= 1
                } else {
                    frames[index].flex = rest
                    frames[index].flags &= ~1
                }
            default: break
            }
        }
        return frames.flatMap(\.bytes)
    }

    /// The table as its record, with the twelve bytes every record begins with.
    public var binary: Data {
        let box = (Double(rect.minX), Double(rect.minY), Double(rect.maxX), Double(rect.maxY))
        var flags: UInt64 = 0x1C
        var flex = SPen.Writer()
        if let leastColumnWidth { flags |= 0x1; flex.f32(leastColumnWidth) }
        if let leastRowHeight { flags |= 0x2; flex.f32(leastRowHeight) }
        flex.u32(UInt32(columns))
        for width in columnWidths { flex.f32(width) }
        flex.u32(UInt32(rows.count))
        for (index, row) in rows.enumerated() {
            let info = rowInfo[safe: index] ?? Row()
            var cells = SPen.Writer()
            for (column, cell) in row.enumerated() {
                var fixed = SPen.Writer()
                fixed.u32(UInt32(column)); fixed.u32(1); fixed.u32(1); fixed.u32(cell.background)
                fixed.rect(cell.place.l, cell.place.t, cell.place.r, cell.place.b)
                fixed.u8(cell.mark)
                fixed.sized(textBox(cell))
                var one = SPen.Writer()
                SamsungTable.head(&one, props: cell.props, flagBytes: cell.flagBytes, flags: cell.flags, fixed: fixed.bytes.count)
                one.raw(fixed.bytes)
                one.raw(cell.extra)
                cells.sized(one.bytes)
            }
            var fixed = SPen.Writer()
            fixed.f32(info.height)
            fixed.u32(UInt32(index))
            fixed.u32(UInt32(row.count))
            fixed.raw(cells.bytes)
            var out = SPen.Writer()
            SamsungTable.head(&out, props: info.props, flagBytes: info.flagBytes, flags: info.flags, fixed: fixed.bytes.count)
            out.raw(fixed.bytes)
            out.raw(info.extra)
            flex.sized(out.bytes)
        }
        flex.rect(box.0, box.1, box.2, box.3)
        if let border { flags |= 0x20; flex.sized(border) }
        if let autoFit { flags |= 0x40; flex.u8(autoFit) }
        func widths(_ kept: [Float]) -> [Float] { (0..<columns).map { kept[safe: $0] ?? kept.last ?? 0 } }
        if let columnLeast { flags |= 0x80; flex.u32(UInt32(columns)); for width in widths(columnLeast) { flex.f32(width) } }
        if let columnMost { flags |= 0x100; flex.u32(UInt32(columns)); for width in widths(columnMost) { flex.f32(width) } }
        if let mostHeight { flags |= 0x200; flex.f32(mostHeight) }
        if let mostWidth { flags |= 0x400; flex.f32(mostWidth) }
        if let cellBorder { flags |= 0x800; flex.sized(cellBorder) }
        if let headingBackground { flags |= 0x1000; flex.u32(headingBackground) }
        if let defaultBackground { flags |= 0x2000; flex.u32(defaultBackground) }

        var frames: [UInt8]
        if var base = baseFrame, let outlineFrame, var shape = shapeFrame {
            // As read, but for its time, its page and its place.
            let name = Int(base.fixed[safe: 4] ?? 0) | Int(base.fixed[safe: 5] ?? 0) << 8
            var stamp = SPen.Writer(); stamp.i64(modified)
            if 6 + name + 8 <= base.fixed.count { base.fixed.replaceSubrange((6 + name)..<(6 + name + 8), with: stamp.bytes) }
            SamsungTable.put(box, into: &base.fixed, at: 6 + name + 8)
            if let pageIndexAt, pageIndexAt + 4 <= base.flex.count {
                var page = SPen.Writer(); page.i32(Int32(pageIndex))
                base.flex.replaceSubrange(pageIndexAt..<(pageIndexAt + 4), with: page.bytes)
            }
            SamsungTable.put(box, into: &shape.fixed, at: 4)
            frames = base.bytes + outlineFrame.bytes + shape.bytes
        } else {
            frames = SPen.baseFrame(props: [0x3E, 0x01], formatVersion: 5400, id: id, modified: modified, rect: box, appended: appended,
                                    ownerPage: (UInt32(pageWidth), 0), layoutType: 3, pageIndex: Int32(pageIndex)).bytes
                + SPen.shapeBaseFrame(points: SPen.connectionPoints(madeAt.0, madeAt.1, madeAt.2, madeAt.3), line: false).bytes
                + SPen.shapeFrame(rect: box, path: SPen.rectPath(madeAt.0, madeAt.1, madeAt.2, madeAt.3)).bytes
        }
        frames += SPen.Frame(type: 22, props: tableProps, flagBytes: 2, flags: flags, fixed: [], flex: flex.bytes).bytes
        return Data(SamsungTable.header + frames)
    }

    /// The rectangle its outline keeps, in whole page units as the sync document has it.
    public var outline: CGRect { CGRect(x: madeAt.0, y: madeAt.1, width: madeAt.2 - madeAt.0, height: madeAt.3 - madeAt.1) }

    /// The rectangles of the cells, row by row, in page units from the table's top left corner.
    public var cellRects: [[CGRect]] {
        rows.map { row in row.map { CGRect(x: $0.place.l - rect.minX, y: $0.place.t - rect.minY, width: $0.place.r - $0.place.l, height: $0.place.b - $0.place.t) } }
    }

    /// The colour of the lines between the cells.
    public var lineColor: UInt32 {
        (SamsungTable.sides(cellBorder) + SamsungTable.sides(border)).first { $0.color >> 24 != 0 && $0.width > 0 }?.color ?? SamsungTable.plainBorderColor
    }
}
