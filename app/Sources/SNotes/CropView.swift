import AppKit
import SamsungNotesKit
import SwiftUI

/// Cropping a picture: the whole picture is shown again, faded outside the part that is kept.
/// With the rectangle, its corners and sides are dragged, or the rectangle itself is moved;
/// with the loop, a line is drawn around what is to be kept. The picture's file is never cut:
/// the note only remembers which part of it to show.
struct CropView: NSViewRepresentable {
    /// The whole picture's frame, not turned, in points of the pages' space.
    let whole: CGRect
    /// Degrees clockwise, about `pivot`.
    let angle: Double
    let pivot: CGPoint
    let image: CGImage?
    let lasso: Bool
    let paper: NSColor
    /// The part kept, in fractions of the whole picture.
    @Binding var crop: CGRect
    /// A loop drawn around what to keep, in fractions of the whole picture.
    let looped: ([CGPoint]) -> Void
    let done: () -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> CropNSView {
        let view = CropNSView()
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: CropNSView, context: Context) {
        view.whole = whole
        view.angle = angle
        view.pivot = pivot
        view.image = image
        view.lasso = lasso
        view.paper = paper
        view.crop = crop
        view.changed = { crop = $0 }
        view.looped = looped
        view.done = done
        view.cancel = cancel
        view.needsDisplay = true
    }
}

final class CropNSView: NSView {
    var whole = CGRect.zero
    var angle = 0.0
    var pivot = CGPoint.zero
    var image: CGImage?
    var lasso = false
    var paper = NSColor.white
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var changed: ((CGRect) -> Void)?
    var looped: (([CGPoint]) -> Void)?
    var done: (() -> Void)?
    var cancel: (() -> Void)?

    private enum Grip: Equatable { case handle(Int), inside }
    private var held: Grip?
    private var start = CGPoint.zero
    private var startCrop = CGRect.zero
    private var loop: [CGPoint] = []
    private var tracking: NSTrackingArea?

    /// The smallest part that can be kept, in points on screen.
    static let least: CGFloat = 24

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Crop picture")
        setAccessibilityHelp("Drag the corners and sides to choose the part to keep. Return keeps it, Escape leaves the picture as it was.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A point of the view along the whole picture's own sides, from its top left corner.
    private func own(_ point: CGPoint) -> CGPoint {
        let radians = -angle * .pi / 180
        let dx = point.x - pivot.x, dy = point.y - pivot.y
        return CGPoint(x: dx * cos(radians) - dy * sin(radians) + pivot.x - whole.minX, y: dx * sin(radians) + dy * cos(radians) + pivot.y - whole.minY)
    }

    /// The kept part in points along the picture's own sides.
    private var kept: CGRect {
        CGRect(x: crop.minX * whole.width, y: crop.minY * whole.height, width: crop.width * whole.width, height: crop.height * whole.height)
    }

    private func handlePoint(_ index: Int, of rect: CGRect) -> CGPoint {
        let handle = PictureGripView.handles[index]
        return CGPoint(x: handle.x < 0 ? rect.minX : (handle.x > 0 ? rect.maxX : rect.midX), y: handle.y < 0 ? rect.minY : (handle.y > 0 ? rect.maxY : rect.midY))
    }

    private func grip(at point: CGPoint) -> Grip? {
        let at = own(point)
        let rect = kept
        for index in PictureGripView.handles.indices {
            let place = handlePoint(index, of: rect)
            if hypot(at.x - place.x, at.y - place.y) <= 14 { return .handle(index) }
        }
        return rect.contains(at) ? .inside : nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, whole.width > 1, whole.height > 1 else { return }
        context.saveGState()
        // Along the picture's own sides from here on.
        context.translateBy(x: pivot.x, y: pivot.y)
        context.rotate(by: angle * .pi / 180)
        context.translateBy(x: whole.minX - pivot.x, y: whole.minY - pivot.y)
        let all = CGRect(origin: .zero, size: whole.size)
        // The picture as it was shown lies beneath: paper over it, then the whole picture, faded.
        context.setFillColor(paper.cgColor)
        context.fill(all.insetBy(dx: -1, dy: -1))
        func drawPicture(alpha: CGFloat) {
            guard let image else { return }
            context.saveGState()
            context.setAlpha(alpha)
            context.translateBy(x: 0, y: all.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: all)
            context.restoreGState()
        }
        drawPicture(alpha: 0.3)
        let accent = NSColor.controlAccentColor.cgColor
        if lasso {
            // The whole picture is there to draw on; what the loop holds so far is shown clear.
            if loop.count > 2 {
                let path = CGMutablePath()
                path.addLines(between: loop)
                path.closeSubpath()
                context.saveGState()
                context.addPath(path)
                context.clip()
                drawPicture(alpha: 1)
                context.restoreGState()
            }
            if loop.count > 1 {
                context.setStrokeColor(accent)
                context.setLineWidth(2)
                context.setLineDash(phase: 0, lengths: [6, 4])
                context.setLineCap(.round)
                context.addLines(between: loop)
                context.strokePath()
            }
        } else {
            let rect = kept
            context.saveGState()
            context.clip(to: rect)
            drawPicture(alpha: 1)
            context.restoreGState()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(3)
            context.stroke(rect)
            context.setStrokeColor(accent)
            context.setLineWidth(1.5)
            context.stroke(rect)
            // Brackets at the corners and bars at the sides, to drag by.
            context.setFillColor(accent)
            let thick: CGFloat = 5, long: CGFloat = min(22, rect.width / 3, rect.height / 3)
            for (index, handle) in PictureGripView.handles.enumerated() {
                let at = handlePoint(index, of: rect)
                if handle.x != 0, handle.y != 0 {
                    let x = handle.x < 0 ? at.x - thick / 2 : at.x + thick / 2 - long, y = handle.y < 0 ? at.y - thick / 2 : at.y + thick / 2 - long
                    context.fill(CGRect(x: x, y: at.y - thick / 2, width: long, height: thick))
                    context.fill(CGRect(x: at.x - thick / 2, y: y, width: thick, height: long))
                } else if handle.x == 0 {
                    context.fill(CGRect(x: at.x - long / 2, y: at.y - thick / 2, width: long, height: thick))
                } else {
                    context.fill(CGRect(x: at.x - thick / 2, y: at.y - long / 2, width: thick, height: long))
                }
            }
        }
        context.restoreGState()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func cursor(for grip: Grip?, pressed: Bool) -> NSCursor {
        if lasso { return .crosshair }
        switch grip {
        case .none: return .arrow
        case .inside: return pressed ? .closedHand : .openHand
        case .handle(let index):
            let handle = PictureGripView.handles[index]
            let radians = angle * .pi / 180
            let x = Double(handle.x) * cos(radians) - Double(handle.y) * sin(radians), y = Double(handle.x) * sin(radians) + Double(handle.y) * cos(radians)
            let octant = Int((atan2(y, x) / (.pi / 4)).rounded())
            let positions: [NSCursor.FrameResizePosition] = [.right, .bottomRight, .bottom, .bottomLeft, .left, .topLeft, .top, .topRight]
            return NSCursor.frameResize(position: positions[((octant % 8) + 8) % 8], directions: .all)
        }
    }

    override func mouseMoved(with event: NSEvent) { cursor(for: held ?? grip(at: convert(event.locationInWindow, from: nil)), pressed: held != nil).set() }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }

    private func inside(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), whole.width), y: min(max(point.y, 0), whole.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let at = own(point)
        if lasso {
            // A press well outside the picture is done with it.
            if !CGRect(origin: .zero, size: whole.size).insetBy(dx: -20, dy: -20).contains(at) { cancel?(); return }
            loop = [inside(at)]
            held = .inside
            needsDisplay = true
            return
        }
        guard let found = grip(at: point) else {
            // A press beside the picture keeps what is chosen, as in the original.
            if !CGRect(origin: .zero, size: whole.size).insetBy(dx: -20, dy: -20).contains(at) { done?() }
            return
        }
        held = found
        start = at
        startCrop = kept
        cursor(for: found, pressed: true).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let held else { return }
        let at = own(convert(event.locationInWindow, from: nil))
        if lasso {
            let next = inside(at)
            if let last = loop.last, hypot(next.x - last.x, next.y - last.y) < 2 { return }
            loop.append(next)
            needsDisplay = true
            return
        }
        cursor(for: held, pressed: true).set()
        let dx = at.x - start.x, dy = at.y - start.y
        var rect = startCrop
        let least = min(CropNSView.least, whole.width, whole.height)
        switch held {
        case .inside:
            rect.origin.x = min(max(rect.minX + dx, 0), whole.width - rect.width)
            rect.origin.y = min(max(rect.minY + dy, 0), whole.height - rect.height)
        case .handle(let index):
            let handle = PictureGripView.handles[index]
            var left = rect.minX, top = rect.minY, right = rect.maxX, bottom = rect.maxY
            if handle.x < 0 { left = min(max(left + dx, 0), right - least) }
            if handle.x > 0 { right = max(min(right + dx, whole.width), left + least) }
            if handle.y < 0 { top = min(max(top + dy, 0), bottom - least) }
            if handle.y > 0 { bottom = max(min(bottom + dy, whole.height), top + least) }
            rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
        crop = CGRect(x: rect.minX / whole.width, y: rect.minY / whole.height, width: rect.width / whole.width, height: rect.height / whole.height)
        changed?(crop)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard held != nil else { return }
        held = nil
        if lasso {
            let drawn = loop
            loop = []
            needsDisplay = true
            let box = drawn.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            // Too small a loop is a slip of the hand: nothing is cut.
            guard drawn.count > 5, box.width >= CropNSView.least, box.height >= CropNSView.least else { return }
            looped?(drawn.map { CGPoint(x: $0.x / whole.width, y: $0.y / whole.height) })
            return
        }
        mouseMoved(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: done?()          // Return, Enter
        case 53: cancel?()            // Escape
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { cancel?() }
}

/// The bar shown while a picture is cropped.
struct CropBar: View {
    let lasso: Bool
    let canReset: Bool
    let reset: () -> Void
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: lasso ? "lasso" : "crop").foregroundStyle(.secondary)
            Text(lasso ? "Draw around the part to keep" : "Drag the corners to choose the part to keep")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Show Whole Picture", action: reset).disabled(!canReset).help("Take the crop off: the whole picture is still there")
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            if !lasso { Button("Done", action: done).buttonStyle(.glassProminent).keyboardShortcut(.defaultAction) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .floatingBar()
        .glassEffect(.regular, in: .capsule)
    }
}
