import AppKit
import SamsungNotesKit

extension EditorChecks {
    /// Development aid: `--editor-check=<out> --transition-only` on an empty `--store` records the
    /// window, frame by frame, while a note is opened and while the list comes back, so that what
    /// jumps can be seen. Frames are kept in memory while recording and written afterwards.
    @MainActor static func transitionFrames(model: AppModel, to folder: URL) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let edits = model.edits
        _ = try? edits.createTextNote(title: "Weekly plan", body: "Monday: call the bank\nTuesday: dentist at 10\nWednesday: finish the slides")
        let id = try? edits.createTextNote(title: "Garden ideas", body: "Tulips along the fence\nA bench under the apple tree")
        if let id {
            let points = (0...60).map { index -> InkPoint in
                let t = Double(index) / 60 * 2 * .pi
                return InkPoint(x: 400 + 120 * cos(t), y: 420 + 120 * sin(t), pressure: 0.8, time: index * 12)
            }
            _ = try? edits.addStrokes(id, page: 0, strokes: [NewStroke(points: points, argb: 0xFFFF_3636, penSize: 8, pen: .fountain)])
        }
        model.changed(sync: false)
        model.path = []
        await pause(2500)

        /// Frames are taken on a thread of their own: what the screen shows while the app's main
        /// thread is busy is caught too.
        final class Recorder: @unchecked Sendable {
            let lock = NSLock()
            var frames: [(Int, CGImage)] = []
        }
        func record(_ name: String, for milliseconds: Int, _ action: () -> Void) async {
            guard let window = window() else { return }
            let number = UInt32(window.windowNumber)
            let recorder = Recorder()
            let start = Date()
            let thread = Thread {
                while Int(Date().timeIntervalSince(start) * 1000) < milliseconds {
                    if let image = create(.null, 1 << 3, number, 1 | 1 << 3)?.takeRetainedValue() {
                        recorder.lock.lock(); recorder.frames.append((Int(Date().timeIntervalSince(start) * 1000), image)); recorder.lock.unlock()
                    }
                    Thread.sleep(forTimeInterval: 0.008)
                }
            }
            thread.start()
            action()
            await pause(milliseconds + 100)
            let frames = recorder.frames
            for (index, frame) in frames.enumerated() {
                let data = NSBitmapImageRep(cgImage: frame.1).representation(using: .png, properties: [:])
                try? data?.write(to: folder.appendingPathComponent(String(format: "%@-%02d-%04dms.png", name, index, frame.0)))
            }
            say("\(name): \(frames.count) frames")
        }
        if let id { await record("open", for: 1400) { model.open(id) } }
        await pause(1500)
        await record("back", for: 1400) { model.path = [] }
        // Again, with a click on the window's own back button, as a person goes back.
        await pause(1500)
        if let id { await record("open2", for: 1000) { model.open(id) } }
        await pause(1200)
        if let window = window() {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await pause(400)
            // The back button stands left of the title, in the toolbar.
            let point = NSPoint(x: 157, y: window.frame.height - 26)
            await record("button", for: 1200) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
                }
            }
            say("after the click the list is \(model.path.isEmpty ? "back" : "not back")")
        }
    }
}
