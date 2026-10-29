import CoreGraphics
import Foundation

/// A kind of pen: the name its strokes carry and the setting string that goes with it. Names,
/// settings and sizes are those of Samsung's own pens, read from the Windows client.
public struct Pen: Equatable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable, Codable { case fountain, ballpoint, pencil, highlighter, brush, calligraphy, marker, tape

        /// The two that lay see-through colour over what is written: the highlighter and the marker pen.
        public var isMarker: Bool { self == .highlighter || self == .marker }
    }

    public var kind: Kind
    /// The class name Samsung's pen has, as strokes name it.
    public var name: String
    /// The pen's "advanced setting", stored with every stroke: its version, and for the
    /// fountain pen how its tip tapers.
    public var setting: String
    /// The pen's narrowest and widest line, on a page 360 units wide.
    public var narrowest: Double
    public var widest: Double
    /// The size the pen has when first picked, from 1 to 100.
    public var standardLevel: Double
    /// How see-through the pen's ink is: 1 is solid.
    public var opacity: Double
    /// The smoothing value strokes of this pen carry, for the pens it is known for.
    public var tolerance: Double?

    static let prefix = "com.samsung.android.sdk.pen.pen.preload."

    public static let fountain = Pen(kind: .fountain, name: prefix + "FountainPen", setting: "18;0;100;", narrowest: 0.228, widest: 7.968, standardLevel: 30, opacity: 1, tolerance: 2.6)
    public static let ballpoint = Pen(kind: .ballpoint, name: prefix + "InkPen2", setting: "9;", narrowest: 0.196, widest: 6.365, standardLevel: 30, opacity: 1, tolerance: 2.6)
    /// The pencil of the Windows client's tools (older notes of this client have the phone's "Pencil3").
    public static let pencil = Pen(kind: .pencil, name: prefix + "Pencil2", setting: "14;", narrowest: 0.228, widest: 3.14, standardLevel: 50, opacity: 0.65, tolerance: nil)
    public static let highlighter = Pen(kind: .highlighter, name: prefix + "Marker4", setting: "8;", narrowest: 1.2, widest: 12.908, standardLevel: 50, opacity: 0.45, tolerance: nil)
    public static let brush = Pen(kind: .brush, name: prefix + "BrushPen", setting: "10;", narrowest: 3.144, widest: 10.529, standardLevel: 30, opacity: 1, tolerance: 2.6)
    public static let calligraphy = Pen(kind: .calligraphy, name: prefix + "ObliquePen", setting: "4;", narrowest: 1.0, widest: 8.34, standardLevel: 30, opacity: 1, tolerance: nil)
    /// The "Marker pen" beside the highlighter in the Windows client's tools.
    public static let marker = Pen(kind: .marker, name: prefix + "Marker3", setting: "5;", narrowest: 1.2, widest: 12.908, standardLevel: 50, opacity: 0.45, tolerance: nil)
    /// The tape: a band laid over what is written, which hides it until it is tapped.
    public static let tape = Pen(kind: .tape, name: prefix + "TapePen", setting: "1;", narrowest: 6, widest: 30, standardLevel: 50, opacity: 1, tolerance: nil)

    public static let all: [Pen] = [.fountain, .ballpoint, .pencil, .highlighter, .brush, .calligraphy, .marker, .tape]
    /// The pens and the highlighters, in the order the Windows client shows each row.
    public static let pens: [Pen] = [.fountain, .calligraphy, .ballpoint, .pencil, .brush]
    public static let markers: [Pen] = [.highlighter, .marker]

    public static func of(_ kind: Kind) -> Pen { all.first { $0.kind == kind } ?? .fountain }

    /// The kind of pen a stroke was made with, from the name it carries. Names this client does
    /// not write (older pens of the same families) are shown as their nearest kind.
    public static func kind(named name: String?) -> Kind {
        let short = (name ?? "").split(separator: ".").last.map { $0.lowercased() } ?? ""
        if short == "tapepen" { return .tape }
        if short == "marker3" { return .marker }
        if short.contains("marker") || short.contains("highlighter") { return .highlighter }
        if short.contains("pencil") { return .pencil }
        if short.contains("oblique") || short.contains("calligraphy") { return .calligraphy }
        if short.contains("brush") { return .brush }
        if short.contains("inkpen") || short.contains("ballpen") { return .ballpoint }
        return .fountain
    }

    /// The width of the pen's line on a page, for a size from 1 to 100: the same law as
    /// Samsung's (level 30 of the fountain pen is 6.007 on a page 848 wide).
    public func size(level: Double, pageWidth: Double, pageHeight: Double = .infinity) -> Double {
        let share = min(max(level, 1), 100) <= 1 ? 0 : min(max(level, 1), 100) / 100
        return (narrowest + (widest - narrowest) * share) * min(pageWidth, pageHeight) / 360
    }

    /// The pens that can draw a dashed or a dotted line, and an even one whatever the pressure.
    public var offersLines: Bool { kind == .ballpoint || kind == .pencil }

    /// A colour as this pen writes it: a highlighter's carries its see-through in the alpha.
    /// `opacity` is the one chosen for the pen, where the pen has a slider for it.
    public func ink(_ argb: UInt32, opacity chosen: Double? = nil) -> UInt32 {
        let opacity = min(max(chosen ?? opacity, 0.01), 1)
        return opacity >= 0.999 ? (argb | 0xFF00_0000) : (argb & 0x00FF_FFFF) | (UInt32((opacity * 255).rounded()) << 24)
    }
}

extension Pen {
    /// The colours a tape pattern is made of, and what it shows: the nine of the Windows client,
    /// by what its files are called.
    public struct TapePattern: Sendable, Equatable {
        public enum Figure: Sendable { case crosses, stripes, checks, dots, grid, bars, hearts, waves, halves }
        public var figure: Figure
        public var paper: UInt32
        public var ink: UInt32
    }

    /// Patterns 1 to 9 (a stroke names its pattern by this number).
    public static let tapePatterns: [TapePattern] = [
        TapePattern(figure: .crosses, paper: 0xFFC9_E6F2, ink: 0xFF3D_5A9A),
        TapePattern(figure: .stripes, paper: 0xFFF4_F0C8, ink: 0xFF3B_4C8C),
        TapePattern(figure: .checks, paper: 0xFFC9_D2F5, ink: 0xFF8F_D0B4),
        TapePattern(figure: .dots, paper: 0xFFC9_857A, ink: 0xFFFF_FFFF),
        TapePattern(figure: .grid, paper: 0xFFFF_C9D0, ink: 0xFFFF_E79A),
        TapePattern(figure: .bars, paper: 0xFF3F_68B0, ink: 0xFFFF_FFFF),
        TapePattern(figure: .hearts, paper: 0xFF4A_5377, ink: 0xFFF2_A0C0),
        TapePattern(figure: .waves, paper: 0xFF5E_3A8C, ink: 0xFFF2_A0B8),
        TapePattern(figure: .halves, paper: 0xFF0F_5F4E, ink: 0xFFF0_B63C),
    ]
}

/// A stroke about to be saved.
public struct NewStroke: Sendable {
    public var points: [InkPoint]
    public var argb: UInt32
    public var penSize: Double
    public var pen: Pen
    /// Given when a stroke comes back under the id it had (undoing an erasure).
    public var id: String?
    public var style: InkStroke.Style

    public init(points: [InkPoint], argb: UInt32, penSize: Double, pen: Pen = .fountain, id: String? = nil, style: InkStroke.Style = InkStroke.Style()) {
        self.points = points; self.argb = argb; self.penSize = penSize; self.pen = pen; self.id = id; self.style = style
    }
}
