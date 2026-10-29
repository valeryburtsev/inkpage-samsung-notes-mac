import Foundation

/// Reading and writing the binary records Samsung's engine keeps objects in: little-endian
/// numbers, and "frames" that say their own size, so that a reader can step over what it does
/// not know. A table of a note travels in this form (`tableBinary`), and so does the whole of
/// a sticky note's own document.
enum SPen {
    enum Failure: Error { case truncated, unexpected(String) }

    struct Reader {
        let bytes: [UInt8]
        var at: Int
        let end: Int

        init(_ bytes: [UInt8]) { self.bytes = bytes; at = 0; end = bytes.count }
        init(_ bytes: [UInt8], from: Int, to: Int) { self.bytes = bytes; at = from; end = to }

        var isAtEnd: Bool { at >= end }
        var left: Int { end - at }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, at + count <= end else { throw Failure.truncated }
            defer { at += count }
            return bytes[at..<(at + count)]
        }
        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func u16() throws -> UInt16 { try take(2).enumerated().reduce(UInt16(0)) { $0 | UInt16($1.element) << (8 * UInt16($1.offset)) } }
        mutating func u32() throws -> UInt32 { try take(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        mutating func u64() throws -> UInt64 { try take(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
        mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
        mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
        /// A count read from the record, kept to what the bytes that are left could hold.
        mutating func count(each size: Int = 1) throws -> Int {
            let value = Int(try u32())
            guard value >= 0, value * max(size, 1) <= left else { throw Failure.truncated }
            return value
        }
        /// A reader over the next `count` bytes, which this one steps over.
        mutating func sub(_ count: Int) throws -> Reader {
            guard count >= 0, at + count <= end else { throw Failure.truncated }
            defer { at += count }
            return Reader(bytes, from: at, to: at + count)
        }
        mutating func rect() throws -> (l: Double, t: Double, r: Double, b: Double) { (try f64(), try f64(), try f64(), try f64()) }
    }

    struct Writer {
        var bytes: [UInt8] = []
        mutating func u8(_ value: UInt8) { bytes.append(value) }
        mutating func u16(_ value: UInt16) { for shift in [0, 8] { bytes.append(UInt8((value >> UInt16(shift)) & 0xFF)) } }
        mutating func u32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
        mutating func u64(_ value: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8((value >> UInt64(shift)) & 0xFF)) } }
        mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
        mutating func i64(_ value: Int64) { u64(UInt64(bitPattern: value)) }
        mutating func f32(_ value: Float) { u32(value.bitPattern) }
        mutating func f64(_ value: Double) { u64(value.bitPattern) }
        mutating func raw(_ more: [UInt8]) { bytes.append(contentsOf: more) }
        mutating func rect(_ l: Double, _ t: Double, _ r: Double, _ b: Double) { f64(l); f64(t); f64(r); f64(b) }
        /// A piece with its length in front.
        mutating func sized(_ piece: [UInt8]) { u32(UInt32(piece.count)); raw(piece) }
    }

    /// One frame: its size, its kind, where its optional part begins, its properties and the
    /// flags that say which optional fields follow, then the fixed and the optional fields.
    struct Frame: Equatable, Sendable {
        var type: UInt16
        var props: [UInt8]
        var flagBytes: Int
        var flags: UInt64
        var fixed: [UInt8]
        var flex: [UInt8]

        init(type: UInt16, props: [UInt8], flagBytes: Int, flags: UInt64, fixed: [UInt8], flex: [UInt8] = []) {
            self.type = type; self.props = props; self.flagBytes = flagBytes; self.flags = flags; self.fixed = fixed; self.flex = flex
        }

        init(_ reader: inout Reader) throws {
            let start = reader.at
            let size = Int(try reader.u32())
            guard size >= 12, start + size <= reader.end else { throw Failure.truncated }
            type = try reader.u16()
            let flexOffset = Int(try reader.u32())
            props = Array(try reader.take(Int(try reader.u8())))
            flagBytes = Int(try reader.u8())
            guard flagBytes <= 8 else { throw Failure.unexpected("flags of \(flagBytes) bytes") }
            flags = try reader.take(flagBytes).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            let body = reader.at, finish = start + size
            let split = flags == 0 ? finish : start + flexOffset
            guard split >= body, split <= finish else { throw Failure.unexpected("frame \(type): optional part at \(flexOffset)") }
            fixed = Array(reader.bytes[body..<split])
            flex = Array(reader.bytes[split..<finish])
            reader.at = finish
        }

        var bytes: [UInt8] {
            var body = Writer()
            body.u16(type)
            let header = 4 + 2 + 4 + 1 + props.count + 1 + flagBytes
            body.u32(flags == 0 ? 0 : UInt32(header + fixed.count))
            body.u8(UInt8(props.count))
            body.raw(props)
            body.u8(UInt8(flagBytes))
            for index in 0..<flagBytes { body.u8(UInt8((flags >> UInt64(8 * index)) & 0xFF)) }
            body.raw(fixed)
            body.raw(flex)
            var out = Writer()
            out.u32(UInt32(4 + body.bytes.count))
            out.raw(body.bytes)
            return out.bytes
        }
    }

    /// A value rounded to what the engine keeps it as: a 32-bit float.
    static func single(_ value: Double) -> Double { Double(Float(value)) }

    /// A run of a text's characters with one property: its kind (as in the sync text: 1 the
    /// colour, 3 the size, 5 bold, 6 italic…), where it starts and ends, and eight bytes of value.
    struct Span: Equatable, Sendable {
        var type: UInt32
        var start: UInt32
        var end: UInt32
        var interval: UInt32 = 1
        var value: [UInt8]
    }

    /// A property of a run of lines: 3 the alignment, 6 the parsing state…
    struct Paragraph: Equatable, Sendable {
        var type: UInt32
        var start: UInt32
        var end: UInt32
        var value: [UInt8]
    }

    /// The text of a text box: its characters, their spans, the lines' properties, the margins.
    struct Text: Equatable, @unchecked Sendable {
        var string = ""
        var spans: [Span] = []
        var paragraphs: [Paragraph] = []
        var margins: (Float, Float, Float, Float) = (0, 0, 0, 0)
        var flag: UInt8 = 0
        var sections: [(UInt32, UInt32)] = []
        /// What follows the sections when the text holds objects (tables, pictures): kept as it came.
        var objects: [UInt8] = []
        var hasObjects = false

        static func == (a: Text, b: Text) -> Bool {
            a.string == b.string && a.spans == b.spans && a.paragraphs == b.paragraphs && a.margins == b.margins && a.flag == b.flag
                && a.sections.map { [$0.0, $0.1] } == b.sections.map { [$0.0, $0.1] } && a.objects == b.objects && a.hasObjects == b.hasObjects
        }

        init() {}

        init(_ reader: inout Reader) throws {
            let length = try reader.count(each: 2)
            let units = try reader.take(length * 2)
            string = String(decoding: stride(from: units.startIndex, to: units.endIndex, by: 2).map { UInt16(units[$0]) | UInt16(units[$0 + 1]) << 8 }, as: UTF16.self)
            for _ in 0..<(try reader.count(each: 18)) {
                var inner = try reader.sub(Int(try reader.u16()))
                let type = try inner.u32(), start = try inner.u32(), end = try inner.u32(), interval = try inner.u32()
                spans.append(Span(type: type, start: start, end: end, interval: interval, value: Array(try inner.take(inner.left))))
            }
            for _ in 0..<(try reader.count(each: 14)) {
                var inner = try reader.sub(Int(try reader.u16()))
                let type = try inner.u32(), start = try inner.u32(), end = try inner.u32()
                paragraphs.append(Paragraph(type: type, start: start, end: end, value: Array(try inner.take(inner.left))))
            }
            margins = (try reader.f32(), try reader.f32(), try reader.f32(), try reader.f32())
            flag = try reader.u8()
            for _ in 0..<Int(try reader.u16()) { sections.append((try reader.u32(), try reader.u32())) }
            hasObjects = try reader.u8() != 0
            _ = try reader.take(7)
            objects = Array(try reader.take(reader.left))
        }

        var bytes: [UInt8] {
            var out = Writer()
            let units = Array(string.utf16)
            out.u32(UInt32(units.count))
            for unit in units { out.u16(unit) }
            out.u32(UInt32(spans.count))
            for span in spans {
                out.u16(UInt16(16 + span.value.count))
                out.u32(span.type); out.u32(span.start); out.u32(span.end); out.u32(span.interval); out.raw(span.value)
            }
            out.u32(UInt32(paragraphs.count))
            for paragraph in paragraphs {
                out.u16(UInt16(12 + paragraph.value.count))
                out.u32(paragraph.type); out.u32(paragraph.start); out.u32(paragraph.end); out.raw(paragraph.value)
            }
            out.f32(margins.0); out.f32(margins.1); out.f32(margins.2); out.f32(margins.3)
            out.u8(flag)
            out.u16(UInt16(sections.count))
            for section in sections { out.u32(section.0); out.u32(section.1) }
            out.u8(hasObjects ? 1 : 0)
            out.raw([0, 0, 0, 0, 0, 0, 0])
            out.raw(objects)
            return out.bytes
        }

        /// The value of the span of one kind that covers the first character, if any.
        func value(of type: UInt32) -> [UInt8]? { spans.first { $0.type == type && $0.start == 0 }?.value }

        /// The same text saying something else. Every character that stays keeps the spans it
        /// had; one that is new takes those of the character before it (of the first one kept,
        /// before which there is none), so that what is typed at the end of bold text is bold.
        /// Lines keep their settings; a line that is new takes those of the line above it.
        func saying(_ new: String) -> Text {
            guard new != string else { return self }
            let old = Array(string.utf16), now = Array(new.utf16)
            var out = self
            out.string = new
            if now.isEmpty {
                // Nothing left: what was said of the text from its start is kept for what comes next.
                out.spans = spans.filter { $0.start == 0 }.map { var span = $0; span.end = 0; return span }
            } else if old.isEmpty {
                out.spans = spans.filter { $0.start == 0 }.map { var span = $0; span.end = UInt32(now.count); return span }
            } else {
                // Where each character of the new text comes from in the old.
                var removed = Set<Int>(), inserted = Set<Int>()
                for change in now.difference(from: old) {
                    switch change {
                    case .remove(let offset, _, _): removed.insert(offset)
                    case .insert(let offset, _, _): inserted.insert(offset)
                    }
                }
                var source = [Int](repeating: -1, count: now.count)
                var next = 0, last = -1
                for index in now.indices {
                    if !inserted.contains(index) {
                        while removed.contains(next) { next += 1 }
                        last = next
                        next += 1
                    }
                    source[index] = last
                }
                let first = source.first { $0 >= 0 } ?? 0
                for index in source.indices where source[index] < 0 { source[index] = first }
                out.spans = spans.flatMap { span -> [Span] in
                    var pieces: [Span] = []
                    var start: Int?
                    for index in 0...now.count {
                        let covered = index < now.count && Int(span.start) <= source[index] && source[index] < Int(span.end)
                        if covered, start == nil { start = index }
                        if !covered, let from = start {
                            var piece = span
                            piece.start = UInt32(from); piece.end = UInt32(index)
                            pieces.append(piece)
                            start = nil
                        }
                    }
                    return pieces
                }
            }
            let lines = now.filter { $0 == 0x0A }.count + 1, before = old.filter { $0 == 0x0A }.count + 1
            if lines != before {
                out.paragraphs = (0..<lines).flatMap { line -> [Paragraph] in
                    let model = UInt32(min(line, before - 1))
                    return paragraphs.filter { $0.start <= model && model < $0.end }.map { Paragraph(type: $0.type, start: UInt32(line), end: UInt32(line + 1), value: $0.value) }
                }
            }
            return out
        }

        /// One span over all of the text for a property that is on or off, in place of whatever
        /// spans of that kind there were.
        /// (A line through the text is the one kind whose value is four bytes, not eight.)
        mutating func set(_ type: UInt32, on: Bool) { set(type, value: on ? Text.on(type) : nil) }

        static func on(_ type: UInt32) -> [UInt8] { type == 20 ? [1, 0, 0, 0] : [1, 0, 0, 0, 0, 0, 0, 0] }

        /// One span over all of the text with a value, in the place of the first span of its
        /// kind (at the end without one); nil takes the kind out.
        mutating func set(_ type: UInt32, value: [UInt8]?, interval: UInt32 = 1) {
            let place = spans.firstIndex { $0.type == type }
            spans.removeAll { $0.type == type }
            if let value { spans.insert(Span(type: type, start: 0, end: UInt32(string.utf16.count), interval: interval, value: value), at: min(place ?? spans.count, spans.count)) }
        }

        /// How the first line is aligned, as the sync text numbers it: 0 left, 1 right, 2 centre, 3 justified.
        var alignment: Int { paragraphs.first { $0.type == 3 }.map { Int($0.value.first ?? 0) } ?? 0 }

        /// Every line aligned one way.
        mutating func setAlignment(_ value: Int) {
            for index in paragraphs.indices where paragraphs[index].type == 3 {
                var bytes = paragraphs[index].value
                if bytes.count < 8 { bytes += [UInt8](repeating: 0, count: 8 - bytes.count) }
                bytes[0] = UInt8(min(max(value, 0), 3))
                paragraphs[index].value = bytes
            }
        }

        /// A stretch of the text in one style.
        struct Run: Equatable {
            var text: String
            var bold = false
            var italic = false
            var underline = false
            var strikethrough = false
            var size: Float?
            var color: UInt32?
        }

        /// The text cut where its spans begin and end, each piece with what the spans over it say.
        var runs: [Run] {
            let units = Array(string.utf16)
            guard !units.isEmpty else { return [] }
            var cuts = Set([0, units.count])
            for span in spans { cuts.insert(min(Int(span.start), units.count)); cuts.insert(min(Int(span.end), units.count)) }
            let edges = cuts.sorted()
            func number(_ value: [UInt8]) -> UInt32 { value.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
            return zip(edges, edges.dropFirst()).map { from, to in
                var run = Run(text: String(decoding: units[from..<to], as: UTF16.self))
                for span in spans where Int(span.start) <= from && Int(span.end) >= to && span.end > span.start {
                    switch span.type {
                    case 1: run.color = number(span.value)
                    case 3: run.size = Float(bitPattern: number(span.value))
                    case 5: run.bold = span.value.first == 1
                    case 6: run.italic = span.value.first == 1
                    case 7: run.underline = span.value.first == 1
                    case 20: run.strikethrough = span.value.first == 1
                    default: break
                    }
                }
                return run
            }
        }
    }

    /// The outline of a rectangle: where it starts, three lines, and closed.
    static func rectPath(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> [UInt8] {
        var out = Writer()
        out.u32(5)
        out.u8(1); out.f64(l); out.f64(t)
        out.u8(2); out.f64(r); out.f64(t)
        out.u8(2); out.f64(r); out.f64(b)
        out.u8(2); out.f64(l); out.f64(b)
        out.u8(6)
        return out.bytes
    }

    /// The middles of a rectangle's sides, where lines attach: top, right, bottom, left.
    static func connectionPoints(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> [(Double, Double)] {
        let x = single((l + r) / 2), y = single((t + b) / 2)
        return [(x, t), (r, y), (x, b), (l, y)]
    }

    /// The line a text box is drawn with when it has none of its own: solid black, of no width.
    static let plainLineColor: [UInt8] = [0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    static let plainLineStyle = [UInt8](repeating: 0, count: 12)

    /// The frame of what every object has: its format, id, time, rectangle, and then, each
    /// only when given, when it was added, its page's size, how it lies in the text, its page.
    static func baseFrame(props: [UInt8], formatVersion: UInt32, id: String, modified: Int64, rect: (Double, Double, Double, Double),
                          appended: Int64? = nil, ownerPage: (UInt32, UInt32)? = nil, layoutType: UInt8? = nil, pageIndex: Int32? = nil) -> Frame {
        var fixed = Writer()
        fixed.u32(formatVersion)
        let name = Array(id.utf8)
        fixed.u16(UInt16(name.count)); fixed.raw(name)
        fixed.i64(modified)
        fixed.rect(rect.0, rect.1, rect.2, rect.3)
        fixed.u32(0); fixed.u8(0)
        var flags: UInt64 = 0
        var flex = Writer()
        if let appended { flags |= 0x2000; flex.i64(appended) }
        if let ownerPage { flags |= 0x4000; flex.u32(ownerPage.0); flex.u32(ownerPage.1) }
        if let layoutType { flags |= 0x8000; flex.u8(layoutType) }
        if let pageIndex { flags |= 0x100000; flex.i32(pageIndex) }
        return Frame(type: 0, props: props, flagBytes: 4, flags: flags, fixed: fixed.bytes, flex: flex.bytes)
    }

    /// The frame of a shape's attachment points, with its line when it has one.
    static func shapeBaseFrame(points: [(Double, Double)], line: Bool) -> Frame {
        var fixed = Writer()
        fixed.u32(UInt32(points.count))
        for point in points { fixed.f64(point.0); fixed.f64(point.1) }
        fixed.u32(4); fixed.u32(0); fixed.u8(0)
        var flex = Writer()
        if line { flex.sized(plainLineColor); flex.sized(plainLineStyle) }
        return Frame(type: 6, props: [0], flagBytes: 1, flags: line ? 0x0C : 0, fixed: fixed.bytes, flex: flex.bytes)
    }

    /// The frame of a shape: its kind (4, a rectangle), its rectangle, its outline, and its text.
    static func shapeFrame(rect: (Double, Double, Double, Double), path: [UInt8]?, text: [UInt8]? = nil, ellipsis: UInt8? = nil, autoFit: UInt8? = nil) -> Frame {
        var fixed = Writer()
        fixed.u32(4)
        fixed.rect(rect.0, rect.1, rect.2, rect.3)
        fixed.f32(0)
        if let path { fixed.sized(path) } else { fixed.u32(0) }
        fixed.u8(0)
        var flags: UInt64 = 0
        var flex = Writer()
        if let text { flags |= 1; flex.sized(text) }
        if let ellipsis { flags |= 0x1000; flex.u8(ellipsis) }
        if let autoFit { flags |= 0x2000; flex.u8(autoFit) }
        return Frame(type: 7, props: [0x04], flagBytes: 4, flags: flags, fixed: fixed.bytes, flex: flex.bytes)
    }

    static let textBoxFrame = Frame(type: 2, props: [0], flagBytes: 2, flags: 0, fixed: [])

    /// The text of the shape frame of a text box, when it has one.
    static func text(ofShape frame: Frame) throws -> Text? {
        guard frame.type == 7, frame.flags & 1 != 0 else { return nil }
        var reader = Reader(frame.flex)
        var inner = try reader.sub(try reader.count())
        return try Text(&inner)
    }
}
