import AppKit

/// A crossfade over a window while what it shows changes a lot at once (a note opened, the list
/// coming back): a picture of the window as it was lies over it, the change is made beneath, and
/// the picture fades out once the new layout has settled. The frames in between, in which the
/// split view brings its folders column a frame after the list, are never seen.
@MainActor
enum WindowCover {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// The window as the screen shows it, toolbar and glass included; nil if it cannot be had.
    private static func picture(of window: NSWindow) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // This window alone, without its shadow, at the screen's resolution.
        return create(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue()
    }

    /// The main window, with the list of notes: the one a note opens in and goes back from.
    static var notesWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true } ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    /// Makes `change` beneath a picture of the window and fades the picture out. Without a window
    /// in front, or when the system asks for less motion, the change is simply made.
    static func crossfade(_ window: NSWindow?, _ change: () -> Void) {
        guard let window, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let frame = window.contentView?.superview, let image = picture(of: window) else { change(); return }
        let cover = NSImageView(frame: frame.bounds)
        cover.image = NSImage(cgImage: image, size: frame.bounds.size)
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = [.width, .height]
        cover.setAccessibilityElement(false)
        frame.addSubview(cover, positioned: .above, relativeTo: nil)
        change()
        // Once the main thread is free again (the note's view taken down or put up), and a moment
        // more for the split view's columns: then the picture goes.
        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    cover.animator().alphaValue = 0
                }, completionHandler: { cover.removeFromSuperview() })
            }
        }
    }
}
