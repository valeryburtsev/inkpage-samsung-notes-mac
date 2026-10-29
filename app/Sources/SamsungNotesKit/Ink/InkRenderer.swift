import CoreGraphics
import Foundation

/// Core Graphics renderer for decoded handwriting strokes.
///
/// Everything is drawn in the stroke's own page-unit coordinate space; the caller applies the
/// page transform. A y-down coordinate system with (0,0) at the page's top-left is assumed.
public enum InkRenderer {
    /// Draws one stroke as a smoothed, pressure-sensitive, round-capped line.
    /// On a dark page a highlighter lays its colour over the page instead of darkening it.
    public static func draw(_ stroke: InkStroke, in context: CGContext, dark: Bool = false) {
        let points = stroke.points.filter { $0.x.isFinite && $0.y.isFinite }
        guard !points.isEmpty else { return }

        let kind = Pen.kind(named: stroke.penName)
        if kind == .tape { drawTape(stroke, points: points, in: context); return }
        let widths = lineWidths(for: points, penSize: stroke.penSize, kind: kind, fixed: stroke.style.fixedWidth)
        let maxWidth = widths.max() ?? 1

        let isMarker = kind.isMarker || stroke.style.topLayer
        var alpha = Double((stroke.argb >> 24) & 0xFF) / 255
        // Highlighters are translucent; honour a stored alpha, otherwise use Samsung's 45 %.
        if isMarker, alpha > 0.99 { alpha = 0.45 }
        // A pencil's line is a little lighter than ink.
        if kind == .pencil { alpha *= 0.82 }
        guard alpha > 0 else { return }

        let color = CGColor(
            srgbRed: CGFloat((stroke.argb >> 16) & 0xFF) / 255,
            green: CGFloat((stroke.argb >> 8) & 0xFF) / 255,
            blue: CGFloat(stroke.argb & 0xFF) / 255,
            alpha: 1
        )

        context.saveGState()
        defer { context.restoreGState() }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setBlendMode(isMarker && !dark ? .multiply : .normal)

        // Translucent ink is drawn opaque into a transparency layer and composited once, so
        // overlapping segments and self-intersections do not darken.
        let usesLayer = alpha < 0.999
        if usesLayer {
            context.clip(to: extent(of: points).insetBy(dx: -maxWidth - 1, dy: -maxWidth - 1))
            context.setAlpha(CGFloat(alpha))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if usesLayer { context.endTransparencyLayer() } }

        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineCap(isMarker ? .butt : .round)
        context.setLineJoin(.round)

        if points.count == 1 {
            let radius = CGFloat(widths[0] / 2)
            context.fillEllipse(in: CGRect(x: points[0].x - radius, y: points[0].y - radius, width: radius * 2, height: radius * 2))
            return
        }

        if stroke.style.lineType != 0, let dashes = dashes(for: stroke, kind: kind) {
            // A dashed or dotted line is the whole line with gaps left in it: so long a dash and
            // so long a gap along its middle, each end rounded off, as the Windows client stamps it.
            context.setLineWidth(CGFloat(stroke.penSize))
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [CGFloat(dashes.dash), CGFloat(dashes.gap)])
            context.addPath(smoothedPath(points))
            context.strokePath()
            return
        }

        let minWidth = widths.min() ?? maxWidth
        if maxWidth - minWidth < 0.05 {
            // Uniform width: one continuous path gives the cleanest joins.
            context.setLineWidth(CGFloat(maxWidth))
            context.addPath(smoothedPath(points))
            context.strokePath()
            return
        }

        forEachPiece(points: points, widths: widths) { piece in
            // Flatten each smoothed piece into short round-capped lines whose width is
            // interpolated along it, so the width changes without visible steps.
            let chord = hypot(piece.end.x - piece.start.x, piece.end.y - piece.start.y)
                + hypot(piece.control.x - piece.start.x, piece.control.y - piece.start.y) * 0.5
            let widthChange = abs(piece.endWidth - piece.startWidth)
            let wanted = max(Double(chord) / 2.5, widthChange / 0.2)
            let steps = wanted.isFinite ? Int(min(24, max(1, wanted.rounded(.up)))) : 1
            var previous = piece.start
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let next = piece.point(at: t)
                let mid = (Double(step) - 0.5) / Double(steps)
                context.setLineWidth(CGFloat(piece.startWidth + (piece.endWidth - piece.startWidth) * mid))
                context.move(to: previous)
                context.addLine(to: next)
                context.strokePath()
                previous = next
            }
        }
    }

    /// Centre-line polyline through the stroke's points (for hit-testing or thumbnails).
    public static func path(for stroke: InkStroke) -> CGPath {
        let path = CGMutablePath()
        var started = false
        for point in stroke.points where point.x.isFinite && point.y.isFinite {
            let location = CGPoint(x: point.x, y: point.y)
            if started {
                path.addLine(to: location)
            } else {
                path.move(to: location)
                started = true
            }
        }
        // A single sample still yields a non-empty (zero-length) subpath.
        if started, stroke.points.count == 1 { path.addLine(to: path.currentPoint) }
        return path
    }

    // MARK: - Width model

    /// Width multiplier for a pressure in 0...1: light touches thin the line to 30 %.
    static func widthFactor(forPressure pressure: Double) -> Double {
        let clamped = min(max(pressure, 0), 1)
        return 0.3 + 0.7 * clamped
    }

    /// How long a dash and a gap are along the middle of a dashed (1) or dotted (2) line: so
    /// many widths of the pen, by the pen and the level its size was set at.
    static func dashes(for stroke: InkStroke, kind: Pen.Kind) -> (dash: Double, gap: Double)? {
        let size = stroke.penSize.isFinite && stroke.penSize > 0 ? stroke.penSize : StrokeDecoder.defaultPenSize
        return dashLengths(lineType: stroke.style.lineType, sizeLevel: stroke.style.sizeLevel, penSize: size, pencil: kind == .pencil)
    }

    /// The same for a line about to be drawn: nil for an unbroken line.
    public static func dashLengths(lineType: Int, sizeLevel: Int, penSize size: Double, pencil: Bool) -> (dash: Double, gap: Double)? {
        switch lineType {
        case 1:
            let factor = sizeLevel == 0 ? 2.6 : sizeLevel <= 20 ? 3.0 : sizeLevel <= 70 ? 2.6 : 2.3
            return (factor * size, factor * size)
        case 2:
            return pencil ? (0.5 * size, 1.6 * size) : (0.1 * size, 2.0 * size)
        default:
            return nil
        }
    }

    /// A tape: a band as wide as the pen along the line, in its colour or its pattern. One that
    /// has been tapped lets what it covers show through.
    private static func drawTape(_ stroke: InkStroke, points: [InkPoint], in context: CGContext) {
        let size = stroke.penSize.isFinite && stroke.penSize > 0 ? stroke.penSize : 20
        let line = points.count == 1 ? path(for: stroke) : smoothedPath(points)
        let band = line.copy(strokingWithWidth: CGFloat(size), lineCap: .butt, lineJoin: .round, miterLimit: 2)
        guard !band.isEmpty else { return }
        var alpha = Double((stroke.argb >> 24) & 0xFF) / 255
        if alpha <= 0 { alpha = 1 }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(stroke.style.revealed ? alpha * 0.25 : alpha))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(band)
        context.clip()
        func color(_ argb: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255, blue: CGFloat(argb & 0xFF) / 255, alpha: 1)
        }
        let box = band.boundingBoxOfPath
        if stroke.style.colorType == 2, stroke.style.patternIndex >= 1, stroke.style.patternIndex <= Pen.tapePatterns.count {
            let pattern = Pen.tapePatterns[stroke.style.patternIndex - 1]
            context.setFillColor(color(pattern.paper))
            context.fill(box)
            drawPattern(pattern, in: box, cell: max(size * 0.4 * stroke.style.patternScale, 1), ink: color(pattern.ink), context: context)
        } else {
            context.setFillColor(color(stroke.argb))
            context.fill(box)
        }
        context.endTransparencyLayer()
    }

    /// One of the tape patterns, laid over a rectangle in cells of a given size.
    public static func drawPattern(_ pattern: Pen.TapePattern, in box: CGRect, cell: Double, ink: CGColor, context: CGContext) {
        let c = CGFloat(cell)
        let columns = Int(box.width / c) + 2, rows = Int(box.height / c) + 2
        guard columns < 4_000, rows < 4_000 else { return }
        // From a corner the pattern is counted from whatever the band's place, so that two bands side by side fit.
        let left = (box.minX / c).rounded(.down) * c, top = (box.minY / c).rounded(.down) * c
        context.setFillColor(ink)
        context.setStrokeColor(ink)
        context.setLineWidth(c * 0.14)
        context.setLineCap(.round)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = left + CGFloat(column) * c, y = top + CGFloat(row) * c
                let middle = CGPoint(x: x + c / 2, y: y + c / 2)
                switch pattern.figure {
                case .crosses:
                    guard (row + column) % 2 == 0 else { continue }
                    context.move(to: CGPoint(x: middle.x - c * 0.22, y: middle.y)); context.addLine(to: CGPoint(x: middle.x + c * 0.22, y: middle.y))
                    context.move(to: CGPoint(x: middle.x, y: middle.y - c * 0.22)); context.addLine(to: CGPoint(x: middle.x, y: middle.y + c * 0.22))
                    context.strokePath()
                case .stripes:
                    guard column == 0 else { continue }
                    context.move(to: CGPoint(x: box.minX, y: middle.y)); context.addLine(to: CGPoint(x: box.maxX, y: middle.y))
                    context.strokePath()
                case .checks:
                    if (row + column) % 2 == 0 { context.fill(CGRect(x: x, y: y, width: c, height: c)) }
                case .dots:
                    guard (row + column) % 2 == 0 else { continue }
                    context.fillEllipse(in: CGRect(x: middle.x - c * 0.16, y: middle.y - c * 0.16, width: c * 0.32, height: c * 0.32))
                case .grid:
                    context.stroke(CGRect(x: x, y: y, width: c, height: c))
                case .bars:
                    guard row == 0, column % 2 == 0 else { continue }
                    context.setLineWidth(c * 0.3)
                    context.move(to: CGPoint(x: middle.x, y: box.minY)); context.addLine(to: CGPoint(x: middle.x, y: box.maxY))
                    context.strokePath()
                case .hearts:
                    guard (row + column) % 2 == 0 else { continue }
                    let r = c * 0.14
                    context.fillEllipse(in: CGRect(x: middle.x - r * 2, y: middle.y - r * 1.4, width: r * 2, height: r * 2))
                    context.fillEllipse(in: CGRect(x: middle.x, y: middle.y - r * 1.4, width: r * 2, height: r * 2))
                    context.move(to: CGPoint(x: middle.x - r * 1.9, y: middle.y - r * 0.1)); context.addLine(to: CGPoint(x: middle.x + r * 1.9, y: middle.y - r * 0.1))
                    context.addLine(to: CGPoint(x: middle.x, y: middle.y + r * 2)); context.closePath()
                    context.fillPath()
                case .waves:
                    guard column == 0 else { continue }
                    context.move(to: CGPoint(x: box.minX, y: middle.y))
                    var at = box.minX
                    var up = true
                    while at < box.maxX {
                        context.addQuadCurve(to: CGPoint(x: at + c, y: middle.y), control: CGPoint(x: at + c / 2, y: middle.y + (up ? -c * 0.45 : c * 0.45)))
                        at += c
                        up.toggle()
                    }
                    context.strokePath()
                case .halves:
                    guard (row + column) % 2 == 0 else { continue }
                    context.move(to: CGPoint(x: middle.x - c * 0.3, y: middle.y))
                    context.addArc(center: middle, radius: c * 0.3, startAngle: .pi, endAngle: 0, clockwise: true)
                    context.closePath()
                    context.fillPath()
                }
            }
        }
    }

    private static func lineWidths(for points: [InkPoint], penSize: Double, kind: Pen.Kind, fixed: Bool = false) -> [Double] {
        let size = penSize.isFinite && penSize > 0 ? penSize : StrokeDecoder.defaultPenSize
        switch kind {
        case .ballpoint, .pencil:
            // A line of one width, unless it was written with a pen that says how hard it was
            // pressed and was not set to an even line: then it thins with a light hand.
            let pressed = !fixed && points.contains { $0.pressure.isFinite && $0.pressure > 0 && $0.pressure < 0.999 } && Set(points.map { ($0.pressure * 64).rounded() }).count > 2
            return pressed ? points.map { size * widthFactor(forPressure: $0.pressure) } : [Double](repeating: size, count: points.count)
        case .highlighter, .marker, .tape:
            // These draw a line of one width whatever the pressure.
            return [Double](repeating: size, count: points.count)
        case .calligraphy:
            // A slanted nib: full width across its edge, a hairline along it.
            return points.indices.map { index in
                let a = points[max(index - 1, 0)], b = points[min(index + 1, points.count - 1)]
                let angle = atan2(b.y - a.y, b.x - a.x)
                return max(size * 0.18, size * abs(sin(angle + .pi / 4)))
            }
        case .brush:
            let hasPressure = points.contains { $0.pressure.isFinite && $0.pressure > 0 && $0.pressure < 0.999 }
            if hasPressure { return points.map { max(0.1, size * (0.12 + 0.88 * min(max($0.pressure, 0), 1))) } }
            // Without pressure the brush thins where the hand moved fast and at both ends.
            var widths = points.indices.map { index -> Double in
                let a = points[max(index - 1, 0)], b = points[min(index + 1, points.count - 1)]
                let reach = hypot(b.x - a.x, b.y - a.y) / max(size, 0.1)
                return size * min(1, max(0.35, 1.15 - reach * 0.22))
            }
            let taper = min(6, widths.count / 2)
            for index in 0..<taper {
                let share = 0.3 + 0.7 * Double(index + 1) / Double(taper + 1)
                widths[index] *= share
                widths[widths.count - 1 - index] *= share
            }
            return widths
        case .fountain:
            break
        }
        // Finger input stores pressure 0 for every sample: that means "no pressure data",
        // not "invisible", so draw at the nominal width.
        let hasPressure = points.contains { $0.pressure.isFinite && $0.pressure > 0 }
        guard hasPressure else { return [Double](repeating: size, count: points.count) }
        return points.map { max(0.1, size * widthFactor(forPressure: $0.pressure.isFinite ? $0.pressure : 1)) }
    }

    // MARK: - Geometry

    private struct Piece {
        var start: CGPoint
        var control: CGPoint
        var end: CGPoint
        var startWidth: Double
        var endWidth: Double

        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
            )
        }
    }

    /// Splits the stroke into quadratic pieces running between segment midpoints, with each
    /// sample as the control point, plus straight lead-in and lead-out halves.
    private static func forEachPiece(points: [InkPoint], widths: [Double], _ body: (Piece) -> Void) {
        let count = points.count
        guard count >= 2 else { return }
        func location(_ index: Int) -> CGPoint { CGPoint(x: points[index].x, y: points[index].y) }
        func midpoint(_ index: Int) -> CGPoint {
            CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
        }
        func midWidth(_ index: Int) -> Double { (widths[index] + widths[index + 1]) / 2 }
        func line(_ a: CGPoint, _ b: CGPoint, _ wa: Double, _ wb: Double) -> Piece {
            Piece(start: a, control: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), end: b, startWidth: wa, endWidth: wb)
        }

        if count == 2 {
            body(line(location(0), location(1), widths[0], widths[1]))
            return
        }
        body(line(location(0), midpoint(0), widths[0], midWidth(0)))
        for index in 1..<(count - 1) {
            body(Piece(start: midpoint(index - 1), control: location(index), end: midpoint(index),
                       startWidth: midWidth(index - 1), endWidth: midWidth(index)))
        }
        body(line(midpoint(count - 2), location(count - 1), midWidth(count - 2), widths[count - 1]))
    }

    private static func smoothedPath(_ points: [InkPoint]) -> CGPath {
        let path = CGMutablePath()
        let count = points.count
        guard count >= 1 else { return path }
        path.move(to: CGPoint(x: points[0].x, y: points[0].y))
        if count == 1 {
            path.addLine(to: path.currentPoint)
            return path
        }
        if count > 2 {
            for index in 1..<(count - 1) {
                let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
                if index == 1 {
                    path.addLine(to: CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2))
                }
                path.addQuadCurve(to: mid, control: CGPoint(x: points[index].x, y: points[index].y))
            }
        }
        path.addLine(to: CGPoint(x: points[count - 1].x, y: points[count - 1].y))
        return path
    }

    private static func extent(of points: [InkPoint]) -> CGRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
