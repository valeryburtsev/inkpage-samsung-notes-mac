import AppKit
import SamsungNotesKit
import SwiftUI
import zlib

/// What a sticky note or a table says while it is written in the note. New ones are stored in
/// Samsung's own forms (`StickyDocument`, `SamsungTable`). An earlier build of this app kept
/// them as pictures with their words in a text chunk of the PNG; those are still read here,
/// and changed in that form, so that notes holding them stay as they are.
enum SmartPicture: Codable, Equatable {
    case sticky(Sticky)
    case table(Table)

    struct Sticky: Codable, Equatable {
        var text = ""
        var color: UInt32 = 0xFFFF_E984
    }

    struct Table: Codable, Equatable {
        var cells: [[String]]
        var header = true
        /// For a table of Samsung's own kind: whether all of a cell's text is bold, or italic.
        var bold: [[Bool]]?
        var italic: [[Bool]]?

        init(rows: Int, columns: Int) { cells = Array(repeating: Array(repeating: "", count: max(columns, 1)), count: max(rows, 1)) }
        var columns: Int { cells.first?.count ?? 0 }

        func isBold(_ row: Int, _ column: Int) -> Bool { bold?[safe: row]?[safe: column] ?? false }
        func isItalic(_ row: Int, _ column: Int) -> Bool { italic?[safe: row]?[safe: column] ?? false }

        /// The styles cell for cell, as many as there are cells.
        private func squared(_ styles: [[Bool]]?) -> [[Bool]] {
            cells.indices.map { row in cells[row].indices.map { styles?[safe: row]?[safe: $0] ?? false } }
        }

        mutating func toggleBold(_ row: Int, _ column: Int) {
            var all = squared(bold)
            guard all.indices.contains(row), all[row].indices.contains(column) else { return }
            all[row][column].toggle()
            bold = all
        }

        mutating func toggleItalic(_ row: Int, _ column: Int) {
            var all = squared(italic)
            guard all.indices.contains(row), all[row].indices.contains(column) else { return }
            all[row][column].toggle()
            italic = all
        }
    }

    var isSticky: Bool { if case .sticky = self { return true }; return false }

    static let stickyColors: [UInt32] = [0xFFFF_E984, 0xFFFF_C5CC, 0xFFB9_F2E6, 0xFFC5_E1FB, 0xFFE6_DCFA, 0xFFFF_C494]

    var name: String {
        switch self {
        case .sticky: return "Sticky Note"
        case .table: return "Table"
        }
    }

    // MARK: In the picture's file

    private static let keyword = "snotes"
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func chunk(_ type: String, _ body: Data) -> Data {
        var out = Data()
        var length = UInt32(body.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        let typed = Data(type.utf8) + body
        out.append(typed)
        var sum = UInt32(truncatingIfNeeded: typed.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(typed.count)) }).bigEndian
        out.append(Data(bytes: &sum, count: 4))
        return out
    }

    /// The chunks of a PNG file: their types and where their bodies lie.
    private static func chunks(_ data: Data) -> [(type: String, body: Range<Int>, whole: Range<Int>)]? {
        let bytes = [UInt8](data)
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { return nil }
        var out: [(String, Range<Int>, Range<Int>)] = []
        var at = 8
        while at + 12 <= bytes.count {
            let length = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            guard length >= 0, at + 12 + length <= bytes.count else { return nil }
            out.append((String(decoding: bytes[(at + 4)..<(at + 8)], as: UTF8.self), (at + 8)..<(at + 8 + length), at..<(at + 12 + length)))
            at += 12 + length
        }
        return out
    }

    /// Writes what the picture says into a PNG file, in a text chunk before its end.
    func embedded(in png: Data) -> Data? {
        guard let json = try? JSONEncoder().encode(self), let found = SmartPicture.chunks(png), let end = found.last(where: { $0.type == "IEND" }) else { return nil }
        // An international text chunk: keyword, no compression, no language, no translation, the text.
        var body = Data(SmartPicture.keyword.utf8)
        body.append(contentsOf: [0, 0, 0, 0, 0])
        body.append(json)
        var out = png.subdata(in: 0..<end.whole.lowerBound)
        out.append(SmartPicture.chunk("iTXt", body))
        out.append(png.subdata(in: end.whole.lowerBound..<png.count))
        return out
    }

    /// Reads what a picture made here says, from its file; nil for any other picture.
    static func read(_ data: Data) -> SmartPicture? {
        guard let found = chunks(data) else { return nil }
        let prefix = Data(keyword.utf8) + Data([0, 0, 0, 0, 0])
        for entry in found where entry.type == "iTXt" {
            let body = data.subdata(in: (data.startIndex + entry.body.lowerBound)..<(data.startIndex + entry.body.upperBound))
            guard body.count > prefix.count, body.prefix(prefix.count) == prefix else { continue }
            guard let found = try? JSONDecoder().decode(SmartPicture.self, from: Data(body.dropFirst(prefix.count))) else { return nil }
            // A table has rows of one length, and not more of anything than a table here can have.
            if case .table(var table) = found {
                let columns = min(max(table.cells.map(\.count).max() ?? 1, 1), 8)
                table.cells = table.cells.prefix(40).map { row in Array(row.prefix(columns)) + Array(repeating: "", count: max(columns - row.count, 0)) }
                if table.cells.isEmpty { table.cells = [Array(repeating: "", count: columns)] }
                return .table(table)
            }
            return found
        }
        return nil
    }

    // MARK: As a picture

    /// The size a sticky note's text is set in, in pixels of its 640-pixel picture: as large as
    /// fits, smaller for a longer note.
    static func fittedSize(_ string: String) -> CGFloat {
        let room = CGSize(width: 640 - 88, height: 640 - 82 - 32)
        var points: CGFloat = 60
        while points > 22 {
            let text = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: points, weight: .medium)])
            if text.boundingRect(with: CGSize(width: room.width, height: 10_000), options: [.usesLineFragmentOrigin]).height <= room.height { break }
            points -= 4
        }
        return points
    }

    private static func bitmap(_ size: CGSize, _ draw: (CGRect) -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // y down, as text is read.
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: size.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        draw(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The picture that goes into the note, with what it says inside its file.
    func picture() -> PictureFile? {
        var size = CGSize.zero
        var made: Data?
        switch self {
        case .sticky(let sticky):
            size = CGSize(width: 640, height: 640)
            made = SmartPicture.bitmap(size) { area in
                PenChoice.nsColor(sticky.color).setFill()
                area.fill()
                // A darker strip along the top, where the glue would be.
                NSColor.black.withAlphaComponent(0.07).setFill()
                CGRect(x: 0, y: 0, width: area.width, height: 54).fill()
                let room = area.insetBy(dx: 44, dy: 0).divided(atDistance: 82, from: .minYEdge).remainder.insetBy(dx: 0, dy: 16)
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                let text = NSAttributedString(string: sticky.text, attributes: [.font: NSFont.systemFont(ofSize: SmartPicture.fittedSize(sticky.text), weight: .medium),
                                                                                .foregroundColor: NSColor(white: 0.13, alpha: 1), .paragraphStyle: style])
                text.draw(with: room, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        case .table(let table):
            let width: CGFloat = 1400, pad: CGFloat = 18
            let columns = max(table.columns, 1)
            let column = width / CGFloat(columns)
            func text(_ string: String, bold: Bool) -> NSAttributedString {
                NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 34, weight: bold ? .semibold : .regular), .foregroundColor: NSColor(white: 0.13, alpha: 1)])
            }
            // Each row is as high as its tallest cell.
            let heights: [CGFloat] = table.cells.enumerated().map { row, cells in
                let tallest = cells.map { text($0, bold: table.header && row == 0).boundingRect(with: CGSize(width: column - pad * 2, height: 10_000), options: [.usesLineFragmentOrigin]).height }.max() ?? 0
                return max(tallest.rounded(.up), 42) + pad * 2
            }
            size = CGSize(width: width, height: heights.reduce(0, +))
            made = SmartPicture.bitmap(size) { area in
                NSColor.white.setFill()
                area.fill()
                var y: CGFloat = 0
                for (row, cells) in table.cells.enumerated() {
                    if table.header, row == 0 {
                        NSColor(white: 0.93, alpha: 1).setFill()
                        CGRect(x: 0, y: y, width: width, height: heights[row]).fill()
                    }
                    for (index, cell) in cells.enumerated() {
                        text(cell, bold: table.header && row == 0).draw(with: CGRect(x: CGFloat(index) * column + pad, y: y + pad, width: column - pad * 2, height: heights[row] - pad * 2), options: [.usesLineFragmentOrigin])
                    }
                    y += heights[row]
                }
                NSColor(white: 0.55, alpha: 1).setStroke()
                let lines = NSBezierPath()
                lines.lineWidth = 2
                y = 0
                for height in [0] + heights {
                    y += height
                    lines.move(to: CGPoint(x: 0, y: min(max(y, 1), area.height - 1)))
                    lines.line(to: CGPoint(x: width, y: min(max(y, 1), area.height - 1)))
                }
                for index in 0...columns {
                    let x = min(max(CGFloat(index) * column, 1), width - 1)
                    lines.move(to: CGPoint(x: x, y: 0))
                    lines.line(to: CGPoint(x: x, y: area.height))
                }
                lines.stroke()
            }
        }
        guard let png = made, let data = embedded(in: png) else { return nil }
        return PictureFile(data: data, fileExtension: "png", pixels: size)
    }
}

/// A sticky note or a table that is being written in the note itself.
struct SmartLive: Equatable {
    /// The picture object it is kept as.
    var id: String
    var content: SmartPicture
    /// What it said when it was opened: nothing is stored when nothing changed.
    var original: SmartPicture
    /// True for one of Samsung's own kind (the only kind that is opened now).
    var real = false
}

/// A number chosen by turning a wheel of numbers, as in the Clock app: the one in the middle counts.
struct WheelPicker: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String
    @State private var position: Int?

    private let row: CGFloat = 46

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(range), id: \.self) { number in
                    let chosen = number == (position ?? value)
                    Text("\(number)")
                        .font(.system(size: 30, weight: .medium).monospacedDigit())
                        .foregroundStyle(chosen ? .primary : .tertiary)
                        .scaleEffect(chosen ? 1 : 0.82)
                        .animation(.easeOut(duration: 0.12), value: chosen)
                        .frame(width: 84, height: row)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { position = number } }
                        .id(number)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $position, anchor: .center)
        // Room above the first and below the last, so that either can come to the middle.
        .contentMargins(.vertical, row, for: .scrollContent)
        .scrollIndicators(.never)
        .frame(width: 84, height: row * 3)
        .background { RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.6)).frame(height: row - 4) }
        .onAppear { position = value }
        .onChange(of: position) { if let position, range.contains(position), position != value { value = position } }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            if direction == .up { step(-1) }
            if direction == .down { step(1) }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
    }

    private func step(_ by: Int) {
        let next = min(max((position ?? value) + by, range.lowerBound), range.upperBound)
        withAnimation(.easeOut(duration: 0.15)) { position = next }
    }
}

/// How many rows and columns a new table gets, as in the original's "Table properties".
struct TableSetup: View {
    let finish: (SmartPicture.Table?) -> Void
    @State private var rows = 3
    @State private var columns = 3
    @State private var header = true

    var body: some View {
        VStack(spacing: 16) {
            Text("Table properties").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .center, spacing: 18) {
                VStack(spacing: 8) {
                    Label("Rows", systemImage: "rectangle.split.1x2").font(.callout).foregroundStyle(.secondary)
                    WheelPicker(value: $rows, range: 1...30, label: "Rows")
                }
                Text("×").font(.title2).foregroundStyle(.tertiary).padding(.top, 26)
                VStack(spacing: 8) {
                    Label("Columns", systemImage: "rectangle.split.2x1").font(.callout).foregroundStyle(.secondary)
                    WheelPicker(value: $columns, range: 1...8, label: "Columns")
                }
            }
            Toggle("First row is a header", isOn: $header).toggleStyle(.checkbox)
            HStack(spacing: 12) {
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction).frame(maxWidth: .infinity)
                Button("Done") {
                    var table = SmartPicture.Table(rows: rows, columns: columns)
                    table.header = header && rows > 1
                    finish(table)
                }
                .keyboardShortcut(.defaultAction).frame(maxWidth: .infinity)
            }
        }
        .padding(22)
        .frame(width: 320)
    }
}

extension NoteSession {
    /// What a picture made here as a sticky note or a table says; nil for any other picture.
    func smartContent(_ id: String) -> SmartPicture? {
        guard let note, let hash = pictureObject(id)?.pictureFile, let url = note.fileURL(hash), let data = try? Data(contentsOf: url) else { return nil }
        return SmartPicture.read(data)
    }
}

/// Takes the presses that fall on it and does nothing with them: laid behind controls that
/// lie over the note's text, so that a press beside a control does not reach the text.
struct PointerShield: NSViewRepresentable {
    final class Shield: NSView {
        override func mouseDown(with event: NSEvent) {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> Shield { Shield() }
    func updateNSView(_ view: Shield, context: Context) {}
}
