import AppKit
import SamsungNotesKit
import SwiftUI

/// Where on a page what is written in the Easy writing pad comes to lie: a box as high as a
/// line of handwriting is to be, which moves on as the pad fills.
struct PadTarget: Equatable {
    var page: Int
    /// The box's top left corner and its height, in the page's units. Its width is the pad's, at the same scale.
    var origin: CGPoint
    var height: Double

    /// A box near the top of a page, a comfortable line high.
    static func first(page: Int, pageWidth: Double, left: Double, top: Double) -> PadTarget {
        PadTarget(page: page, origin: CGPoint(x: left, y: top), height: pageWidth * 0.085)
    }
}

/// The Easy writing pad of the Windows client: a strip at the foot of the note to write large
/// in. What is written there is laid, small and in line, into the box marked on the page
/// above, and the box moves on as the strip fills: neat lines of handwriting without aiming.
struct EasyPad: View {
    static let height = 150.0
    static let padWidth = 640.0

    let pen: PenChoice
    /// The pad's width in points, and the width of the pen's line in it.
    let width: Double
    let lineWidth: Double
    /// Moves when the pad is wiped for the next stretch of writing.
    let revision: Int
    let isEmpty: Bool
    let onStroke: ([[CGPoint]], [Double], [Int]) -> Void
    let back: () -> Void
    let forward: () -> Void
    let newLine: () -> Void
    let smaller: () -> Void
    let larger: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "circle.grid.2x2.fill").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 30).accessibilityHidden(true)
                Text("Easy writing pad").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                key("textformat.size.smaller", "Smaller writing on the page", smaller)
                key("textformat.size.larger", "Larger writing on the page", larger)
                Divider().frame(height: 16).padding(.horizontal, 4)
                key("chevron.left", "Move back along the line", back)
                key("chevron.right", "Move on along the line", forward)
                key("return", "Start a new line", newLine)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Divider()
            ZStack {
                // Past this line the pad makes room by itself: what was written moves up into the page.
                Rectangle().fill(Color.accentColor.opacity(0.06)).frame(width: width * 0.15).frame(maxWidth: .infinity, alignment: .trailing)
                Rectangle().fill(Color.accentColor).frame(width: 1.5).offset(x: width * 0.35)
                if isEmpty {
                    Text("Write here to have your handwriting aligned neatly above").font(.title3).foregroundStyle(.secondary).allowsHitTesting(false)
                }
                InkOverlay(tool: .pen, shape: .line, color: PenChoice.nsColor(pen.liveColor), lineWidth: lineWidth, highlighter: pen.active.isMarker || pen.active == .tape,
                           revision: revision, picked: nil, onStroke: onStroke, onErase: { _ in }, onLasso: { _ in }, onPick: { _ in }, onTransform: { _ in }, onDelete: {}, onDropPicture: { _, _ in false })
            }
            .frame(width: width, height: EasyPad.height)
            .clipped()
        }
        .frame(width: width)
        .floatingBar()
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func key(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 26).contentShape(.rect) }
            .buttonStyle(.plain).hoverHighlight().named(help, above: true)
    }
}
