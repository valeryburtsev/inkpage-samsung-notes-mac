import AppKit
import SamsungNotesKit
import SwiftUI

/// A sheet to make a drawing on: a few colours, three widths, an eraser. What is drawn goes
/// into the note as a picture.
struct DrawingSheet: View {
    /// The drawing as a PNG with a clear background, cut to what was drawn; nil when cancelled or empty.
    let finish: (PictureFile?) -> Void
    @State private var board = DrawingBoard()
    @State private var color: UInt32 = 0xFF25_2525
    @State private var width: CGFloat = 4
    @State private var erasing = false

    private static let colors: [UInt32] = [0xFF25_2525, 0xFFFF_3636, 0xFFFF_9500, 0xFFFF_CB30, 0xFF22_B573, 0xFF14_47FF, 0xFF8E_44D6, 0xFFFF_6FA5, 0xFF8A_8A8E, 0xFFFF_FFFF]
    private static let widths: [CGFloat] = [2, 4, 9, 18]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(DrawingSheet.colors, id: \.self) { value in
                    Button { color = value; erasing = false } label: {
                        Circle().fill(PenChoice.color(value)).frame(width: 22, height: 22)
                            .overlay { Circle().strokeBorder(.primary.opacity(0.18)) }
                            .overlay { if !erasing, color == value { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-4) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Swatches.name(value))
                    .accessibilityAddTraits(!erasing && color == value ? .isSelected : [])
                }
                Divider().frame(height: 22)
                ForEach(DrawingSheet.widths, id: \.self) { value in
                    Button { width = value } label: {
                        Circle().fill(.primary).frame(width: min(value + 3, 18), height: min(value + 3, 18)).frame(width: 26, height: 26)
                            .background(width == value ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.clear), in: .circle)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Line width \(Int(value))")
                    .accessibilityAddTraits(width == value ? .isSelected : [])
                }
                Divider().frame(height: 22)
                Button { erasing.toggle() } label: {
                    Image(systemName: "eraser").frame(width: 30, height: 26)
                        .foregroundStyle(erasing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(erasing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain).help("Eraser: rubs out whole lines").accessibilityLabel("Eraser").accessibilityAddTraits(erasing ? .isSelected : [])
                Spacer()
                Button { board.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(board.strokes.isEmpty).help("Undo").accessibilityLabel("Undo")
                Button("Clear") { board.clear() }.disabled(board.strokes.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            DrawingCanvas(board: board, color: color, width: width, erasing: erasing)
                .frame(width: 720, height: 460)
                .background(Color.white)
            Divider()
            HStack {
                Text("The drawing is put into the note as a picture.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Insert") { finish(board.picture()) }.keyboardShortcut(.defaultAction).disabled(board.strokes.isEmpty)
            }
            .padding(14)
        }
    }
}

/// What has been drawn on the sheet.
@MainActor @Observable
final class DrawingBoard {
    struct Stroke {
        var points: [CGPoint]
        var argb: UInt32
        var width: CGFloat
    }

    var strokes: [Stroke] = []

    func undo() { if !strokes.isEmpty { strokes.removeLast() } }
    func clear() { strokes = [] }

    static func path(_ stroke: Stroke) -> CGPath {
        let path = CGMutablePath()
        guard let first = stroke.points.first else { return path }
        path.move(to: first)
        if stroke.points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
        // Through the middles between the points, for a line without corners.
        for index in 1..<max(stroke.points.count, 1) {
            let before = stroke.points[index - 1], here = stroke.points[index]
            path.addQuadCurve(to: CGPoint(x: (before.x + here.x) / 2, y: (before.y + here.y) / 2), control: before)
        }
        if let last = stroke.points.last, stroke.points.count > 1 { path.addLine(to: last) }
        return path
    }

    static func draw(_ strokes: [Stroke], in context: CGContext) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            context.setStrokeColor(PenChoice.nsColor(stroke.argb).cgColor)
            context.setLineWidth(stroke.width)
            context.addPath(path(stroke))
            context.strokePath()
        }
    }

    /// The drawing cut to what was drawn, at twice the size it was drawn at, as a PNG.
    func picture() -> PictureFile? {
        var bounds = CGRect.null
        for stroke in strokes { bounds = bounds.union(DrawingBoard.path(stroke).boundingBoxOfPath.insetBy(dx: -stroke.width / 2 - 2, dy: -stroke.width / 2 - 2)) }
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { return nil }
        let scale: CGFloat = 2
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The sheet's y points down, the bitmap's up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        DrawingBoard.draw(strokes, in: context)
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        return PictureFile(data: data, fileExtension: "png", pixels: CGSize(width: width, height: height))
    }
}

private struct DrawingCanvas: NSViewRepresentable {
    let board: DrawingBoard
    let color: UInt32
    let width: CGFloat
    let erasing: Bool

    func makeNSView(context: Context) -> DrawingCanvasView { DrawingCanvasView() }

    func updateNSView(_ view: DrawingCanvasView, context: Context) {
        view.board = board
        view.color = color
        view.width = width
        view.erasing = erasing
        // Read here so that the view is drawn again when the strokes change.
        view.shown = board.strokes.count
        view.needsDisplay = true
    }
}

final class DrawingCanvasView: NSView {
    var board: DrawingBoard?
    var color: UInt32 = 0xFF25_2525
    var width: CGFloat = 4
    var erasing = false
    var shown = 0
    private var current: DrawingBoard.Stroke?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Drawing")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        MainActor.assumeIsolated {
            DrawingBoard.draw((board?.strokes ?? []) + (current.map { [$0] } ?? []), in: context)
        }
    }

    private func erase(at point: CGPoint) {
        MainActor.assumeIsolated {
            guard let board else { return }
            board.strokes.removeAll { stroke in
                DrawingBoard.path(stroke).copy(strokingWithWidth: max(stroke.width, 14), lineCap: .round, lineJoin: .round, miterLimit: 2).contains(point)
            }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if erasing { erase(at: point); return }
        current = DrawingBoard.Stroke(points: [point], argb: color, width: width)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if erasing { erase(at: point); return }
        guard current != nil else { return }
        if let last = current?.points.last, hypot(point.x - last.x, point.y - last.y) < 1.2 { return }
        current?.points.append(CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height)))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let stroke = current else { return }
        current = nil
        MainActor.assumeIsolated { board?.strokes.append(stroke) }
        needsDisplay = true
    }
}
