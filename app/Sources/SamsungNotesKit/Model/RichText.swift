import Foundation

/// A stretch of text with one set of character attributes.
public struct TextRun: Sendable, Equatable, Codable {
    public var text: String
    public var fontSize: Double?
    public var color: UInt32?            // 0xAARRGGBB
    public var background: UInt32?
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var alignment: Int = 0        // 0 leading, 1 trailing, 2 centre, 3 justified (as the service numbers them)
    /// For a run that is the placeholder of a picture set in the text: that object's id.
    public var objectID: String?
    /// The mark its paragraphs start with.
    public var bullet: Bullet?
    public var indent: Int = 0
    public var link = false
    public var fontName: String?

    public enum Bullet: Equatable, Sendable, Codable {
        case dot, number(Int?), checkbox(checked: Bool)
    }

    public init(text: String) { self.text = text }
}

/// Text of a title, a note body or a text box.
public struct RichText: Sendable, Equatable, Codable {
    public var runs: [TextRun] = []
    public init(runs: [TextRun] = []) { self.runs = runs }
    /// The text without the placeholders of pictures set in it.
    public var plain: String { runs.map(\.text).joined().replacingOccurrences(of: "\u{FFFC}", with: "") }
    public var isEmpty: Bool { plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Decodes the service's text encoding: see `NoteText`, which keeps it whole; this is what it shows.
    public init(encoded: String) { runs = NoteText(encoded: encoded).runs }
    public init(_ text: NoteText) { runs = text.runs }
}

extension TextRun {
    func sameStyle(as other: TextRun) -> Bool {
        var a = self, b = other
        a.text = ""; b.text = ""
        return a == b
    }
}
