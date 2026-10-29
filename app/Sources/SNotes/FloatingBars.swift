import AppKit
import SwiftUI

/// What lies under the pointer, for the views that choose the pointer's shape themselves.
@MainActor
enum PointerOver {
    /// The view that is topmost in the window at an event's place: the one a press would go to.
    static func view(_ event: NSEvent, in window: NSWindow?) -> NSView? {
        guard let content = window?.contentView else { return nil }
        return (content.superview ?? content).hitTest(event.locationInWindow)
    }

    /// A field that text is typed into, which shows the text pointer of its own accord.
    static func isTextInput(_ view: NSView?) -> Bool { view is NSTextField || view is NSTextView }
}

/// Laid behind a bar of controls that floats over the note. The note's text and the drawing
/// area reach under such a bar, and without this they would go on choosing the pointer's shape
/// there (the text's I-beam over a button) and take the presses that fall between the buttons.
struct BarShield: NSViewRepresentable {
    final class Shield: NSView {
        private var tracking: NSTrackingArea?

        override func mouseDown(with event: NSEvent) {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        /// Over the bar the pointer is an arrow, as over any toolbar; a field of the bar keeps its own.
        private func show(_ event: NSEvent) {
            let over = PointerOver.view(event, in: window)
            if PointerOver.isTextInput(over) || over is PointerOwner { return }
            NSCursor.arrow.set()
        }

        override func mouseMoved(with event: NSEvent) { show(event) }
        override func mouseEntered(with event: NSEvent) { show(event) }
        override func cursorUpdate(with event: NSEvent) { show(event) }

        // Off the bar again: what lies there now is asked for its pointer, since it had no
        // edge of its own crossed to be asked by.
        override func mouseExited(with event: NSEvent) {
            guard let under = PointerOver.view(event, in: window), under !== self else { return }
            under.cursorUpdate(with: event)
        }
    }

    func makeNSView(context: Context) -> Shield { Shield() }
    func updateNSView(_ view: Shield, context: Context) {}
}

/// A control of a bar lights up under the pointer, so that it is seen to be a button and which
/// one a press would reach.
private struct HoverHighlight: ViewModifier {
    let radius: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(hovering && enabled ? 0.1 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

extension View {
    /// For a button or menu of a bar: it lights up under the pointer.
    func hoverHighlight(radius: CGFloat = 9) -> some View { modifier(HoverHighlight(radius: radius)) }

    /// For a bar of controls that floats over the note: the pointer is an arrow over it, and a
    /// press between its controls stays with it.
    func floatingBar() -> some View { background { BarShield() } }
}
