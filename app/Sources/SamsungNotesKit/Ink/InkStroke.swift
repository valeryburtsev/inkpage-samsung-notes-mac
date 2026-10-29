import CoreGraphics
import Foundation

/// One sampled point of a handwriting stroke, in page units (y grows downwards).
public struct InkPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    /// Raw stored pressure. Stylus input is roughly 0...1; mouse input is a constant 1 and
    /// finger input a constant 0 (i.e. "no pressure information").
    public var pressure: Double
    /// Time offset of the sample relative to the start of the stroke (milliseconds when the
    /// record uses millisecond mode, which every record seen so far does). `nil` if absent.
    public var time: Int?

    public init(x: Double, y: Double, pressure: Double = 1, time: Int? = nil) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.time = time
    }
}

/// A decoded Samsung Notes handwriting stroke.
public struct InkStroke: Sendable, Identifiable {
    /// Object UUID from the record.
    public var id: String
    /// Stored bounding rect of the centre line, page units.
    public var bounds: CGRect
    /// Centre-line samples, page units.
    public var points: [InkPoint]
    /// Colour as 0xAARRGGBB.
    public var argb: UInt32
    /// Nominal pen width, page units.
    public var penSize: Double
    /// Index into the note's `stringIdList`, if the record carries one.
    public var penNameID: Int?
    /// Pen class name; filled in by the caller from the note's string table.
    public var penName: String?
    /// Index of the pen's setting string in the note's string table, and the string itself.
    public var settingID: Int?
    public var setting: String?

    /// What a stroke says of the manner it is drawn in, beyond its pen, colour and size:
    /// the Windows client's pen options, as its stroke record keeps them.
    public struct Style: Sendable, Equatable {
        /// An even line: the width does not follow the pressure. (Property bit 4.)
        public var fixedWidth = false
        /// Drawn over the others, as the highlighters' strokes are. (Property bit 6.)
        public var topLayer = false
        /// The pencil's ink does not thin with the pressure. (Property bit 11.)
        public var fixedOpacity = false
        /// A tape that has been tapped: what it covers shows through. (Property bit 14.)
        public var revealed = false
        /// 0 an unbroken line, 1 dashed, 2 dotted.
        public var lineType = 0
        /// The pen's size from 1 to 100, kept by dashed and dotted strokes: their dashes go by it.
        public var sizeLevel = 0
        /// 0 a plain colour, 2 a pattern (a tape's).
        public var colorType = 0
        /// Which of the nine tape patterns, from 1; -1 none.
        public var patternIndex = -1
        public var patternScale = 1.0

        public init() {}
    }

    public var style = Style()

    public var pen: Pen {
        var pen = Pen.of(Pen.kind(named: penName))
        if let penName, !penName.isEmpty { pen.name = penName }
        if let setting { pen.setting = setting }
        return pen
    }

    public init(
        id: String,
        bounds: CGRect,
        points: [InkPoint],
        argb: UInt32 = StrokeDecoder.defaultARGB,
        penSize: Double = StrokeDecoder.defaultPenSize,
        penNameID: Int? = nil,
        penName: String? = nil
    ) {
        self.id = id
        self.bounds = bounds
        self.points = points
        self.argb = argb
        self.penSize = penSize
        self.penNameID = penNameID
        self.penName = penName
    }
}
