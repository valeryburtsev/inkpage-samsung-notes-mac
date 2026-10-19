import AppKit
import SamsungNotesKit

extension EditorChecks {
    /// The Easy writing pad's edges: the first stroke in a pad just opened is shown to the pad's lower edge.
    @MainActor static func padChecks(model: AppModel, shot: @MainActor (String) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        model.path = []
        await pause(500)
        model.createNote(handwritten: true)
        await pause(2200)
        guard let window = window() else { say("FAIL: no window"); return }
        func front() async {
            for _ in 0..<12 where !window.isKeyWindow {
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                await pause(150)
            }
        }
        func describe(_ view: NSView) -> String {
            var out = "frame \(view.frame.integral) visible \(view.visibleRect.integral)"
            var up = view.superview
            while let at = up {
                if at.layer?.masksToBounds == true || at is NSClipView { out += " | clips: \(type(of: at)) \(at.convert(at.bounds, to: view).integral)" }
                up = at.superview
            }
            return out
        }
        var plain = PenChoice()
        plain.kind = .fountain
        EditorRemote.shared.pen = plain
        EditorRemote.shared.pad = true
        await pause(1200)
        guard let pad = find(InkCanvasView.self, in: window.contentView).min(by: { $0.convert(CGPoint.zero, to: nil).y < $1.convert(CGPoint.zero, to: nil).y }) else { say("FAIL: no pad"); return }
        say("info before: \(describe(pad))")
        await front()
        // Down the pad's whole height, with the pointer's own events, one at a time as a hand moves.
        let points = (0...40).map { CGPoint(x: 120, y: 8 + Double($0) * 3.4) }
        func post(_ type: NSEvent.EventType, _ point: CGPoint) {
            if let event = NSEvent.mouseEvent(with: type, location: pad.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
        }
        post(.leftMouseDown, points[0])
        await pause(60)
        say("info after the press: \(describe(pad))")
        for point in points.dropFirst() { post(.leftMouseDragged, point); await pause(16) }
        say("info while drawing: \(describe(pad))")
        await shot("p1-pad-first-stroke-live")
        post(.leftMouseUp, points[points.count - 1])
        await pause(900)
        say("info after: \(describe(pad))")
        await shot("p2-pad-first-stroke")
        let full = pad.visibleRect.height >= pad.bounds.height - 1
        say("\(verdict(full)) the pad's drawing area is shown whole (\(Int(pad.visibleRect.height)) of \(Int(pad.bounds.height)))")
        EditorRemote.shared.pad = false
        // The pages down the side, for a look at where they meet the toolbar.
        EditorRemote.shared.pages = true
        await pause(900)
        await shot("p3-pages")
        EditorRemote.shared.pages = false
    }
}

extension EditorChecks {
    /// The pointer: a click on handwriting picks the block it belongs to, a drag moves it, a click
    /// on nothing lets go, a drag over nothing picks by a rectangle. With posted pointer events.
    @MainActor static func pointerChecks(model: AppModel, shot: @MainActor (String) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        model.path = []
        await pause(500)
        model.createNote(handwritten: true)
        await pause(2200)
        guard let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString), let window = window() else { say("FAIL: no note to draw in"); return }
        func canvas() -> InkCanvasView? { find(InkCanvasView.self, in: window.contentView).first }
        func front() async {
            for _ in 0..<12 where !window.isKeyWindow {
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                await pause(150)
            }
        }
        func draw(_ points: [CGPoint]) async {
            await front()
            if let canvas = canvas() { drag(canvas, points) }
            await pause(700)
        }
        func stored() -> [InkStroke] { Array(((try? model.store.load(id))?.strokes ?? [:]).values) }
        var plain = PenChoice()
        plain.kind = .ballpoint
        EditorRemote.shared.pen = plain
        EditorRemote.shared.tool = .pen
        await pause(500)
        let top = Double(canvas()?.visibleRect.minY ?? 0) + 120
        // A word of three letters close together, a stroke over it, and a stroke far below.
        for letter in 0..<3 {
            let x = 120 + Double(letter) * 32
            await draw((0...20).map { CGPoint(x: x + Double($0), y: top + 20 * sin(Double($0) / 3)) })
        }
        await draw((0...30).map { CGPoint(x: 115 + Double($0) * 4, y: top - 28 - 8 * sin(Double($0) / 9)) })
        await draw((0...30).map { CGPoint(x: 140 + Double($0) * 5, y: top + 260) })
        let drawn = session.note?.strokes.count ?? 0
        say("\(verdict(drawn == 5)) five strokes are drawn (\(drawn))")

        EditorRemote.shared.pointing = true
        EditorRemote.shared.panel = true
        await pause(600)
        // A click on the middle letter.
        await draw([CGPoint(x: 152 + 10, y: top + 20 * sin(10.0 / 3))])
        let picked = session.selection?.strokes.count ?? 0
        say("\(verdict(picked == 4)) a click on a letter picks the word and the stroke over it, not the one far below (\(picked) of 5)")
        await shot("q1-pointer-block")

        // Let go, then press on the far stroke and drag it at once: it moves, alone.
        await draw([CGPoint(x: 600, y: top + 120)])
        let cleared = session.selection == nil
        say("\(verdict(cleared)) a click on an empty place lets go")
        let far = stored().max { $0.bounds.minY < $1.bounds.minY }
        await draw((0...20).map { CGPoint(x: 200 + Double($0) * 3, y: top + 260 + Double($0) * 2) })
        await pause(600)
        let moved = stored().max { $0.bounds.minY < $1.bounds.minY }
        let unit = session.text.metrics.unit
        let shift = (moved?.bounds.minX ?? 0) - (far?.bounds.minX ?? 0)
        let words = stored().filter { $0.bounds.minY < (far?.bounds.minY ?? 0) - 50 }
        say("\(verdict(abs(shift - 60 * unit) < 3 * unit && words.count == 4 && session.selection?.strokes.count == 1)) a press on handwriting and a drag moves its block at once (moved by \(Int(shift / unit)) points)")

        // A drag over an empty place picks what the rectangle holds.
        await draw((0...20).map { CGPoint(x: 90 + Double($0) * 12, y: top - 60 + Double($0) * 5) })
        let boxed = session.selection?.strokes.count ?? 0
        say("\(verdict(boxed == 4)) a drag over an empty place picks what its rectangle holds (\(boxed))")
        await shot("q2-pointer-rectangle")

        // A text box and a picture on the page: the pointer picks and moves them too.
        let boxRect = CGRect(x: 520 * unit, y: (top + 40) * unit, width: 160 * unit, height: 50 * unit)
        let box = session.addTextBox(page: 0, rect: boxRect, text: "A box")
        let pictureRect = CGRect(x: 520 * unit, y: (top + 170) * unit, width: 140 * unit, height: 90 * unit)
        let before = Set(session.note?.document.floating.map(\.id) ?? [])
        if let png = testPicture(), let file = PictureFile(data: png) { session.addPicture(file, onPage: (0, pictureRect)) }
        await pause(1500)
        let picture = session.note?.document.floating.first { !before.contains($0.id) }?.id
        await draw([CGPoint(x: 600, y: top + 65)])
        let boxPicked = box != nil && session.pictureSelection == box && session.selection == nil
        say("\(verdict(boxPicked)) a click on a text box picks it")
        await draw((0...20).map { CGPoint(x: 600 + Double($0) * 2, y: top + 65 + Double($0) * 2) })
        await pause(700)
        let boxNow = (try? model.store.load(id))?.document.pages[0].objects.first { $0.id == box }?.rect ?? .zero
        let boxMoved = abs(boxNow.minX - boxRect.minX - 40 * unit) < 3 * unit && abs(boxNow.minY - boxRect.minY - 40 * unit) < 3 * unit
        say("\(verdict(boxMoved)) a press on a text box and a drag moves it")
        await draw([CGPoint(x: 590, y: top + 215)])
        let picturePicked = picture != nil && session.pictureSelection == picture
        say("\(verdict(picturePicked)) a click on a picture picks it")
        await draw((0...20).map { CGPoint(x: 590 - Double($0) * 2, y: top + 215 + Double($0) * 3) })
        await pause(800)
        let pictureNow = (try? model.store.load(id))?.document.floating.first { $0.id == picture }?.rect ?? .zero
        let pictureMoved = abs(pictureNow.minX - pictureRect.minX + 40 * unit) < 3 * unit && abs(pictureNow.minY - pictureRect.minY - 60 * unit) < 3 * unit
        say("\(verdict(pictureMoved)) a press on a picture and a drag moves it")
        await shot("q3-pointer-picture")
        // A click on handwriting lets the picture go and picks the handwriting.
        await draw([CGPoint(x: 152 + 10, y: top + 20 * sin(10.0 / 3))])
        let back = session.pictureSelection == nil && (session.selection?.strokes.count ?? 0) == 4
        say("\(verdict(back)) a click on handwriting then picks the handwriting, and the picture is let go")

        // A rectangle over the handwriting, the text box and the picture picks all of them; a drag moves them together, and one Undo puts them back.
        await draw((0...20).map { CGPoint(x: 90 + Double($0) * 32, y: top - 70 + Double($0) * 18) })
        let mixed = session.selection
        let all = mixed?.strokes.count == 4 && mixed?.objects == Set([box, picture].compactMap { $0 })
        say("\(verdict(all)) the pointer's rectangle picks handwriting, text boxes and pictures together (\(mixed?.strokes.count ?? 0) strokes, \(mixed?.objects.count ?? 0) objects)")
        await shot("q4-pointer-mixed")
        func places() -> [CGFloat] {
            let document = (try? model.store.load(id))?.document
            let boxY = document?.pages[0].objects.first { $0.id == box }?.rect.minY ?? 0
            let pictureY = document?.floating.first { $0.id == picture }?.rect.minY ?? 0
            let inkY = stored().filter { $0.bounds.minY < boxY + 200 * unit }.map(\.bounds.minY).min() ?? 0
            return [boxY, pictureY, inkY]
        }
        let was = places()
        await tick()
        await draw((0...20).map { CGPoint(x: 152 + 10, y: top + 20 * sin(10.0 / 3) + Double($0) * 4) })
        await pause(800)
        let now = places()
        let together = zip(was, now).allSatisfy { abs($1 - $0 - 80 * unit) < 3 * unit }
        say("\(verdict(together)) dragged, they all move together by the same (\(now.indices.map { Int((now[$0] - was[$0]) / unit) }))")
        await tick()
        session.undoManager?.undo()
        await tick()
        await pause(900)
        let undone = places()
        let back2 = zip(was, undone).allSatisfy { abs($1 - $0) < 2 * unit }
        say("\(verdict(back2)) one Undo puts them all back")

        EditorRemote.shared.pointing = false
    }
}
