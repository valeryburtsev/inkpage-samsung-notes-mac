import AppKit
import SamsungNotesKit
import SwiftUI

enum ShapeKind: String, CaseIterable, Identifiable {
    case line, arrow, rectangle, ellipse
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        }
    }
    var title: String {
        switch self {
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        }
    }
}

enum InkTool: Equatable { case pen, eraser, select, shape }

/// What the pen writes with: the pen in hand of the pens and of the highlighters (each tool of
/// the strip keeps its own), and for every pen what the Windows client keeps for it: colour,
/// size, and where the pen has them see-through, kind of line and the two switches.
struct PenChoice: Equatable, Codable {
    struct Setting: Equatable, Codable {
        var argb: UInt32
        /// 1 to 100, as Samsung's own size slider.
        var level: Double
        /// 1 to 100, for the pens that have the slider (pencil, highlighter, marker pen).
        var opacity: Double?
        /// The kind of line, for the pens that offer it (pen, pencil): see `PenLine`.
        var line: Int?
        /// "Straighten lines".
        var straight: Bool?
        /// "Adjust thickness to text" (highlighters, tape).
        var fit: Bool?
        /// Which of the nine patterns a tape has, from 1; nil for a tape of one colour.
        var pattern: Int?
    }

    /// A pen put by for quick access, with all it was set to.
    struct Favourite: Equatable, Codable, Identifiable {
        var id = UUID()
        var kind: Pen.Kind
        var setting: Setting
    }

    /// The pen in hand when the pen tool is, and the one in hand when the highlighter tool is.
    var kind: Pen.Kind = .fountain
    var markerKind: Pen.Kind = .highlighter
    /// True while the highlighter tool is the one chosen; and while the tape is.
    var marking = false
    var taping = false
    var settings: [String: Setting] = [:]
    var shape: String = ShapeKind.line.rawValue
    /// The colours last picked that are not in the palette, newest first.
    var recents: [UInt32] = []
    var favourites: [Favourite] = []

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(Pen.Kind.self, forKey: .kind) ?? .fountain
        markerKind = try values.decodeIfPresent(Pen.Kind.self, forKey: .markerKind) ?? .highlighter
        marking = try values.decodeIfPresent(Bool.self, forKey: .marking) ?? false
        settings = try values.decodeIfPresent([String: Setting].self, forKey: .settings) ?? [:]
        shape = try values.decodeIfPresent(String.self, forKey: .shape) ?? ShapeKind.line.rawValue
        recents = try values.decodeIfPresent([UInt32].self, forKey: .recents) ?? []
        favourites = try values.decodeIfPresent([Favourite].self, forKey: .favourites) ?? []
        // From when the highlighter was one of the pens.
        if kind.isMarker { markerKind = kind; kind = .fountain; marking = true }
        if !markerKind.isMarker { markerKind = .highlighter }
    }

    /// The palette of the Windows client's pens and text: four rows of eight.
    static let palette: [UInt32] = [
        0xFFFF_3636, 0xFFFF_CB30, 0xFFF7_EB00, 0xFF2F_EBD2, 0xFF33_96FF, 0xFF14_47FF, 0xFF99_33FF, 0xFF25_2525,
        0xFFEF_806C, 0xFFD9_4D3C, 0xFF12_3644, 0xFF3F_8881, 0xFF60_88B1, 0xFF50_479A, 0xFFA5_6133, 0xFFCE_B8A1,
        0xFFFB_E156, 0xFFF0_5268, 0xFF6C_DD8F, 0xFF72_89FF, 0xFFDA_DADA, 0xFF67_6767, 0xFFFF_C000, 0xFF37_D366,
        0xFF6C_A9E8, 0xFF92_B0E2, 0xFFB0_D29F, 0xFFBA_9500, 0xFFEB_7461, 0xFF74_3AA2, 0xFFC7_67A6, 0xFFC2_7F65,
    ]
    /// The colours behind text: none, then seven.
    static let backgrounds: [UInt32] = [0xFFFF_3636, 0xFFFF_B426, 0xFFFF_F400, 0xFF00_EBAD, 0xFF33_97FF, 0xFFAE_33FF, 0xFF25_2525]
    static let colors: [UInt32] = [0xFF25_2525, 0xFFFF_3636, 0xFFFF_9500, 0xFFFF_CB30, 0xFF22_B573, 0xFF14_47FF, 0xFF8E_44D6, 0xFF8A_8A8E]
    static let highlights: [UInt32] = [0xFFFF_CB30, 0xFF37_D366, 0xFF5A_C8FA, 0xFFFF_6FA5, 0xFFFF_9500, 0xFFB7_8CFF]

    static func title(_ kind: Pen.Kind) -> String {
        switch kind {
        case .fountain: return "Fountain pen"
        case .ballpoint: return "Pen"
        case .pencil: return "Pencil"
        case .highlighter: return "Highlighter"
        case .brush: return "Brush"
        case .calligraphy: return "Calligraphy pen"
        case .marker: return "Marker pen"
        case .tape: return "Tape"
        }
    }

    static func symbol(_ kind: Pen.Kind) -> String {
        switch kind {
        case .fountain: return "pencil.tip"
        case .ballpoint: return "pencil.line"
        case .pencil: return "pencil"
        case .highlighter, .marker: return "highlighter"
        case .tape: return "bandage"
        case .brush: return "paintbrush.pointed"
        case .calligraphy: return "applepencil.tip"
        }
    }

    /// What each pen is set to when first taken up, as in the Windows client.
    static func standard(_ kind: Pen.Kind) -> Setting {
        switch kind {
        case .fountain, .calligraphy: return Setting(argb: 0xFF25_2525, level: 30)
        case .ballpoint: return Setting(argb: 0xFFFF_CB30, level: 30, line: 0)
        case .pencil: return Setting(argb: 0xFFFF_3636, level: 50, opacity: 65, line: 0)
        case .brush: return Setting(argb: 0xFF6C_DD8F, level: 30)
        case .highlighter: return Setting(argb: 0xFFFF_CB30, level: 50, opacity: 45)
        case .marker: return Setting(argb: 0xFF37_D366, level: 50, opacity: 45)
        case .tape: return Setting(argb: 0xFFFF_CB30, level: 50, pattern: 1)
        }
    }

    /// The three kinds of thing that write: each has a tool of its own in the strip.
    enum Group { case pens, markers, tape }

    var group: Group {
        get { taping ? .tape : marking ? .markers : .pens }
        set { taping = newValue == .tape; marking = newValue == .markers }
    }

    /// The pen in hand with the tool that is chosen.
    var active: Pen.Kind {
        get { taping ? .tape : marking ? markerKind : kind }
        set {
            if newValue == .tape { group = .tape } else if newValue.isMarker { markerKind = newValue; group = .markers } else { kind = newValue; group = .pens }
        }
    }

    /// The manner of the strokes the pen in hand writes, as the Windows client's record keeps it.
    var strokeStyle: InkStroke.Style {
        var style = InkStroke.Style()
        let setting = setting
        if pen.offersLines {
            switch PenLine(rawValue: setting.line ?? 0) ?? .natural {
            case .natural: break
            case .even: style.fixedWidth = true
            case .dashed: style.lineType = 1; style.sizeLevel = Int(setting.level)
            case .dotted: style.lineType = 2; style.sizeLevel = Int(setting.level)
            }
        }
        if active.isMarker { style.topLayer = true }
        if active == .tape, let pattern = setting.pattern, (1...Pen.tapePatterns.count).contains(pattern) { style.colorType = 2; style.patternIndex = pattern }
        return style
    }

    /// The colour the line shows in while it is being drawn.
    var liveColor: UInt32 {
        if active == .tape, let pattern = setting.pattern, let found = Pen.tapePatterns[safe: pattern - 1] { return found.paper }
        return argb
    }
    var pen: Pen { Pen.of(active) }
    var shapeKind: ShapeKind { ShapeKind(rawValue: shape) ?? .line }

    func setting(of kind: Pen.Kind) -> Setting {
        var stored = settings[kind.rawValue] ?? PenChoice.standard(kind)
        // A pen set before it had the slider gets the slider's first place.
        if stored.opacity == nil { stored.opacity = PenChoice.standard(kind).opacity }
        return stored
    }

    var setting: Setting {
        get { setting(of: active) }
        set { settings[active.rawValue] = newValue }
    }

    /// The colour as the stroke stores it: a see-through pen's carries that in its alpha.
    var argb: UInt32 { pen.ink(setting.argb, opacity: setting.opacity.map { $0 / 100 }) }
    var color: Color { PenChoice.color(setting.argb) }

    /// Notes a colour as picked: one that is not in the palette is kept among the last five.
    mutating func pick(_ argb: UInt32) {
        let solid = argb | 0xFF00_0000
        setting.argb = solid
        guard !MainActor.assumeIsolated({ ColorSets.shared.colors }).contains(solid) else { return }
        recents.removeAll { $0 == solid }
        recents.insert(solid, at: 0)
        recents = Array(recents.prefix(5))
    }

    static func color(_ argb: UInt32) -> Color {
        Color(.sRGB, red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255, blue: Double(argb & 0xFF) / 255)
    }

    static func nsColor(_ argb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255, blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }

    static func argb(_ color: NSColor) -> UInt32 {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0xFF25_2525 }
        func part(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return 0xFF00_0000 | part(rgb.redComponent) << 16 | part(rgb.greenComponent) << 8 | part(rgb.blueComponent)
    }

    /// The line's width on a page of this size, in the page's units.
    func size(pageWidth: Double, pageHeight: Double) -> Double { pen.size(level: setting.level, pageWidth: pageWidth, pageHeight: pageHeight) }

    static func stored() -> PenChoice {
        guard Launch.value("--editor-check") == nil else { return PenChoice() }
        return (UserDefaults.standard.data(forKey: "penChoice")).flatMap { try? JSONDecoder().decode(PenChoice.self, from: $0) } ?? PenChoice()
    }

    func store() {
        // A scripted run does not change the pen the user left.
        guard Launch.value("--editor-check") == nil else { return }
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "penChoice") }
    }
}

/// How the eraser rubs out, as the Windows client's eraser panel has it.
struct EraserChoice: Equatable, Codable {
    /// The area eraser takes away only what it passes over; the stroke eraser the whole stroke it touches.
    var area = false
    /// The area eraser's size, 1 to 10.
    var level: Double = 7
    var highlighterOnly = false
    var tapeOnly = false

    /// The area eraser's reach on a page, in the page's units: from a fine point to a wide rubber.
    func radius(pageWidth: Double) -> Double { (2 + level * 2.4) * pageWidth / 360 / 2 }

    static func stored() -> EraserChoice {
        guard Launch.value("--editor-check") == nil else { return EraserChoice() }
        return (UserDefaults.standard.data(forKey: "eraserChoice")).flatMap { try? JSONDecoder().decode(EraserChoice.self, from: $0) } ?? EraserChoice()
    }

    func store() {
        guard Launch.value("--editor-check") == nil else { return }
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "eraserChoice") }
    }
}

/// How the selection tool picks: with a loop or a rectangle, and whether what it only touches counts.
struct SelectChoice: Equatable, Codable {
    var rectangle = false
    var partial = true

    static func stored() -> SelectChoice {
        guard Launch.value("--editor-check") == nil else { return SelectChoice() }
        return (UserDefaults.standard.data(forKey: "selectChoice")).flatMap { try? JSONDecoder().decode(SelectChoice.self, from: $0) } ?? SelectChoice()
    }

    func store() {
        guard Launch.value("--editor-check") == nil else { return }
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "selectChoice") }
    }
}

/// The points of a shape drawn from one corner to the other, close enough together that the
/// stroke they make keeps its corners.
enum ShapePoints {
    static func line(_ a: CGPoint, _ b: CGPoint, step: CGFloat = 2) -> [CGPoint] {
        let length = hypot(b.x - a.x, b.y - a.y)
        let count = max(Int(length / step), 1)
        return (0...count).map { CGPoint(x: a.x + (b.x - a.x) * CGFloat($0) / CGFloat(count), y: a.y + (b.y - a.y) * CGFloat($0) / CGFloat(count)) }
    }

    /// One stroke per piece: a line is one, an arrow is the shaft and its head.
    static func strokes(_ kind: ShapeKind, from a: CGPoint, to b: CGPoint, step: CGFloat = 2) -> [[CGPoint]] {
        switch kind {
        case .line:
            return [line(a, b, step: step)]
        case .arrow:
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = min(max(hypot(b.x - a.x, b.y - a.y) * 0.22, step * 5), step * 22)
            let left = CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7))
            let right = CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7))
            return [line(a, b, step: step), line(left, b, step: step) + line(b, right, step: step).dropFirst()]
        case .rectangle:
            let corners = [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y), a]
            var points: [CGPoint] = []
            for index in 0..<4 { points.append(contentsOf: line(corners[index], corners[index + 1], step: step).dropLast(index == 3 ? 0 : 1)) }
            return [points]
        case .ellipse:
            let centre = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            let count = max(Int((rx + ry) * .pi / step), 16)
            return [(0...count).map { CGPoint(x: centre.x + rx * cos(CGFloat($0) / CGFloat(count) * 2 * .pi), y: centre.y + ry * sin(CGFloat($0) / CGFloat(count) * 2 * .pi)) }]
        }
    }

    /// With Shift held: a line snaps to eighths of a turn, a box to a square.
    static func constrained(_ kind: ShapeKind, from a: CGPoint, to b: CGPoint) -> CGPoint {
        switch kind {
        case .line, .arrow:
            let length = hypot(b.x - a.x, b.y - a.y)
            let angle = (atan2(b.y - a.y, b.x - a.x) / (.pi / 4)).rounded() * (.pi / 4)
            return CGPoint(x: a.x + length * cos(angle), y: a.y + length * sin(angle))
        case .rectangle, .ellipse:
            let side = max(abs(b.x - a.x), abs(b.y - a.y))
            return CGPoint(x: a.x + (b.x < a.x ? -side : side), y: a.y + (b.y < a.y ? -side : side))
        }
    }
}

/// The layer over a page that takes the pointer: it shows what is being drawn and reports it
/// when the button comes up. Everything is in the view's own coordinates.
struct InkOverlay: NSViewRepresentable {
    struct Picked: Equatable {
        var rect: CGRect
        var picture: CGImage?
        var keepsShape: Bool
        var revision: Int
        static func == (a: Picked, b: Picked) -> Bool { a.rect == b.rect && a.revision == b.revision && a.keepsShape == b.keepsShape }
    }

    let tool: InkTool
    let shape: ShapeKind
    let color: NSColor
    let lineWidth: CGFloat
    let highlighter: Bool
    /// The pen draws a straight line from where it went down to where it came up.
    var straighten = false
    /// The selection tool draws a rectangle, not a loop.
    var rectangle = false
    /// The pointer: a press on handwriting picks the block it belongs to and moves it at once.
    var pointer = false
    /// Picks the block of handwriting at a point; its frame in the view's points, nil when there is none.
    var onGrab: ((CGPoint) -> CGRect?)?
    /// The area eraser's reach in the view's points; nil for the stroke eraser.
    var eraserRadius: CGFloat?
    /// The lengths of dash and gap of the line being drawn, in the view's points; nil for an unbroken line.
    var dash: [CGFloat]?
    /// A press without a drag, with the pen in hand: true when it was taken for something (a tape tapped), and leaves no dot.
    var onTap: ((CGPoint) -> Bool)?
    /// Changes when the page beneath shows the strokes drawn so far.
    let revision: Int
    /// What is picked on this page, if anything.
    let picked: Picked?
    let onStroke: ([[CGPoint]], [Double], [Int]) -> Void
    let onErase: (CGPoint) -> Void
    let onLasso: ([CGPoint]) -> Void
    let onPick: (CGPoint) -> Void
    let onTransform: (CGAffineTransform) -> Void
    let onDelete: () -> Void
    let onDropPicture: (NSPasteboard, CGPoint) -> Bool

    func makeNSView(context: Context) -> InkCanvasView { InkCanvasView() }

    func updateNSView(_ view: InkCanvasView, context: Context) {
        let toolChanged = view.tool != tool
        view.tool = tool
        view.shape = shape
        view.strokeColor = color
        view.lineWidth = lineWidth
        view.highlighter = highlighter
        view.straighten = straighten
        view.rectangle = rectangle
        if view.pointer != pointer { view.pointer = pointer; view.window?.invalidateCursorRects(for: view) }
        view.onGrab = onGrab
        if view.eraserRadius != eraserRadius { view.eraserRadius = eraserRadius; view.window?.invalidateCursorRects(for: view) }
        view.dash = dash
        view.onTap = onTap
        view.onStroke = onStroke
        view.onErase = onErase
        view.onLasso = onLasso
        view.onPick = onPick
        view.onTransform = onTransform
        view.onDelete = onDelete
        view.onDropPicture = onDropPicture
        if view.revision != revision {
            view.revision = revision
            view.forgetFinishedSoon()
        }
        if view.picked != picked { view.picked = picked }
        if toolChanged { view.window?.invalidateCursorRects(for: view) }
    }
}

final class InkCanvasView: NSView {
    var tool: InkTool = .pen
    var shape: ShapeKind = .line
    var strokeColor: NSColor = .black
    var lineWidth: CGFloat = 3
    var highlighter = false
    var straighten = false
    var rectangle = false
    var pointer = false
    var onGrab: ((CGPoint) -> CGRect?)?
    /// What the pointer picked as the press began, before the picked frame comes back from the note.
    private var grabbed: CGRect?
    var eraserRadius: CGFloat?
    var dash: [CGFloat]?
    var onTap: ((CGPoint) -> Bool)?
    var revision = 0
    var onStroke: (([[CGPoint]], [Double], [Int]) -> Void)?
    var onErase: ((CGPoint) -> Void)?
    var onLasso: (([CGPoint]) -> Void)?
    var onPick: ((CGPoint) -> Void)?
    var onTransform: ((CGAffineTransform) -> Void)?
    var onDelete: (() -> Void)?
    var onDropPicture: ((NSPasteboard, CGPoint) -> Bool)?
    var picked: InkOverlay.Picked? { didSet { showPicked() } }

    private var points: [CGPoint] = []
    private var pressures: [Double] = []
    private var times: [Int] = []
    private var started = Date()
    private var live: CAShapeLayer?
    private var finished: [CALayer] = []
    private var anchor = CGPoint.zero

    private let box = CAShapeLayer()
    private let ghost = CALayer()
    private var handles: [CAShapeLayer] = []
    private enum Drag { case none, move(CGPoint), resize(corner: Int, start: CGPoint) }
    private var drag = Drag.none
    private var pending = CGAffineTransform.identity
    private var erasing = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityLabel("Drawing area")
        setAccessibilityRole(.layoutArea)
        box.fillColor = nil
        box.strokeColor = NSColor.controlAccentColor.cgColor
        box.lineWidth = 1.2
        box.lineDashPattern = [5, 4]
        box.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "hidden": NSNull()]
        ghost.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        ghost.opacity = 0.55
        ghost.isHidden = true
        box.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() {
        switch tool {
        case .pen, .shape: addCursorRect(bounds, cursor: .crosshair)
        case .eraser: addCursorRect(bounds, cursor: eraserCursor)
        case .select:
            addCursorRect(bounds, cursor: rectangle && !pointer ? .crosshair : .arrow)
            if let rect = picked?.rect { addCursorRect(rect, cursor: .openHand) }
        }
    }

    /// The area eraser shows how much it takes: a ring of its own size. The stroke eraser points.
    private var eraserCursor: NSCursor {
        guard let radius = eraserRadius else { return .pointingHand }
        let side = max(radius * 2, 6) + 4
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            NSColor.white.withAlphaComponent(0.55).setFill()
            ring.fill()
            NSColor.gray.setStroke()
            ring.lineWidth = 1
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }

    /// Asked for the pointer's shape by a bar the pointer has just left (see `BarShield`):
    /// the same shapes as the rectangles above give.
    override func cursorUpdate(with event: NSEvent) {
        switch tool {
        case .pen, .shape: NSCursor.crosshair.set()
        case .eraser: eraserCursor.set()
        case .select: (picked?.rect.contains(convert(event.locationInWindow, from: nil)) == true ? NSCursor.openHand : rectangle ? NSCursor.crosshair : NSCursor.arrow).set()
        }
    }

    // MARK: What is picked

    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private func showPicked() {
        guard let layer else { return }
        handles.forEach { $0.removeFromSuperlayer() }
        handles = []
        pending = .identity
        guard let picked, tool == .select else {
            box.isHidden = true
            ghost.isHidden = true
            return
        }
        if box.superlayer == nil { layer.addSublayer(ghost); layer.addSublayer(box) }
        box.isHidden = false
        box.setAffineTransform(.identity)
        box.path = CGPath(rect: picked.rect.insetBy(dx: -4, dy: -4), transform: nil)
        ghost.setAffineTransform(.identity)
        ghost.frame = picked.rect
        ghost.contents = picked.picture
        ghost.isHidden = true
        for corner in corners(picked.rect.insetBy(dx: -4, dy: -4)) {
            let handle = CAShapeLayer()
            handle.path = CGPath(ellipseIn: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10), transform: nil)
            handle.fillColor = NSColor.white.cgColor
            handle.strokeColor = NSColor.controlAccentColor.cgColor
            handle.lineWidth = 1.5
            handle.actions = ["transform": NSNull(), "path": NSNull()]
            layer.addSublayer(handle)
            handles.append(handle)
        }
        window?.invalidateCursorRects(for: self)
    }

    private func preview(_ transform: CGAffineTransform) {
        pending = transform
        guard let rect = picked?.rect ?? grabbed else { return }
        let moved = rect.applying(transform)
        ghost.isHidden = false
        ghost.frame = moved
        box.path = CGPath(rect: moved.insetBy(dx: -4, dy: -4), transform: nil)
        for (handle, corner) in zip(handles, corners(moved.insetBy(dx: -4, dy: -4))) {
            handle.path = CGPath(ellipseIn: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10), transform: nil)
        }
    }

    // MARK: Pointer

    private func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)); return path }
        // Through the midpoints, so the line is as smooth as the saved stroke will be drawn.
        for index in 1..<points.count {
            let previous = points[index - 1], current = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// A layer of the drawing the size of the whole canvas. One left without a size was at times
    /// shown cut short at the edges, the first stroke of a new pad most of all.
    private func sized(_ shape: CAShapeLayer) -> CAShapeLayer {
        shape.frame = bounds
        shape.contentsScale = window?.backingScaleFactor ?? 2
        shape.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        return shape
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in finished + [live].compactMap({ $0 }) where shape.frame != bounds { shape.frame = bounds }
        CATransaction.commit()
    }

    private func inkLayer() -> CAShapeLayer {
        let shape = sized(CAShapeLayer())
        shape.fillColor = nil
        shape.strokeColor = strokeColor.cgColor
        shape.lineWidth = lineWidth
        shape.lineCap = highlighter ? .butt : .round
        shape.lineJoin = .round
        if let dash, tool == .pen { shape.lineDashPattern = dash.map { NSNumber(value: Double($0)) } }
        if highlighter { shape.compositingFilter = "multiplyBlendMode" }
        layer?.addSublayer(shape)
        return shape
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        anchor = point
        switch tool {
        case .eraser:
            // Everything one sweep takes off comes back with one undo.
            if !erasing { erasing = true; undoManager?.beginUndoGrouping() }
            onErase?(point)
        case .select:
            drag = .none
            if let picked {
                let around = corners(picked.rect.insetBy(dx: -4, dy: -4))
                if let corner = around.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < 9 }) {
                    drag = .resize(corner: corner, start: point)
                    return
                }
                if picked.rect.insetBy(dx: -4, dy: -4).contains(point) {
                    drag = .move(point)
                    NSCursor.closedHand.set()
                    return
                }
            }
            grabbed = nil
            if pointer, let rect = onGrab?(point) {
                // A press on handwriting: its block is picked, and moves with the pointer at once.
                grabbed = rect
                box.isHidden = false
                drag = .move(point)
                NSCursor.closedHand.set()
                return
            }
            points = [point]
            let shape = sized(CAShapeLayer())
            shape.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            shape.strokeColor = NSColor.controlAccentColor.cgColor
            shape.lineWidth = 1.2
            shape.lineDashPattern = [5, 4]
            layer?.addSublayer(shape)
            live = shape
        case .pen:
            points = [point]
            pressures = [pressure(event)]
            times = [0]
            started = Date()
            let shape = inkLayer()
            shape.path = path(points)
            live = shape
        case .shape:
            let shape = inkLayer()
            shape.lineCap = .round
            live = shape
        }
    }

    override func mouseDragged(with event: NSEvent) {
        var point = convert(event.locationInWindow, from: nil)
        switch tool {
        case .eraser:
            onErase?(point)
        case .select:
            switch drag {
            case .move(let start):
                preview(CGAffineTransform(translationX: point.x - start.x, y: point.y - start.y))
            case .resize(let corner, _):
                guard let picked else { return }
                // The corner opposite the one held stays where it is; the shape is kept.
                let rect = picked.rect
                let around = corners(rect)
                let fixed = around[(corner + 2) % 4], held = around[corner]
                let was = hypot(held.x - fixed.x, held.y - fixed.y)
                guard was > 1 else { return }
                let scale = max(hypot(point.x - fixed.x, point.y - fixed.y) / was, 0.05)
                preview(CGAffineTransform(translationX: fixed.x, y: fixed.y).scaledBy(x: scale, y: scale).translatedBy(x: -fixed.x, y: -fixed.y))
            case .none:
                if rectangle || pointer {
                    // From the corner it began at to where the pointer is.
                    let first = points.first ?? anchor
                    points = [first, CGPoint(x: point.x, y: first.y), point, CGPoint(x: first.x, y: point.y)]
                    live?.path = CGPath(rect: CGRect(x: min(first.x, point.x), y: min(first.y, point.y), width: abs(point.x - first.x), height: abs(point.y - first.y)), transform: nil)
                    return
                }
                guard let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 1.5 else { return }
                points.append(point)
                let loop = CGMutablePath()
                loop.addLines(between: points)
                loop.closeSubpath()
                live?.path = loop
            }
        case .pen:
            guard live != nil, let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 0.6 else { return }
            points.append(point)
            pressures.append(pressure(event))
            times.append(Int(Date().timeIntervalSince(started) * 1000))
            // Straightened, the line shows as it will be: from where it began to the pointer.
            live?.path = straighten ? path([points[0], point]) : path(points)
        case .shape:
            if event.modifierFlags.contains(.shift) { point = ShapePoints.constrained(shape, from: anchor, to: point) }
            let outline = CGMutablePath()
            for piece in ShapePoints.strokes(shape, from: anchor, to: point) { outline.addLines(between: piece) }
            live?.path = outline
        }
    }

    override func mouseUp(with event: NSEvent) {
        var point = convert(event.locationInWindow, from: nil)
        if erasing { erasing = false; undoManager?.endUndoGrouping() }
        switch tool {
        case .eraser:
            break
        case .select:
            if case .none = drag {
                live?.removeFromSuperlayer()
                live = nil
                let wide = (rectangle || pointer) && points.count == 4 && hypot(points[2].x - points[0].x, points[2].y - points[0].y) > 6
                if points.count > 6 || wide { onLasso?(points) } else { onPick?(point) }
                points = []
            } else {
                drag = .none
                let transform = pending
                pending = .identity
                if !transform.isIdentity { onTransform?(transform) } else { ghost.isHidden = true }
                grabbed = nil
                window?.invalidateCursorRects(for: self)
            }
        case .pen:
            guard let shape = live, !points.isEmpty, pressures.count == points.count else { live?.removeFromSuperlayer(); live = nil; points = []; return }
            live = nil
            if points.count == 1, onTap?(points[0]) == true {
                // The tap was for what lay under it.
                shape.removeFromSuperlayer()
                points = []
                return
            }
            if points.count == 1 {
                // A tap leaves a dot.
                points.append(CGPoint(x: points[0].x + 0.4, y: points[0].y + 0.4)); pressures.append(pressures[0]); times.append(16)
            } else if straighten, let first = points.first, let last = points.last, hypot(last.x - first.x, last.y - first.y) > 3 {
                // A straight line from the first point to the last, in steps as close as a drawn one's.
                let whole = times.last ?? 16, even = pressures.reduce(0, +) / Double(pressures.count)
                points = ShapePoints.line(first, last, step: 2)
                pressures = [Double](repeating: even, count: points.count)
                times = points.indices.map { whole * $0 / max(points.count - 1, 1) }
                shape.path = path(points)
            }
            finished.append(shape)
            onStroke?([points], pressures, times)
            points = []
        case .shape:
            guard let outline = live else { return }
            live = nil
            if event.modifierFlags.contains(.shift) { point = ShapePoints.constrained(self.shape, from: anchor, to: point) }
            guard hypot(point.x - anchor.x, point.y - anchor.y) > 3 else { outline.removeFromSuperlayer(); return }
            finished.append(outline)
            onStroke?(ShapePoints.strokes(shape, from: anchor, to: point), [], [])
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: if picked != nil { onDelete?() } else { super.keyDown(with: event) }       // delete, forward delete
        case 53: if picked != nil { onPick?(CGPoint(x: -10_000, y: -10_000)) } else { super.keyDown(with: event) }   // escape
        default: super.keyDown(with: event)
        }
    }

    private func pressure(_ event: NSEvent) -> Double {
        event.subtype == .tabletPoint ? max(Double(event.pressure), 0.05) : 1
    }

    /// The page beneath now shows what was drawn: the copies kept here can go once it has redrawn.
    func forgetFinishedSoon() {
        let old = finished
        finished = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { old.forEach { $0.removeFromSuperlayer() } }
    }

    // MARK: Pictures dropped on the page

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PictureFile.canRead(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropPicture?(sender.draggingPasteboard, convert(sender.draggingLocation, from: nil)) ?? false
    }
}

extension PictureFile {
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) || pasteboard.availableType(from: [.png, .tiff]) != nil
    }
}
