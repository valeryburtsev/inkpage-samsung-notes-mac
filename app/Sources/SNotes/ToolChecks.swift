import AppKit
import SamsungNotesKit

extension EditorChecks {
    /// The tools down the side and their options, tried with the pointer's own events: the two
    /// highlighters, straight lines, the area eraser, the rectangle, changing style.
    @MainActor static func toolChecks(model: AppModel, shot: @MainActor (String) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        model.path = []
        await pause(500)
        model.createNote(handwritten: true)
        await pause(2200)
        guard let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString) else { say("FAIL: no note to draw in"); return }
        func canvas() -> InkCanvasView? { window().flatMap { find(InkCanvasView.self, in: $0.contentView).first } }
        func strokes() -> [InkStroke] { Array(session.note?.strokes.values ?? [:].values) }
        func front() async {
            guard let window = window() else { return }
            for _ in 0..<12 where !window.isKeyWindow {
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                await pause(150)
            }
        }
        func draw(_ points: [CGPoint]) async {
            await front()
            if let canvas = canvas() { drag(canvas, points) }
            await pause(900)
        }
        func line(_ y: Double, from: Double = 120, to: Double = 520, wobble: Double = 0) -> [CGPoint] {
            (0...40).map { CGPoint(x: from + (to - from) * Double($0) / 40, y: y + wobble * sin(Double($0) / 3)) }
        }
        let top = Double(canvas()?.visibleRect.minY ?? 0) + 120
        EditorRemote.shared.panel = true

        // The pens' panel, and a line with the pen as it comes.
        var choice = PenChoice()
        choice.kind = .ballpoint
        EditorRemote.shared.pen = choice
        EditorRemote.shared.tool = .pen
        await pause(600)
        await draw(line(top, wobble: 9))
        await shot("t1-pen-panel")
        let first = strokes()
        say("\(verdict(first.count == 1 && first.first?.pen.kind == .ballpoint && first.first.map { $0.argb == 0xFFFF_CB30 } == true)) the pen writes in the colour the Windows client gives it at first")

        // "Straighten lines": a wavering line is stored straight.
        choice.setting.straight = true
        EditorRemote.shared.pen = choice
        await pause(400)
        await draw(line(top + 50, wobble: 14))
        let straight = strokes().first { stroke in !first.contains { $0.id == stroke.id } }
        // How far its points stray from the line between its ends.
        let spread: Double = straight.flatMap { stroke -> Double? in
            guard let from = stroke.points.first, let to = stroke.points.last else { return nil }
            let length = max(hypot(to.x - from.x, to.y - from.y), 0.001)
            return stroke.points.map { abs(($0.x - from.x) * (to.y - from.y) - ($0.y - from.y) * (to.x - from.x)) / length }.max()
        } ?? 99
        say("\(verdict(straight != nil && spread < 1.5 && (straight?.points.count ?? 0) > 20)) with Straighten lines on, a wavering line is stored straight (it strays \(String(format: "%.1f", spread)))")
        choice.setting.straight = false

        // The highlighter tool keeps its own pen: the marker pen, see-through.
        choice.active = .marker
        EditorRemote.shared.pen = choice
        await pause(500)
        await draw(line(top + 100))
        await shot("t2-highlighter-panel")
        let marker = strokes().first { $0.pen.kind == .marker }
        say("\(verdict(marker != nil && marker?.penName?.hasSuffix("Marker3") == true && (marker.map { $0.argb >> 24 } ?? 255) < 160)) the marker pen writes see-through, as its own pen (\(marker?.penName?.split(separator: ".").last ?? "none"), alpha \(marker.map { $0.argb >> 24 } ?? 0))")

        // The area eraser takes the middle out of a line and leaves both ends.
        let before = strokes().count
        var rubber = EraserChoice()
        rubber.area = true
        rubber.level = 6
        EditorRemote.shared.eraser = rubber
        EditorRemote.shared.tool = .eraser
        await pause(600)
        await draw([CGPoint(x: 320, y: top - 30), CGPoint(x: 320, y: top - 10), CGPoint(x: 320, y: top + 10), CGPoint(x: 320, y: top + 25)])
        await shot("t3-eraser-panel")
        let whole: CGRect = first.first?.bounds ?? .zero
        let pieces: [InkStroke] = strokes().filter { $0.pen.kind == .ballpoint && abs($0.bounds.midY - whole.midY) < whole.height + 8 && $0.bounds.width < whole.width * 0.7 }
        say("\(verdict(strokes().count == before + 1 && pieces.count == 2)) the area eraser cuts the line in two and leaves both ends (\(before) strokes, then \(strokes().count))")
        session.undoManager?.undo()
        await pause(900)
        say("\(verdict(strokes().count == before)) and Undo makes it whole again")
        // "Erase highlighter only" passes over the pen's lines.
        rubber.area = false
        rubber.highlighterOnly = true
        EditorRemote.shared.eraser = rubber
        await pause(400)
        await draw((0...35).map { CGPoint(x: 300, y: top - 20 + Double($0) * 4) })
        let afterOnly = strokes()
        say("\(verdict(afterOnly.count == before - 1 && !afterOnly.contains { $0.pen.kind == .marker })) with Erase highlighter only, a sweep over all three lines takes the highlighter's alone (\(afterOnly.count) left)")

        // The rectangle picks what lies in it; with "partially selected" off, only what lies in it whole.
        var pick = SelectChoice()
        pick.rectangle = true
        pick.partial = false
        EditorRemote.shared.picking = pick
        EditorRemote.shared.tool = .select
        await pause(600)
        await draw([CGPoint(x: 80, y: top + 30), CGPoint(x: 300, y: top + 50), CGPoint(x: 400, y: top + 75)])
        say("\(verdict(session.selection == nil)) a rectangle over half a line picks nothing while only whole objects count")
        pick.partial = true
        EditorRemote.shared.picking = pick
        await pause(400)
        await draw([CGPoint(x: 80, y: top + 30), CGPoint(x: 300, y: top + 50), CGPoint(x: 400, y: top + 75)])
        await shot("t4-select-panel")
        say("\(verdict(session.selection?.strokes.count == 1)) and picks the line it touches when partly selected objects count")

        // Change style: the picked line gets another colour and another size, and stays picked.
        EditorRemote.shared.styling = true
        await pause(600)
        let picked = session.selection?.strokes.first.flatMap { session.note?.strokes[$0] }
        session.restyleSelection(argb: 0xFF14_47FF, level: 80)
        await pause(900)
        let restyled = session.selection?.strokes.first.flatMap { session.note?.strokes[$0] }
        await shot("t5-change-style-panel")
        say("\(verdict(picked != nil && restyled != nil && restyled?.argb == 0xFF14_47FF && (restyled?.penSize ?? 0) > (picked?.penSize ?? 99) * 1.5 && restyled?.points.count == picked?.points.count)) Change style gives the picked line another colour and size")
        EditorRemote.shared.styling = false

        // The pen's four lines: dashed keeps the level of its size, even says so; both are one unbroken stroke.
        var liner = PenChoice()
        liner.kind = .ballpoint
        liner.setting.line = PenLine.dashed.rawValue
        EditorRemote.shared.pen = liner
        EditorRemote.shared.tool = .pen
        await pause(600)
        let known = Set(strokes().map(\.id))
        await draw(line(top + 160))
        liner.setting.line = PenLine.even.rawValue
        EditorRemote.shared.pen = liner
        await pause(400)
        await draw(line(top + 200))
        let lined = strokes().filter { !known.contains($0.id) }
        let dashed = lined.first { $0.style.lineType == 1 }, even = lined.first { $0.style.fixedWidth }
        say("\(verdict(lined.count == 2 && dashed?.style.sizeLevel == 30 && (dashed?.points.count ?? 0) > 20 && even?.style.lineType == 0)) a dashed line is one stroke marked dashed at its size's level, an even line one marked even")

        // The tape: a band in its pattern over the page; a press on it opens it, another closes it.
        var taper = PenChoice()
        taper.group = .tape
        EditorRemote.shared.pen = taper
        await pause(600)
        await draw(line(top + 260))
        await shot("t7-tape-panel")
        let tape = strokes().first { $0.pen.kind == .tape }
        say("\(verdict(tape != nil && tape?.style.colorType == 2 && tape?.style.patternIndex == 1 && tape?.style.revealed == false && (tape?.penSize ?? 0) > 30)) the tape is a stroke of the tape pen in its first pattern, closed (\(Int(tape?.penSize ?? 0)) wide)")
        await draw([CGPoint(x: 300, y: top + 260)])
        let opened = strokes().first { $0.pen.kind == .tape }
        say("\(verdict(strokes().filter { $0.pen.kind == .tape }.count == 1 && opened?.style.revealed == true)) a press on the tape opens it")
        await shot("t8-tape-open")
        // "Erase tape only" passes over the lines beside it.
        var rubberOnly = EraserChoice()
        rubberOnly.tapeOnly = true
        EditorRemote.shared.eraser = rubberOnly
        EditorRemote.shared.tool = .eraser
        await pause(500)
        let beforeTape = strokes().count
        await draw((0...30).map { CGPoint(x: 310, y: top + 150 + Double($0) * 4) })
        say("\(verdict(strokes().count == beforeTape - 1 && !strokes().contains { $0.pen.kind == .tape })) with Erase tape only, a sweep over the lines and the tape takes the tape alone")

        // The Easy writing pad: written large at the foot of the note, laid small into the box on the page.
        var plain = PenChoice()
        plain.kind = .fountain
        EditorRemote.shared.pen = plain
        EditorRemote.shared.pad = true
        await pause(900)
        let padCanvas = window().flatMap { find(InkCanvasView.self, in: $0.contentView).min { $0.convert(CGPoint.zero, to: nil).y < $1.convert(CGPoint.zero, to: nil).y } }
        let beforePad = Set(strokes().map(\.id))
        if let padCanvas {
            await front()
            drag(padCanvas, (0...30).map { CGPoint(x: 60 + Double($0) * 6, y: 75 + 40 * sin(Double($0) / 4)) })
            await pause(900)
            drag(padCanvas, (0...30).map { CGPoint(x: 380 + Double($0) * 6, y: 75 + 40 * cos(Double($0) / 4)) })
            await pause(1200)
        }
        await shot("t9-easy-pad")
        let padded = strokes().filter { !beforePad.contains($0.id) }.sorted { $0.bounds.minX < $1.bounds.minX }
        let smallOnPage: Bool = padded.count == 2 && padded.allSatisfy { $0.bounds.height < 60 && $0.bounds.height > 20 && $0.bounds.minY < 140 }
        say("\(verdict(padCanvas != nil && smallOnPage && (padded.last?.bounds.minX ?? 0) > (padded.first?.bounds.maxX ?? 9_999))) two strokes written large in the pad lie small, one after the other, at the head of the page (\(padded.map { Int($0.bounds.height) }))")
        // The second went past the pad's line: the pad made room, and what is written next goes on after it.
        if let padCanvas {
            drag(padCanvas, (0...20).map { CGPoint(x: 40 + Double($0) * 5, y: 75 + 30 * sin(Double($0) / 3)) })
            await pause(1200)
        }
        let paddedIDs = Set(padded.map(\.id))
        let third = strokes().first { !beforePad.contains($0.id) && !paddedIDs.contains($0.id) }
        say("\(verdict(third != nil && (third?.bounds.minX ?? 0) > (padded.last?.bounds.maxX ?? 9_999))) written past the pad's line, the pad makes room and the next stroke goes on after the last")
        EditorRemote.shared.pad = false
        await pause(500)

        // The keyboard's options in the panel.
        EditorRemote.shared.drawing = false
        await shot("t6-text-panel")
        say("\(verdict(window().map { !find(NoteTextView.self, in: $0.contentView).isEmpty } ?? false)) the keyboard's options take the panel")
        EditorRemote.shared.panel = false
    }
}

extension EditorChecks {
    /// Undo for the changes it used not to take back: the paper, a deleted page, an inserted PDF.
    @MainActor static func undoChecks(model: AppModel) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        model.path = []
        await pause(500)
        model.createNote(handwritten: true)
        await pause(2200)
        guard let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString) else { say("FAIL: no note"); return }
        func stored() -> NoteDocument? { (try? model.store.load(id))?.document }
        func undo() async { session.undoManager?.undo(); await pause(1500) }
        func redo() async { session.undoManager?.redo(); await pause(1500) }

        // The paper's colour.
        let plain = stored()?.pages.first?.background ?? 0
        session.setPaperColor(0xFFFF_EC94)
        await pause(1500)
        say("\(verdict(stored()?.pages.first?.background == 0xFFFF_EC94)) the paper is given a colour")
        await undo()
        say("\(verdict(stored()?.pages.first?.background == plain && session.note?.document.pages.first?.background == plain)) Undo gives the paper its colour back")
        await redo()
        say("\(verdict(stored()?.pages.first?.background == 0xFFFF_EC94)) and Redo colours it again")
        await undo()

        // A PDF of two pages, put in and taken back.
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-undo-check.pdf")
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        if let pdf = CGContext(pdfURL as CFURL, mediaBox: &box, nil) {
            for _ in 1...2 { pdf.beginPDFPage(nil); pdf.setFillColor(CGColor(gray: 0.5, alpha: 1)); pdf.fill(CGRect(x: 60, y: 200, width: 300, height: 200)); pdf.endPDFPage() }
            pdf.closePDF()
        }
        let pagesBefore = stored()?.pages.count ?? 0
        session.addPDF(pdfURL) { _ in }
        await pause(3000)
        let withPDF = stored()
        say("\(verdict((withPDF?.pages.filter { $0.pdf != nil }.count ?? 0) == 2)) a PDF of two pages is put into the note")
        await undo()
        let without = stored()
        say("\(verdict(without?.pages.count == pagesBefore && without?.pages.contains { $0.pdf != nil } == false)) Undo takes its pages and the document out again (\(without?.pages.count ?? 0) pages)")
        await redo()
        say("\(verdict((stored()?.pages.filter { $0.pdf != nil }.count ?? 0) == 2)) Redo puts them back")

        // A page of it deleted with what was drawn on it, and brought back.
        let first = stored()?.pages.firstIndex { $0.pdf != nil } ?? 0
        session.draw([NewStroke(points: (0..<12).map { InkPoint(x: 100 + Double($0) * 8, y: 200, pressure: 1, time: $0 * 8) }, argb: 0xFF25_2525, penSize: 4)], page: first)
        await pause(1500)
        let drawn = (try? model.store.load(id))?.strokes.count ?? 0
        session.removePage(first)
        await pause(2000)
        let afterRemove = try? model.store.load(id)
        say("\(verdict(drawn == 1 && (afterRemove?.document.pages.filter { $0.pdf != nil }.count ?? 0) == 1 && afterRemove?.strokes.isEmpty == true)) a page is deleted with what was drawn on it")
        await undo()
        let back = try? model.store.load(id)
        let backPages: [Int?] = back?.document.pages.compactMap { $0.pdf?.page } ?? []
        say("\(verdict(backPages == [0, 1] && back?.strokes.count == 1 && back?.document.pages[safe: first]?.objects.count == 1)) Undo brings the page back, and the stroke on it")
        say("\(verdict(model.library.notes[id]?.pending != nil && model.library.notes[id]?.unsentStrokes?.isEmpty == false)) and the note waits to be sent as it now stands, the stroke with it")
        try? FileManager.default.removeItem(at: pdfURL)
    }
}
