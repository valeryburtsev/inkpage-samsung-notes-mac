import Foundation

/// The text of a title, a body or a text box, kept exactly as the service stores it: the
/// characters, the character attributes as spans over them, and the attributes of each
/// paragraph. Nothing is interpreted here, so text read and written back is byte for byte the
/// same, whatever attributes it carries.
public struct NoteText: Equatable, Sendable {
    /// A character attribute over a range. `key` is as in the encoding ("span/fontSize",
    /// "objectSpan/objectSpan"), `value` is everything after it ("1,17": a flag and the value).
    public struct Span: Equatable, Sendable {
        public var key: String
        public var value: String
        /// UTF-16 offsets into `string`.
        public var start: Int
        public var end: Int
        /// The number the span list gives this kind of span, when it lists it.
        public var type: Int?

        public init(key: String, value: String, start: Int, end: Int, type: Int? = nil) {
            self.key = key; self.value = value; self.start = start; self.end = end
            self.type = type ?? NoteText.spanTypes[key]
        }
    }

    public struct Attribute: Equatable, Sendable {
        public var key: String
        public var value: String
        public init(_ key: String, _ value: String) { self.key = key; self.value = value }
    }

    /// The text. A picture set in the text stands as U+FFFC under an "objectSpan/objectSpan" span.
    public var string: String
    /// In the order they are opened in the encoding, which is also the order of the span list.
    public var spans: [Span]
    /// One entry per paragraph (a paragraph more than there are line breaks).
    public var paragraphs: [[Attribute]]
    /// Bodies carry a "sectionData" attribute with the text's length; titles do not.
    public var hasSection: Bool
    /// What the section attribute says when it is not the text's length (the phone writes 0).
    public var sectionValue: String?
    /// Spans over no text at all (a style chosen at the cursor and not yet typed in): they are
    /// not in the encoding, only in the span list, at these places in it.
    public var zeroLength: [ZeroLength] = []

    public struct ZeroLength: Equatable, Sendable {
        public var index: Int
        public var line: String
    }

    public static let objectKey = "objectSpan/objectSpan"
    public static let object = "\u{FFFC}"

    /// The numbers the span list uses for the kinds of span, as far as they are known.
    public static let spanTypes: [String: Int] = [
        "span/foregroundColor": 1, "span/fontSize": 3, "span/fontName": 4, "span/bold": 5, "span/italic": 6, "span/underline": 7,
        "span/hyperText": 9, "span/backgroundColor": 17, "span/timeStamp": 19, "span/strikethrough": 20,
    ]
    /// The order the client keeps a paragraph's attributes in.
    static let paragraphOrder = ["paragraph/indentLevel", "paragraph/alignment", "paragraph/lineSpacing", "paragraph/bullet", "paragraph/parsingState"]

    public static let firstParagraph = [Attribute("paragraph/alignment", "0"), Attribute("paragraph/parsingState", "False")]
    public static let laterParagraph = [Attribute("paragraph/parsingState", "False")]

    public init(string: String = "", spans: [Span] = [], paragraphs: [[Attribute]] = [], hasSection: Bool = true) {
        self.string = string
        self.spans = spans
        self.paragraphs = paragraphs
        self.hasSection = hasSection
    }

    public var length: Int { string.utf16.count }
    public var isEmpty: Bool { string.isEmpty }
    /// The text without the placeholders of pictures.
    public var plain: String { string.replacingOccurrences(of: NoteText.object, with: "") }

    // MARK: Reading

    /// Reads an encoded text and its span list (`spanOrderData` values, already base64-decoded).
    public init(encoded: String, spanList: [String] = []) {
        self.init(string: "", spans: [], paragraphs: [], hasSection: false)
        guard let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)), let stream = String(data: data, encoding: .utf8), !stream.isEmpty else { return }
        var open: [(key: String, value: String, start: Int)] = []
        var paragraph: [Attribute] = []
        var started = false
        var position = 0
        var rest = Substring(stream)
        func startParagraph() { paragraphs.append(paragraph) }
        var instructions = 0
        while !rest.isEmpty {
            if rest.hasPrefix("<?a"), let end = rest.range(of: "?>") {
                // A text that begins with a line break opens with two instructions: the first
                // describes the empty first paragraph, the second the one the break starts.
                if instructions == 1, !started, rest[end.upperBound...].hasPrefix("<?a") == false {
                    startParagraph()
                    started = true
                }
                instructions += 1
                for token in TextStyle.tokens(rest[rest.index(rest.startIndex, offsetBy: 3)..<end.lowerBound]) {
                    if token.key == "sectionData/sectionData" {
                        if !hasSection, let value = token.value { sectionValue = value }
                        hasSection = true
                        continue
                    }
                    if token.key.hasPrefix("paragraph/") {
                        paragraph.removeAll { $0.key == token.key }
                        if let value = token.value { paragraph.append(Attribute(token.key, value)) }
                    } else if let value = token.value {
                        open.append((token.key, value, position))
                    } else if let index = open.lastIndex(where: { $0.key == token.key }) {
                        let item = open.remove(at: index)
                        spans.append(Span(key: item.key, value: item.value, start: item.start, end: position))
                    }
                }
                rest = rest[end.upperBound...]
                continue
            }
            let next = rest.range(of: "<?a")?.lowerBound ?? rest.endIndex
            let chunk = String(rest[..<next])
            rest = rest[next...]
            guard let bytes = Data(base64Encoded: chunk), let text = String(data: bytes, encoding: .utf8), !text.isEmpty else { continue }
            if !started { startParagraph(); started = true }
            for character in text where character == "\n" { _ = character; startParagraph() }
            string += text
            position += text.utf16.count
        }
        for item in open { spans.append(Span(key: item.key, value: item.value, start: item.start, end: position)) }
        if !started, !paragraph.isEmpty { paragraphs.append(paragraph) }
        if sectionValue == "\(position)" { sectionValue = nil }
        // Spans come out in the order they close; the encoding and the span list go by where
        // they open, earlier-listed first among those that open together.
        let order = spanOrder(stream)
        spans.sort { a, b in a.start != b.start ? a.start < b.start : (order[a.key + "\u{1}" + a.value + "\u{1}\(a.start)"] ?? 0) < (order[b.key + "\u{1}" + b.value + "\u{1}\(b.start)"] ?? 0) }
        // The span list tells each span's type number, also for kinds not known here.
        for (index, line) in spanList.enumerated() {
            let parts = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let type = Int(parts[0]), let start = Int(parts[1]), let end = Int(parts[2]) else { continue }
            if start == end { zeroLength.append(ZeroLength(index: index, line: line)); continue }
            if let index = spans.firstIndex(where: { $0.start == start && $0.end == end && $0.value == parts[3] && ($0.type == nil || $0.type == type) && $0.key != NoteText.objectKey }) {
                spans[index].type = type
            }
        }
    }

    /// Where each span was opened among the others opened at the same place.
    private func spanOrder(_ stream: String) -> [String: Int] {
        var order: [String: Int] = [:]
        var position = 0, counter = 0
        var rest = Substring(stream)
        while !rest.isEmpty {
            if rest.hasPrefix("<?a"), let end = rest.range(of: "?>") {
                for token in TextStyle.tokens(rest[rest.index(rest.startIndex, offsetBy: 3)..<end.lowerBound]) where token.value != nil && !token.key.hasPrefix("paragraph/") && token.key != "sectionData/sectionData" {
                    order[token.key + "\u{1}" + token.value! + "\u{1}\(position)"] = counter
                    counter += 1
                }
                rest = rest[end.upperBound...]
                continue
            }
            let next = rest.range(of: "<?a")?.lowerBound ?? rest.endIndex
            if let bytes = Data(base64Encoded: String(rest[..<next])), let text = String(data: bytes, encoding: .utf8) { position += text.utf16.count }
            rest = rest[next...]
        }
        return order
    }

    // MARK: Writing

    static func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    /// The encoded text and its span list (not yet base64-encoded), as the Windows client writes them.
    public func encoded() -> (text: String, spanList: [String]) {
        guard !string.isEmpty else { return ("", []) }
        let units = Array(string.utf16)
        let length = units.count
        // Paragraph n begins at its line break; the first at 0.
        var paragraphStarts = [0]
        for (index, unit) in units.enumerated() where unit == 0x0A { paragraphStarts.append(index) }
        var attributes = paragraphs
        while attributes.count < paragraphStarts.count { attributes.append(attributes.isEmpty ? NoteText.firstParagraph : NoteText.laterParagraph) }
        let live = spans.filter { $0.end > $0.start && $0.start >= 0 && $0.end <= length }
        var cuts = Set([0, length])
        for span in live { cuts.insert(span.start); cuts.insert(span.end) }
        for start in paragraphStarts { cuts.insert(start) }
        let ordered = cuts.sorted()
        var startingAt: [Int: [Int]] = [:]
        for (paragraph, start) in paragraphStarts.enumerated() { startingAt[start, default: []].append(paragraph) }
        var stream = ""
        for (index, cut) in ordered.enumerated() {
            // What ends here closes first, then what starts opens: spans, a picture's place, the paragraph, the section.
            var tokens: [String] = []
            let starting = startingAt[cut] ?? []
            for span in live where span.end == cut { tokens.append("'\(span.key)'") }
            if let first = starting.first, first > 0 { for attribute in attributes[first - 1] { tokens.append("'\(attribute.key)'") } }
            if cut == length {
                for attribute in attributes[paragraphStarts.count - 1] { tokens.append("'\(attribute.key)'") }
                if hasSection { tokens.append("'sectionData/sectionData'") }
            }
            for span in live where span.start == cut && span.key != NoteText.objectKey { tokens.append("'\(span.key)'='\(span.value)'") }
            for span in live where span.start == cut && span.key == NoteText.objectKey { tokens.append("'\(span.key)'='\(span.value)'") }
            if let first = starting.first { for attribute in attributes[first] { tokens.append("'\(attribute.key)'='\(attribute.value)'") } }
            if cut == 0, hasSection { tokens.append("'sectionData/sectionData'='\(sectionValue ?? "\(length)")'") }
            if !tokens.isEmpty { stream += "<?a \(tokens.joined(separator: " "))?>" }
            // A text that begins with a line break: the empty first paragraph ends at once and the next begins.
            for paragraph in starting.dropFirst() {
                let closing = attributes[paragraph - 1].map { "'\($0.key)'" }, opening = attributes[paragraph].map { "'\($0.key)'='\($0.value)'" }
                stream += "<?a \((closing + opening).joined(separator: " "))?>"
            }
            if cut < length {
                let end = ordered[index + 1]
                stream += NoteText.b64(String(decoding: units[cut..<end], as: UTF16.self))
            }
        }
        if hasSection { stream += "<?a 'sectionData/sectionData'='0' 'sectionData/sectionData'?>" }
        var list = live.compactMap { span in span.key == NoteText.objectKey ? nil : span.type.map { "\($0),\(span.start),\(span.end),\(span.value)" } }
        for entry in zeroLength.sorted(by: { $0.index < $1.index }) { list.insert(entry.line, at: min(entry.index, list.count)) }
        return (NoteText.b64(stream), list)
    }

    // MARK: Changing

    /// The attributes a new character at `offset` takes: those of the character before it.
    public func spans(at offset: Int) -> [Span] {
        spans.filter { $0.key != NoteText.objectKey && $0.start < max(offset, 1) && $0.end >= max(offset, 1) }
    }

    /// Text typed here in one style throughout: the given spans stretched over all of it.
    public static func uniform(_ string: String, like model: NoteText?, body: Bool) -> NoteText {
        var text = NoteText(string: string, spans: [], paragraphs: [], hasSection: body)
        let length = string.utf16.count
        var kinds: [Span] = []
        for span in model?.spans ?? [] where span.key != objectKey && !kinds.contains(where: { $0.key == span.key }) { kinds.append(span) }
        if kinds.isEmpty {
            kinds = body ? [Span(key: "span/foregroundColor", value: "1,-14342875", start: 0, end: 0), Span(key: "span/backgroundColor", value: "1,0", start: 0, end: 0), Span(key: "span/fontSize", value: "1,12", start: 0, end: 0)]
                         : [Span(key: "span/foregroundColor", value: "1,-14342875", start: 0, end: 0)]
        }
        text.spans = kinds.map { Span(key: $0.key, value: $0.value, start: 0, end: length, type: $0.type) }
        let count = string.components(separatedBy: "\n").count
        let first = model?.paragraphs.first ?? (body ? firstParagraph : laterParagraph)
        text.paragraphs = (0..<count).map { index in index == 0 ? first : (model?.paragraphs[safe: index] ?? laterParagraph) }
        return text
    }

    /// Adds a picture's placeholder as a paragraph of its own at the end.
    /// `tail` is what follows the object's id in its place's value: "0,0" for a picture, "3,2" for a table.
    public mutating func appendObject(id: String, tail: String = "0,0") {
        if !string.isEmpty {
            let style = spans(at: length)
            let at = length
            string += "\n"
            for index in spans.indices where spans[index].end == at && style.contains(where: { $0.key == spans[index].key && $0.start == spans[index].start }) { spans[index].end = at + 1 }
            paragraphs.append(NoteText.laterParagraph)
        } else if paragraphs.isEmpty {
            paragraphs = [NoteText.firstParagraph]
        }
        let at = length
        string += NoteText.object
        if spans.isEmpty {
            for span in NoteText.uniform("x", like: nil, body: true).spans { spans.append(Span(key: span.key, value: span.value, start: at, end: at + 1, type: span.type)) }
        } else {
            for index in spans.indices where spans[index].end == at && spans[index].key != NoteText.objectKey { spans[index].end = at + 1 }
        }
        spans.append(Span(key: NoteText.objectKey, value: "\(id),\(tail)", start: at, end: at + 1))
    }

    /// Sets a picture's placeholder into the text at an offset, on a line of its own.
    public mutating func insertObject(id: String, at offset: Int, tail: String = "0,0") {
        let units = Array(string.utf16)
        var at = Swift.min(Swift.max(offset, 0), units.count)
        if units.isEmpty { appendObject(id: id, tail: tail); return }
        var piece = NoteText.object
        if at > 0, units[at - 1] != 0x0A { piece = "\n" + piece }
        if at < units.count, units[at] != 0x0A { piece += "\n" }
        replace(at..<at, with: piece)
        at += piece.hasPrefix("\n") ? 1 : 0
        // The placeholder takes the text's own style, like any character typed there, and names its picture.
        spans.removeAll { $0.key == NoteText.objectKey && $0.start <= at && at < $0.end }
        spans.append(Span(key: NoteText.objectKey, value: "\(id),\(tail)", start: at, end: at + 1))
        tidySpans()
    }

    /// The ids of the pictures set in the text, in order.
    public var objectIDs: [String] {
        spans.filter { $0.key == NoteText.objectKey }.sorted { $0.start < $1.start }.compactMap { $0.value.split(separator: ",").first.map(String.init) }
    }
}

// MARK: - Formatting

extension NoteText.Span {
    /// How the span behaves when text is typed at its ends: the first field of its value.
    /// 0 grows at its start, 1 at both ends, 2 at neither, 3 at its end.
    public var interval: Int { key == NoteText.objectKey ? 2 : (value.split(separator: ",", maxSplits: 1).first.flatMap { Int($0) } ?? 3) }
    var growsAtStart: Bool { interval <= 1 }
    var growsAtEnd: Bool { interval == 1 || interval == 3 }
    /// The value without the interval: "True", "-51658", "12".
    public var property: String {
        guard key != NoteText.objectKey, let comma = value.firstIndex(of: ",") else { return value }
        return String(value[value.index(after: comma)...])
    }
}

extension NoteText {
    public static let bold = "span/bold", italic = "span/italic", underline = "span/underline", strikethrough = "span/strikethrough"
    public static let foreground = "span/foregroundColor", background = "span/backgroundColor", fontSize = "span/fontSize", fontName = "span/fontName", link = "span/hyperText"
    public static let bullet = "paragraph/bullet", indent = "paragraph/indentLevel", alignment = "paragraph/alignment"

    public static func isOn(_ property: String?) -> Bool { property?.lowercased() == "true" }

    /// The value of a character attribute at an offset: that of the innermost span over it.
    public func property(_ key: String, at offset: Int) -> String? {
        spans.last { $0.key == key && $0.start <= offset && offset < $0.end }?.property
    }

    /// The one value a character attribute has over the whole of a range, or nil when it
    /// varies or is not set. `unset` stands in where no span covers a character.
    public func property(_ key: String, over range: Range<Int>, unset: String? = nil) -> String? {
        guard !range.isEmpty else { return property(key, at: Swift.max(range.lowerBound - 1, 0)) ?? unset }
        var cuts = Set([range.lowerBound])
        for span in spans where span.key == key { for edge in [span.start, span.end] where range.contains(edge) { cuts.insert(edge) } }
        var found: String??
        for cut in cuts {
            let here = property(key, at: cut) ?? unset
            if let found, found != here { return nil }
            found = here
        }
        return found ?? nil
    }

    /// Gives a range one value for a character attribute, or with `nil` takes the attribute off it.
    /// Spans of one kind are kept nested or apart, never crossing, as the encoding needs them.
    public mutating func setProperty(_ key: String, _ property: String?, in range: Range<Int>) {
        let lower = Swift.min(Swift.max(range.lowerBound, 0), length), upper = Swift.min(Swift.max(range.upperBound, lower), length)
        guard lower < upper else { return }
        var out: [Span] = []
        for var span in spans {
            guard span.key == key, span.end > lower, span.start < upper else { out.append(span); continue }
            if span.start >= lower && span.end <= upper { continue }                     // inside: replaced
            if span.start <= lower && span.end >= upper {                                // around
                if property != nil { out.append(span); continue }
                var tail = span
                span.end = lower
                tail.start = upper
                // The second half starts inside the text: it grows at its end only.
                if tail.interval <= 1 { tail.value = "3," + tail.property }
                if span.end > span.start { out.append(span) }
                if tail.end > tail.start { out.append(tail) }
                continue
            }
            if span.start < lower { span.end = lower } else { span.start = upper }       // across an edge: cut back
            out.append(span)
        }
        spans = out
        if let property, self.property(key, over: lower..<upper) != property {
            let interval = lower == 0 && upper == length ? 1 : 3
            let span = Span(key: key, value: "\(interval),\(property)", start: lower, end: upper)
            let at = spans.lastIndex { $0.start <= lower && $0.key != NoteText.objectKey }.map { $0 + 1 } ?? spans.firstIndex { $0.start > lower } ?? spans.count
            spans.insert(span, at: at)
        }
        tidySpans()
        zeroLength = []
    }

    /// Puts the spans in the order the encoding needs: by where they start, as they were among
    /// those that start together, except that of two of one kind the longer comes first (it is
    /// the outer one, and what opens first closes last).
    mutating func tidySpans() {
        spans.removeAll { $0.end <= $0.start }
        spans.sort { $0.start < $1.start }
        var index = 0
        while index < spans.count {
            var end = index
            while end + 1 < spans.count, spans[end + 1].start == spans[index].start { end += 1 }
            if end > index {
                var slots: [String: [Int]] = [:]
                for place in index...end { slots[spans[place].key, default: []].append(place) }
                for places in slots.values where places.count > 1 {
                    let sorted = places.map { spans[$0] }.enumerated().sorted { $0.element.end != $1.element.end ? $0.element.end > $1.element.end : $0.offset < $1.offset }.map(\.element)
                    for (place, span) in zip(places, sorted) { spans[place] = span }
                }
            }
            index = end + 1
        }
    }

    // MARK: Paragraphs

    /// Where each paragraph starts: the first at 0, the others at their line break.
    public var paragraphStarts: [Int] {
        var starts = [0]
        for (index, unit) in string.utf16.enumerated() where unit == 0x0A { starts.append(index) }
        return starts
    }

    /// The paragraphs a range of text touches. A caret is in the paragraph it would type into;
    /// a selection that ends just after a line break does not reach into the next paragraph.
    public func paragraphs(touching range: Range<Int>) -> ClosedRange<Int> {
        let units = Array(string.utf16)
        let lower = Swift.min(Swift.max(range.lowerBound, 0), units.count), upper = Swift.min(Swift.max(range.upperBound, lower), units.count)
        func breaks(before offset: Int) -> Int { units[..<offset].reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } }
        let first = breaks(before: lower)
        let end = upper > lower && units[upper - 1] == 0x0A ? upper - 1 : upper
        return first...Swift.max(breaks(before: end), first)
    }

    /// The text of a paragraph without its line break, as offsets.
    public func paragraphRange(_ index: Int) -> Range<Int> {
        let starts = paragraphStarts
        guard starts.indices.contains(index) else { return length..<length }
        let from = index == 0 ? 0 : starts[index] + 1
        return from..<(index + 1 < starts.count ? starts[index + 1] : length)
    }

    private mutating func fillParagraphs() {
        let count = paragraphStarts.count
        while paragraphs.count < count { paragraphs.append(paragraphs.isEmpty ? NoteText.firstParagraph : NoteText.laterParagraph) }
        if paragraphs.count > count { paragraphs.removeLast(paragraphs.count - count) }
    }

    public func paragraphValue(_ key: String, _ index: Int) -> String? { paragraphs[safe: index]?.first { $0.key == key }?.value }

    public mutating func setParagraphValue(_ key: String, _ value: String?, _ index: Int) {
        fillParagraphs()
        guard paragraphs.indices.contains(index) else { return }
        paragraphs[index].removeAll { $0.key == key }
        guard let value else { return }
        func rank(_ key: String) -> Int { NoteText.paragraphOrder.firstIndex(of: key) ?? NoteText.paragraphOrder.count }
        let at = paragraphs[index].firstIndex { rank($0.key) > rank(key) } ?? paragraphs[index].count
        paragraphs[index].insert(Attribute(key, value), at: at)
    }

    /// The mark a paragraph starts with.
    public enum Mark: Equatable, Sendable {
        case none, dot, number, checkbox(checked: Bool)

        init(_ value: String?) {
            let parts = (value ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            switch Int(parts.first ?? "") ?? 0 {
            case 2: self = .checkbox(checked: NoteText.isOn(parts[safe: 1]))
            case 4, 5, 6, 7, 10: self = .number
            case 8, 9, 11, 12: self = .dot
            default: self = .none
            }
        }
    }

    public func mark(_ index: Int) -> Mark { Mark(paragraphValue(NoteText.bullet, index)) }

    public mutating func setMark(_ mark: Mark, _ index: Int) {
        switch mark {
        case .none: setParagraphValue(NoteText.bullet, nil, index)
        case .dot: setParagraphValue(NoteText.bullet, "8,0", index)
        case .number: setParagraphValue(NoteText.bullet, "4,1", index)
        case .checkbox(let checked): setParagraphValue(NoteText.bullet, "2,\(checked ? "True" : "False")", index)
        }
        renumber()
    }

    public func indentLevel(_ index: Int) -> Int {
        paragraphValue(NoteText.indent, index).flatMap { $0.split(separator: ",").first }.flatMap { Int($0) } ?? 0
    }

    public mutating func setIndentLevel(_ level: Int, _ index: Int) {
        let level = Swift.min(Swift.max(level, 0), 8)
        let direction = paragraphValue(NoteText.indent, index).flatMap { $0.split(separator: ",").dropFirst().first }.map(String.init) ?? "1"
        setParagraphValue(NoteText.indent, level == 0 ? nil : "\(level),\(direction)", index)
        renumber()
    }

    /// 0 left, 1 right, 2 centre, 3 justified.
    public func alignment(_ index: Int) -> Int { paragraphValue(NoteText.alignment, index).flatMap { Int($0) } ?? 0 }

    public mutating func setAlignment(_ value: Int, _ index: Int) {
        // The first paragraph always says how it is aligned; later ones only when it is not to the left.
        setParagraphValue(NoteText.alignment, value == 0 && index > 0 ? nil : String(Swift.min(Swift.max(value, 0), 3)), index)
    }

    /// The numbers numbered paragraphs show: counted along each run of them, per depth.
    public func numbers() -> [Int: Int] {
        var out: [Int: Int] = [:]
        var counters: [Int: Int] = [:]
        for index in 0..<paragraphStarts.count {
            let level = indentLevel(index)
            for deeper in counters.keys where deeper > level { counters[deeper] = nil }
            guard case .number = mark(index) else {
                // Anything else at this depth ends the count; an empty line too.
                counters[level] = nil
                continue
            }
            counters[level] = (counters[level] ?? 0) + 1
            out[index] = counters[level]
        }
        return out
    }

    /// Writes into numbered paragraphs the numbers they show, as the Windows client stores them.
    public mutating func renumber() {
        let shown = numbers()
        for (index, number) in shown {
            guard let value = paragraphValue(NoteText.bullet, index) else { continue }
            var parts = value.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts[1] != String(number) else { continue }
            parts[1] = String(number)
            setParagraphValue(NoteText.bullet, parts.joined(separator: ","), index)
        }
    }

    // MARK: For display

    /// The text as runs of one style each, with what every character effectively has.
    public var runs: [TextRun] {
        guard !string.isEmpty else { return [] }
        let units = Array(string.utf16)
        let starts = paragraphStarts
        var cuts = Set([0, units.count])
        for span in spans where span.end > span.start { cuts.insert(Swift.min(Swift.max(span.start, 0), units.count)); cuts.insert(Swift.min(Swift.max(span.end, 0), units.count)) }
        for start in starts { cuts.insert(start) }
        let ordered = cuts.sorted()
        let shown = numbers()
        var out: [TextRun] = []
        var paragraph = 0
        for (index, cut) in ordered.enumerated() where cut < units.count {
            while paragraph + 1 < starts.count, starts[paragraph + 1] <= cut { paragraph += 1 }
            var run = TextRun(text: String(decoding: units[cut..<ordered[index + 1]], as: UTF16.self))
            run.fontSize = property(NoteText.fontSize, at: cut).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            run.color = property(NoteText.foreground, at: cut).flatMap { Int32($0.split(separator: ",").first.map(String.init) ?? $0) }.map { UInt32(bitPattern: $0) }
            run.background = property(NoteText.background, at: cut).flatMap { Int32($0) }.map { UInt32(bitPattern: $0) }
            run.bold = NoteText.isOn(property(NoteText.bold, at: cut))
            run.italic = NoteText.isOn(property(NoteText.italic, at: cut))
            run.underline = NoteText.isOn(property(NoteText.underline, at: cut))
            run.strikethrough = NoteText.isOn(property(NoteText.strikethrough, at: cut))
            run.fontName = property(NoteText.fontName, at: cut)
            run.link = property(NoteText.link, at: cut) != nil
            run.objectID = spans.last { $0.key == NoteText.objectKey && $0.start <= cut && cut < $0.end }?.value.split(separator: ",").first.map(String.init)
            run.alignment = alignment(paragraph)
            run.indent = indentLevel(paragraph)
            switch mark(paragraph) {
            case .none: run.bullet = nil
            case .dot: run.bullet = .dot
            case .number: run.bullet = .number(shown[paragraph])
            case .checkbox(let checked): run.bullet = .checkbox(checked: checked)
            }
            if let last = out.last, last.sameStyle(as: run) { out[out.count - 1].text += run.text } else { out.append(run) }
        }
        return out
    }
}
