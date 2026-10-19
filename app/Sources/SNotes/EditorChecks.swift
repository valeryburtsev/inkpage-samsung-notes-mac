import AppKit
import SamsungNotesKit
import SwiftUI

/// Lets the editor's own check pick tools the way the tool strip does.
@MainActor @Observable
final class EditorRemote {
    static let shared = EditorRemote()
    var tool: InkTool?
    var pen: PenChoice?
    var drawing: Bool?
    /// Sets how the eraser rubs out and how the selection picks, takes the selection tool up
    /// to change styles, and opens or closes the panel of the tool's options.
    var eraser: EraserChoice?
    var picking: SelectChoice?
    var styling: Bool?
    var panel: Bool?
    /// Opens or closes the Easy writing pad.
    var pad: Bool?
    /// Takes the pointer up, or puts it down.
    var pointing: Bool?
    /// Shows every control's label at once, for a picture of them.
    var showLabels = false
    /// Shows or hides the pages down the side.
    var pages: Bool?
    /// Opens or closes the note style panel, and chooses how the pages scroll.
    var style: Bool?
    var scroll: ScrollDirection?
    /// Turns to a page.
    var page: Int?
    /// Opens a sticky note or a table to be written in where it stands, and closes it again.
    var smartBegin: String?
    var smartDone = 0
    /// Shows or hides the sheet that asks for a new table's rows and columns.
    var tableSetup: Bool?
    /// Chooses an item of the Insert menu.
    var insert: InsertKind?
    /// Does to the table that is open what one of its handles, menus or panels would: the
    /// change is made when the count goes up.
    @ObservationIgnored var tableChange: ((TableLive) -> Void)?
    var tableStep = 0
    /// What the open table is, for the check to read.
    @ObservationIgnored var tableOpen: TableLive?
    /// Sets a new text box down, opens one to be written in, or ends the writing: done when the count goes up.
    enum BoxAction { case new, begin(String), done }
    @ObservationIgnored var boxAction: BoxAction?
    var boxStep = 0
}

/// Development aid: `--editor-check=<folder>` (with `--store=<a copy of a library> --demo`) makes
/// a note, types, formats, pastes a picture, draws with several pens, moves and deletes ink with
/// real events, saves a picture of the window after each step and writes what was stored to
/// `report.txt`. It changes the library it is given.
@MainActor
enum EditorChecks {
    static var lines: [String] = []
    static func say(_ text: String) {
        lines.append(text)
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        var out: [T] = []
        if let found = view as? T { out.append(found) }
        for child in view.subviews { out.append(contentsOf: find(type, in: child)) }
        return out
    }

    static func window() -> NSWindow? {
        NSApplication.shared.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.height > 300 && !$0.isSheet && !($0 is NSPanel) }
    }

    static func capture(_ window: NSWindow) -> Data? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func drag(_ view: InkCanvasView, _ points: [CGPoint], flags: NSEvent.ModifierFlags = []) {
        guard let window = view.window, let first = points.first, let last = points.last else { return }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // Through the app's own event queue, so that everything an event brings with it happens too
        // (an undo group per event, for one).
        if let down = event(.leftMouseDown, first) { NSApp.postEvent(down, atStart: false) }
        for point in points.dropFirst() { if let move = event(.leftMouseDragged, point) { NSApp.postEvent(move, atStart: false) } }
        if let up = event(.leftMouseUp, last) { NSApp.postEvent(up, atStart: false) }
    }

    /// Picking the text of a PDF under a note's pages, with the pointer's own events.
    @MainActor static func pdfTextChecks(model: AppModel, note id: String, shot: @MainActor (String) async -> Void, tick: @MainActor () async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        guard let session = NoteSession.live.object(forKey: id as NSString), let view = session.text.view, let window = view.window, let layout = session.text.pages else { say("FAIL: no open note to pick text in"); return }
        let pdf = session.pdfText
        let metrics = session.text.metrics
        /// A place on a page of the note as a place in the text view.
        func place(_ page: Int, _ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / Double(metrics.unit) - Double(metrics.left), y: (layout.top(page) + point.y) / Double(metrics.unit) - Double(metrics.top))
        }
        func post(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = .option) {
            if let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) { NSApp.postEvent(event, atStart: false) }
        }
        /// A press on a window that is not in front only brings it to the front: it is brought
        /// there first, and waited for, since whoever sits at the Mac may have taken the front since.
        func front() async {
            for _ in 0..<12 where !window.isKeyWindow {
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                await pause(150)
            }
        }
        func moved(_ point: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSCursor {
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { view.mouseMoved(with: event) }
            return NSCursor.current
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await pause(600)
        let lines = pdf.lines(page: 0)
        guard lines.count >= 4 else { say("FAIL: the PDF's first page has no lines of text to pick (\(lines.count))"); return }
        say("\(verdict(true)) the first page of the PDF has \(lines.count) lines of text")
        func over(_ catcher: PDFTextCatcher.CatcherView, _ point: CGPoint) -> NSCursor {
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { catcher.mouseMoved(with: event) }
            return NSCursor.current
        }

        // A note made of a PDF is paper to write on: it opens with the pen in hand.
        say("\(verdict(!find(InkCanvasView.self, in: window.contentView).isEmpty)) a note made of a PDF opens with the pen in hand")
        // With the keyboard and no key held, the PDF's text is not picked, and the pointer over it is an arrow, not the text pointer.
        EditorRemote.shared.drawing = false
        await pause(900)
        let typed = lines[0]
        let k1 = place(0, CGPoint(x: typed.minX + 2, y: typed.midY)), k2 = place(0, CGPoint(x: typed.maxX - 2, y: typed.midY))
        await front()
        post(.leftMouseDown, k1, flags: [])
        post(.leftMouseDragged, k2, flags: [])
        post(.leftMouseUp, k2, flags: [])
        await pause(700)
        NSCursor.iBeam.set()
        let plainPointer: Bool = moved(place(0, CGPoint(x: typed.midX, y: typed.midY))) == NSCursor.arrow
        say("\(verdict(pdf.isEmpty && plainPointer)) with the keyboard, dragging over the PDF's text picks nothing, and the pointer there is an arrow")
        // With ⌥ held, the PDF's text is picked as in Preview.

        // Dragged along its first line: that line is picked, and marked on the page.
        let first = lines[0]
        let from = place(0, CGPoint(x: first.minX + 2, y: first.midY)), to = place(0, CGPoint(x: first.maxX - 2, y: first.midY))
        await front()
        post(.leftMouseDown, from)
        for step in 1...6 { post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * Double(step) / 6, y: from.y)) }
        post(.leftMouseUp, to)
        await pause(900)
        let line = pdf.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let marked: CGRect = pdf.marks.first?.rects.first ?? .zero
        let lineRight: Bool = !line.isEmpty && !line.contains("\n") && pdf.marks.count == 1 && pdf.marks.first?.page == 0 && abs(marked.midY - first.midY) < 4 && marked.width > first.width * 0.8
        say("\(verdict(lineRight)) dragging along the first line picks it: \(line.count) characters, \(line.split(separator: " ").count) words, marked on the page")
        await shot("p4-pdf-text-picked")

        // Copy puts it on the pasteboard, through the Edit menu's own way to whoever has the keys.
        let board = NSPasteboard.general
        let before = board.string(forType: .string)
        board.clearContents()
        // The text view holds the keys after the drag, so Copy in the Edit menu reaches it; it is sent to it here, whichever window is in front.
        let holdsKeys: Bool = window.firstResponder === view
        let sent: Bool = NSApp.sendAction(#selector(NSText.copy(_:)), to: window.firstResponder, from: nil)
        let copied: String = board.string(forType: .string) ?? ""
        let copyRight: Bool = holdsKeys && sent && !line.isEmpty && copied.trimmingCharacters(in: .whitespacesAndNewlines) == line
        say("\(verdict(copyRight)) Copy puts the picked text on the pasteboard\(copyRight ? "" : " (keys \(holdsKeys), sent \(sent), \(copied.count) characters for \(line.count))")")
        board.clearContents()
        if let before { board.setString(before, forType: .string) }
        await tick()

        // Pressed twice on a word: the word. Three times: its line.
        let body = lines[lines.count / 2]
        let inWord = place(0, CGPoint(x: body.minX + body.width * 0.3, y: body.midY))
        await front()
        post(.leftMouseDown, inWord, clicks: 2)
        post(.leftMouseUp, inWord, clicks: 2)
        await pause(700)
        let word = pdf.string.trimmingCharacters(in: .whitespacesAndNewlines)
        say("\(verdict(!word.isEmpty && !word.contains(" ") && pdf.marks.count == 1)) two presses on a word pick the word (\(word.count) letters)")
        await front()
        post(.leftMouseDown, inWord, clicks: 3)
        post(.leftMouseUp, inWord, clicks: 3)
        await pause(700)
        let whole = pdf.string.trimmingCharacters(in: .whitespacesAndNewlines)
        say("\(verdict(whole.count > word.count && whole.contains(word) && !whole.contains("\n"))) three presses pick its line")

        // The pointer is the text's over the PDF's text, and an arrow over its bare paper.
        let paper = CGPoint(x: first.midX, y: first.minY - 30)
        NSCursor.arrow.set()
        let overText: Bool = moved(place(0, CGPoint(x: body.midX, y: body.midY)), flags: .option) == NSCursor.iBeam
        let overPaper: Bool = moved(place(0, paper), flags: .option) == NSCursor.arrow
        say("\(verdict(overText && overPaper)) with ⌥ held the pointer is the text pointer over the PDF's text, and an arrow over its bare paper")

        // A press on bare paper lets go of what was picked.
        let bare = place(0, paper)
        await front()
        post(.leftMouseDown, bare, flags: [])
        post(.leftMouseUp, bare, flags: [])
        await pause(700)
        say("\(verdict(pdf.isEmpty && pdf.string.isEmpty)) a press on bare paper lets go of it")

        // Beside the text's column, at the page's edge, the PDF's text is picked as well.
        let column = session.note.map { TextColumn($0.document) }
        var edge: (page: Int, rect: CGRect)?
        for page in 0..<min(layout.pageCount, 15) where edge == nil {
            if let found = pdf.lines(page: page).first(where: { $0.minX + 6 < (column?.left ?? 0) || $0.maxX - 6 > (column?.left ?? 0) + (column?.width ?? 1e9) }) { edge = (page, found) }
        }
        if let edge, edge.page == 0 {
            let outside = edge.rect.minX + 6 < (column?.left ?? 0) ? CGPoint(x: edge.rect.minX + 3, y: edge.rect.midY) : CGPoint(x: edge.rect.maxX - 3, y: edge.rect.midY)
            let at = place(0, outside)
            await front()
            post(.leftMouseDown, at, clicks: 2)
            post(.leftMouseUp, at, clicks: 2)
            await pause(700)
            say("\(verdict(!pdf.isEmpty)) two presses on a word at the page's edge, beside the text's column, pick it too")
            NSCursor.arrow.set()
            let edgePointer: Bool = find(PDFTextCatcher.CatcherView.self, in: window.contentView).first.map { over($0, at) == NSCursor.iBeam } ?? false
            say("\(verdict(edgePointer)) and the pointer is the text pointer over it")
            pdf.clear()
        } else {
            say("     (no text of this PDF's first page lies beside the text's column: picking there was not tried)")
        }

        // Dragged from one page onto the next: the text of both, to where the pointer is.
        let second = pdf.lines(page: 1)
        if let onNext = second.dropFirst(2).first ?? second.first {
            let start = place(0, CGPoint(x: body.minX + 2, y: body.midY)), end = place(1, CGPoint(x: onNext.midX, y: onNext.midY))
            await front()
            post(.leftMouseDown, start)
            for step in 1...8 { post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * Double(step) / 8, y: start.y + (end.y - start.y) * Double(step) / 8)) }
            post(.leftMouseUp, end)
            await pause(1200)
            let pages: [Int] = pdf.marks.map(\.page)
            // The next page lies below the window: the pages scroll as the pointer is held there, and the picking goes on with them.
            let across: Bool = pages.count >= 2 && pages.first == 0 && pages == Array(0..<pages.count) && pdf.string.count > whole.count
            say("\(verdict(across)) dragging down past the page picks on, page after page (\(pdf.string.count) characters on pages \(pages.map { $0 + 1 }))")
            await shot("p5-pdf-text-across-pages")
        } else {
            say("FAIL: the second page has no text")
        }
        // The pens out, what was picked is let go.
        EditorRemote.shared.drawing = true
        await pause(800)
        say("\(verdict(pdf.isEmpty)) taking up the pen lets go of what was picked")
    }

    static func testPicture() -> Data? {
        let size = 360
        guard let context = CGContext(data: nil, width: size, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.16, green: 0.45, blue: 0.95, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: 240))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1)); context.fillEllipse(in: CGRect(x: 110, y: 50, width: 140, height: 140))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func run(model: AppModel, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            @MainActor func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
            @MainActor func shot(_ name: String, wait: Int = 900) async {
                await pause(wait)
                if let window = window(), let data = capture(window) { try? data.write(to: folder.appendingPathComponent(name + ".png")) } else { say("no picture for \(name)") }
            }
            /// An event of its own through the app's queue: undo steps are grouped by event, so
            /// steps made here by direct calls need one between them to be steps apart.
            @MainActor func tick() async {
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(event, atStart: false)
                }
                await pause(150)
            }
            /// The view's text as a copy: `string` itself can stay tied to the live text.
            @MainActor func copy(_ view: NSTextView) -> String { String(decoding: Array(view.string.utf16), as: UTF16.self) }
            await pause(2000)
            NSApplication.shared.activate(ignoringOtherApps: true)
            for _ in 0..<12 where window() == nil { await pause(400) }
            window()?.setContentSize(NSSize(width: 1180, height: 820))
            model.appearance = Launch.flag("--dark") ? .dark : .light

            if Launch.flag("--sync-only") {
                await syncChecks(model: model, shot: shot)
                finish(folder)
                return
            }
            if Launch.flag("--readme-only") {
                await readmeShots(model: model, shot: { name in await shot(name, wait: 600) })
                finish(folder)
                return
            }
            if Launch.flag("--pointer-only") {
                await pointerChecks(model: model, shot: { name in await shot(name, wait: 300) })
                finish(folder)
                return
            }
            if Launch.flag("--pad-only") {
                await padChecks(model: model, shot: { name in await shot(name, wait: 300) })
                finish(folder)
                return
            }
            if Launch.flag("--boxes-only") {
                await boxChecks(model: model, shot: { name in await shot(name, wait: 700) })
                finish(folder)
                return
            }
            if Launch.flag("--undo-only") {
                await undoChecks(model: model)
                finish(folder)
                return
            }
            if Launch.flag("--ai-only") {
                // Only calculations and writing with the Mac's own language model.
                await aiChecks(model: model, shot: { name in await shot(name, wait: 700) })
                finish(folder)
                return
            }
            if Launch.flag("--tools-only") {
                // Only the tools down the side and their options.
                await toolChecks(model: model, shot: { name in await shot(name, wait: 700) })
                finish(folder)
                return
            }
            if Launch.flag("--menu-only") {
                // Only the checks of the picture menu, the pages at the side, finding and note styles.
                await menuChecks(model: model, shot: shot)
                finish(folder)
                return
            }
            if let given = Launch.value("--import-pdf") {
                // "Import PDF" with a document given: the list with the new note, then the note itself.
                func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
                let before = Set(model.library.notes.keys)
                NoteFiles.importFiles([URL(fileURLWithPath: given)], in: model)
                for _ in 0..<40 { await pause(250); if Set(model.library.notes.keys) != before { break } }
                await pause(1500)
                let made = Set(model.library.notes.keys).subtracting(before).first ?? ""
                let note = try? model.store.load(made)
                let shown = note.map { NoteLayout.shownPageCount(of: $0.document) } ?? 0
                say("\(verdict(note != nil && shown > 0 && note?.document.pages.prefix(shown).allSatisfy { $0.pdf != nil } == true)) the PDF is a note of \(shown) pages (\(note?.document.pages.count ?? 0) with the spare one), each \(Int(note?.document.pages.first?.width ?? 0)) by \(Int(note?.document.pages.first?.height ?? 0))")
                say("\(verdict(model.path.last == made)) and it is opened")
                await shot("p2-pdf-note", wait: 2500)
                model.path = []
                await shot("p1-list-with-import", wait: 1500)
                model.open(made)
                await pause(2500)
                EditorRemote.shared.page = min(2, max(shown - 1, 0))
                await shot("p3-pdf-third-page", wait: 2500)
                EditorRemote.shared.page = 0
                await pause(1500)
                await pdfTextChecks(model: model, note: made, shot: { name in await shot(name, wait: 700) }, tick: tick)
                finish(folder)
                return
            }
            if Launch.flag("--open-only") {
                // Opens each note of the library given, as it is, and says where its pictures lie.
                for item in model.items(in: .all) {
                    model.path = []
                    await pause(500)
                    model.open(item.id)
                    await pause(2500)
                    guard let session = NoteSession.live.object(forKey: item.id as NSString), let view = find(NoteTextView.self, in: window()?.contentView).first,
                          let text = view.controller, let container = view.textContainer as? PagedTextContainer else { say("FAIL: \(item.id.prefix(8)) did not open"); continue }
                    say("note \(item.id.prefix(8)): pages shown \(session.visiblePages) of \(session.note?.document.pages.count ?? -1); room \(Int(container.room)) of stride \(Int(container.stride)) points; simple container: \(container.isSimpleRectangularTextContainer); view \(Int(view.frame.width)) x \(Int(view.frame.height))")
                    for (id, frame) in text.pictureFrames.sorted(by: { $0.value.minY < $1.value.minY }) {
                        let within = container.stride > 0 ? frame.minY.truncatingRemainder(dividingBy: container.stride) : frame.minY
                        let crosses = container.room > 0 && within + frame.height > container.room + 1
                        say("\(crosses ? "FAIL" : "ok  ") picture \(id.prefix(8)) at \(Int(frame.minY))…\(Int(frame.maxY)), \(Int(within)) into its page, \(Int(frame.height)) high\(crosses ? ": CROSSES the break" : "")")
                    }
                    if let last = text.pictureFrames.values.max(by: { $0.minY < $1.minY }) { view.scrollToVisible(last.insetBy(dx: 0, dy: -200)) }
                    await shot("open-\(item.id.prefix(8))", wait: 1200)
                }
                finish(folder)
                return
            }
            // 1. A new note: typing and formatting.
            model.createNote()
            await pause(1500)
            guard let id = model.path.last, let view = find(NoteTextView.self, in: window()?.contentView).first, let text = view.controller else {
                say("FAIL: no text view for the new note")
                finish(folder)
                return
            }
            view.window?.makeFirstResponder(view)
            view.insertText("Weekend plan\nBuy milk\nCall the plumber\nBook tickets\nNotes: the red part matters, the rest is plain text that runs long enough to wrap onto a second line of the page.", replacementRange: view.selectedRange())
            await pause(200)
            view.setSelectedRange(NSRange(location: 0, length: 12))
            text.toggle(NoteText.bold)
            text.setSize(20)
            view.setSelectedRange(NSRange(location: 13, length: 37))
            text.setMark(.checkbox(checked: false))
            view.setSelectedRange(NSRange(location: 14, length: 0))
            text.setMark(.checkbox(checked: true))          // same kind already: turns the first line's box off...
            text.setMark(.checkbox(checked: false))         // ...and on again
            let notes = (view.string as NSString).range(of: "the red part")
            view.setSelectedRange(notes)
            text.setColor(0xFFFF_3636)
            text.toggle(NoteText.underline)
            let plain = (view.string as NSString).range(of: "plain text")
            view.setSelectedRange(plain)
            text.setHighlight(0xFFFF_F27A)
            text.toggle(NoteText.italic)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            await shot("e1-formatted")
            // Typing continues the style at the caret; Return in a list makes a new list line.
            view.setSelectedRange(NSRange(location: NSMaxRange((view.string as NSString).range(of: "Book tickets")), length: 0))
            view.insertNewline(nil)
            view.insertText("Pack bags", replacementRange: view.selectedRange())
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.insertNewline(nil)
            view.insertText("One", replacementRange: view.selectedRange())
            text.setMark(.number)
            view.insertNewline(nil)
            view.insertText("Two", replacementRange: view.selectedRange())
            view.insertNewline(nil)
            view.insertText("Inner", replacementRange: view.selectedRange())
            await tick()
            view.doCommand(by: #selector(NSResponder.insertTab(_:)))
            await tick()
            await shot("e2-lists", wait: 1800)

            if let stored = model.edits.richText(id) {
                let stream = Data(base64Encoded: stored.body.encoded().text).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                @MainActor func has(_ what: String, _ part: String) { say("\(stream.contains(part) ? "ok  " : "FAIL") stored text has \(what)") }
                has("bold", "'span/bold'='3,True'")
                has("size 20", "'span/fontSize'='3,20'")
                has("a red run", "'span/foregroundColor'='3,-51658'")
                has("underline", "'span/underline'='3,True'")
                has("italic", "'span/italic'='3,True'")
                has("highlight", "'span/backgroundColor'='3,-3462'")
                has("an open checkbox", "'paragraph/bullet'='2,False'")
                has("numbered lines", "'paragraph/bullet'='4,2'")
                has("an indented line", "'paragraph/indentLevel'='1,1'")
                say("\(stored.body.string == view.string ? "ok  " : "FAIL") stored text equals the text on screen (\(stored.body.length) units)")
                say("     span list: \(stored.body.encoded().spanList.joined(separator: " | "))")
                say("     paragraphs: \(stored.body.paragraphs.map { $0.map { "\($0.key.replacingOccurrences(of: "paragraph/", with: ""))=\($0.value)" }.joined(separator: ",") }.joined(separator: " | "))")
            } else {
                say("FAIL: the note's text was not stored")
            }

            // 2. Undo takes formatting and typing back in order; redo brings it again.
            let before = copy(view), styled = text.text
            let manager = view.window?.undoManager
            // One more formatting step in an event of its own, then back and forth.
            await tick()
            view.setSelectedRange(NSRange(location: 0, length: 7))
            text.toggle(NoteText.strikethrough)
            await tick()
            say("\(text.text != styled ? "ok  " : "FAIL") a formatting step changed the stored text")
            manager?.undo()
            await tick()
            say("\(text.text == styled && copy(view) == before ? "ok  " : "FAIL") undo took the formatting back exactly (next: “\(manager?.undoActionName ?? "")”)")
            manager?.redo()
            await tick()
            say("\(text.text != styled && NoteText.isOn(text.text.property(NoteText.strikethrough, at: 3)) ? "ok  " : "FAIL") redo brought it again")
            manager?.undo()
            await tick()
            manager?.undo()
            await tick()
            say("\(text.text != styled && text.text.indentLevel(text.text.paragraphStarts.count - 1) == 0 && text.text.string == copy(view) ? "ok  " : "FAIL") a second undo went one step further back (“\(manager?.redoActionName ?? "")”), model in step: \(text.text.string == copy(view))")
            manager?.redo()
            await tick()
            say("\(copy(view) == before && text.text == styled ? "ok  " : "FAIL") redo restored text and formatting; model in step: \(text.text.string == copy(view))")
            // An emoji replaced by another keeps both halves.
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.insertText(" \u{1F600}", replacementRange: view.selectedRange())
            view.insertText("\u{1F601}", replacementRange: NSRange(location: (view.string as NSString).length - 2, length: 2))
            say("\(text.text.string.hasSuffix(" \u{1F601}") && text.text.string == view.string ? "ok  " : "FAIL") an emoji typed over another is stored whole")
            view.insertText("", replacementRange: NSRange(location: (view.string as NSString).length - 3, length: 3))
            await pause(1500)

            // 3. A picture pasted into the text.
            if let png = testPicture() {
                let board = NSPasteboard(name: NSPasteboard.Name("snotes-editor-check"))
                board.clearContents()
                board.setData(png, forType: .png)
                view.setSelectedRange(NSRange(location: 12, length: 0))
                let took = text.onPastePicture?(board, 12) ?? false
                say("\(took ? "ok  " : "FAIL") pasted picture accepted")
                board.releaseGlobally()
            }
            await shot("e3-picture", wait: 2500)
            if let note = try? model.store.load(id) {
                say("\(note.document.floating.count == 1 ? "ok  " : "FAIL") one picture object stored; in text: \(note.document.floating.first?.inText == true); files: \(note.document.files.count); pages: \(note.document.pages.count)")
                say("\(model.edits.richText(id)?.body.objectIDs.count == 1 ? "ok  " : "FAIL") the text holds the picture's place; on screen: \(text.text.objectIDs.count)")
            }

            // 4. Drawing: three pens, a shape, the eraser.
            EditorRemote.shared.drawing = true
            await pause(900)
            @MainActor func canvases() -> [InkCanvasView] { find(InkCanvasView.self, in: window()?.contentView).sorted { $0.convert(CGPoint.zero, to: nil).y > $1.convert(CGPoint.zero, to: nil).y } }
            func wave(_ y: Double, _ amplitude: Double = 18) -> [CGPoint] {
                var out: [CGPoint] = []
                for step in 0..<70 {
                    let x: Double = 60 + Double(step) * 6
                    let dy: Double = sin(Double(step) / 5) * amplitude
                    out.append(CGPoint(x: x, y: y + dy))
                }
                return out
            }
            guard let canvas = canvases().first else {
                say("FAIL: no drawing canvas")
                finish(folder)
                return
            }
            // Below the text, inside what the window shows of the page.
            let base = Double(canvas.visibleRect.minY) + 500
            drag(canvas, wave(base))
            await pause(500)
            var choice = PenChoice()
            choice.kind = .highlighter
            EditorRemote.shared.pen = choice
            await pause(300)
            if let canvas = canvases().first { drag(canvas, wave(base + 40, 4)) }
            await pause(500)
            choice.kind = .brush
            choice.setting = PenChoice.Setting(argb: 0xFF14_47FF, level: 60)
            EditorRemote.shared.pen = choice
            await pause(300)
            if let canvas = canvases().first { drag(canvas, wave(base + 85)) }
            await pause(500)
            choice.kind = .calligraphy
            choice.setting = PenChoice.Setting(argb: 0xFF8E_44D6, level: 70)
            EditorRemote.shared.pen = choice
            await pause(300)
            var curl: [CGPoint] = []
            for step in 0..<40 {
                let t = Double(step)
                let x: Double = 80 + 60 * cos(t / 6.2) + t * 5
                let y: Double = base + 150 + 22 * sin(t / 3.1)
                curl.append(CGPoint(x: x, y: y))
            }
            if let canvas = canvases().first { drag(canvas, curl) }
            await pause(400)
            choice.kind = .fountain
            choice.shape = ShapeKind.rectangle.rawValue
            EditorRemote.shared.pen = choice
            EditorRemote.shared.tool = .shape
            await pause(300)
            if let canvas = canvases().first { drag(canvas, [CGPoint(x: 400, y: base + 115), CGPoint(x: 450, y: base + 140), CGPoint(x: 540, y: base + 175)]) }
            await pause(300)
            choice.shape = ShapeKind.arrow.rawValue
            EditorRemote.shared.pen = choice
            await pause(300)
            if let canvas = canvases().first { drag(canvas, [CGPoint(x: 430, y: base - 45), CGPoint(x: 480, y: base - 30), CGPoint(x: 560, y: base + 5)]) }
            await shot("e4-drawing", wait: 1800)
            let drawn = (try? model.store.load(id))?.strokes ?? [:]
            say("\(drawn.count == 7 ? "ok  " : "FAIL") strokes stored: \(drawn.count) (wave, highlighter, brush, calligraphy, rectangle, arrow shaft and head)")
            say("     pens: \(Set(drawn.values.map { $0.penName?.split(separator: ".").last.map(String.init) ?? "?" }).sorted().joined(separator: ", "))")
            say("     highlighter colour: \(drawn.values.first { $0.pen.kind == .highlighter }.map { String($0.argb, radix: 16) } ?? "none")")

            // 5. Select with a loop, move, resize, then delete; erase one stroke; undo it.
            EditorRemote.shared.tool = .select
            await pause(400)
            if let canvas = canvases().first {
                let loop = [CGPoint(x: 40, y: base - 28), CGPoint(x: 425, y: base - 28), CGPoint(x: 425, y: base + 26), CGPoint(x: 40, y: base + 26), CGPoint(x: 40, y: base - 20)]
                var path: [CGPoint] = []
                for index in 0..<(loop.count - 1) { path.append(contentsOf: ShapePoints.line(loop[index], loop[index + 1], step: 12)) }
                drag(canvas, path)
                await shot("e5-selected", wait: 700)
                say("\(canvas.picked != nil ? "ok  " : "FAIL") the loop picked something: \(canvas.picked.map { "\(Int($0.rect.width))x\(Int($0.rect.height))" } ?? "nothing")")
                if let rect = canvas.picked?.rect {
                    drag(canvas, [CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: rect.midX + 40, y: rect.midY - 10), CGPoint(x: rect.midX + 150, y: rect.midY - 30)])
                    await pause(900)
                }
                if let rect = canvases().first?.picked?.rect {
                    let corner = CGPoint(x: rect.maxX + 4, y: rect.maxY + 4)
                    if let again = canvases().first { drag(again, [corner, CGPoint(x: corner.x - 40, y: corner.y - 10), CGPoint(x: corner.x - 120, y: corner.y - 30)]) }
                }
                await shot("e6-moved-resized", wait: 1500)
            }
            let moved = (try? model.store.load(id))?.strokes ?? [:]
            say("\(moved.count == 7 && Set(moved.keys) != Set(drawn.keys) ? "ok  " : "FAIL") moved strokes were stored anew: \(moved.count) strokes, \(Set(moved.keys).subtracting(drawn.keys).count) new ids")
            EditorRemote.shared.tool = .eraser
            await pause(300)
            if let canvas = canvases().first { drag(canvas, [CGPoint(x: 100, y: base + 40), CGPoint(x: 140, y: base + 40)]) }
            await pause(900)
            let erased = (try? model.store.load(id))?.strokes.count ?? -1
            say("\(erased == 6 ? "ok  " : "FAIL") the eraser took the highlighter stroke: \(erased) left")
            say("     undo: level \(window()?.undoManager?.groupingLevel ?? -1), next is “\(window()?.undoManager?.undoActionName ?? "")”")
            window()?.undoManager?.undo()
            await pause(900)
            let back = (try? model.store.load(id))?.strokes.count ?? -1
            say("\(back == 7 ? "ok  " : "FAIL") undo brought it back: \(back)")
            await shot("e7-after-undo", wait: 900)

            // 6. Back to typing; the title; then close and reopen: everything is as it was left.
            EditorRemote.shared.drawing = false
            await pause(500)
            if let field = find(NSTextField.self, in: window()?.contentView).first(where: { $0.isEditable }) ?? nil { _ = field }
            model.path = []
            await pause(1200)
            let record = model.library.notes[id]
            say("\(record?.hasInk == true && record?.hasText == true ? "ok  " : "FAIL") library record: ink \(record?.hasInk == true), text \(record?.hasText == true), picture \(record?.coverFile != nil), waiting \(String(describing: record?.pending))")
            if let file = try? Data(contentsOf: model.store.directory(id).appendingPathComponent("note.xml")), let tree = try? XMLTree.parse(file) {
                let note = tree.name == "NoteResource" ? tree : (tree.descendant("NoteResource") ?? tree)
                say("\(note.child("noteTree").map(NoteHash.verify) == true ? "ok  " : "FAIL") every hash in the note's tree holds")
            }
            model.open(id)
            await shot("e8-reopened", wait: 2200)
            if let again = find(NoteTextView.self, in: window()?.contentView).first {
                say("\(again.string.contains("\u{FFFC}") && again.string.contains("Weekend plan") ? "ok  " : "FAIL") reopened text has the picture's place and \((again.string as NSString).length) units")
            }
            if Launch.flag("--dark") { await shot("e9-dark") }
            await pageChecks(model: model, shot: shot)
            await pictureChecks(model: model, shot: shot)
            await clickChecks(model: model, shot: shot)
            await breakChecks(model: model, shot: shot)
            await menuChecks(model: model, shot: shot)
            finish(folder)
        }
    }

    /// The spare page every note ends with: kept in the file, not shown while it is empty.
    @MainActor private static func pageChecks(model: AppModel, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        model.path = []
        await pause(600)
        model.createNote()
        await pause(1500)
        guard let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString),
              let view = find(NoteTextView.self, in: window()?.contentView).first, let text = view.controller else {
            say("FAIL: no session for the page checks")
            return
        }
        func filePages() -> Int { (try? model.store.load(id))?.document.pages.count ?? -1 }
        say("\(session.visiblePages == 1 && filePages() == 2 ? "ok  " : "FAIL") a new note shows 1 page and the file keeps \(filePages()) (visible \(session.visiblePages), hidden \(session.hiddenPages))")
        view.window?.makeFirstResponder(view)
        view.insertText("one short line", replacementRange: view.selectedRange())
        await pause(300)
        say("\(session.visiblePages == 1 ? "ok  " : "FAIL") a line of text keeps it at \(session.visiblePages) page")
        // Enough lines to run onto the second page, shown while typing, before anything is saved.
        let lines = (0..<90).map { "line \($0)" }.joined(separator: "\n")
        view.insertText("\n" + lines, replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
        await pause(250)
        say("\(session.visiblePages == 2 ? "ok  " : "FAIL") text that runs past the first page shows the second at once (\(session.visiblePages) shown)")
        await shot("e10-text-two-pages", 1800)
        say("\(text.text.length > 400 && filePages() >= 2 ? "ok  " : "FAIL") and the file has \(filePages()) pages")
        // Taking the text away again hides the empty page again.
        view.setSelectedRange(NSRange(location: 14, length: 0))
        view.insertText("", replacementRange: NSRange(location: 14, length: (view.string as NSString).length - 14))
        await pause(300)
        say("\(session.visiblePages == 1 ? "ok  " : "FAIL") with the text gone the empty page is hidden again (\(session.visiblePages) shown)")
        // Add Page shows the empty pages the note already has, one by one; only when none is
        // left is a page added.
        let before = filePages()
        var steps = 0
        while session.hiddenPages > 0, steps < 8 {
            let shown = session.visiblePages
            session.addPage(after: shown - 1)
            await pause(400)
            steps += 1
            if session.visiblePages != shown + 1 || filePages() != before { break }
        }
        say("\(session.hiddenPages == 0 && filePages() == before && steps == before - 1 ? "ok  " : "FAIL") Add Page showed the \(steps) empty pages the note kept, adding none (\(session.visiblePages) shown, file \(before) -> \(filePages()))")
        session.addPage(after: session.visiblePages - 1)
        await pause(1500)
        say("\(session.visiblePages == before + 1 && filePages() == before + 1 ? "ok  " : "FAIL") with none left, Add Page adds one (\(session.visiblePages) shown, file \(filePages()))")
        // A stroke on the last page keeps it, and a reopened note shows what holds something.
        EditorRemote.shared.drawing = true
        await pause(700)
        say("\(session.hiddenPages == 0 ? "ok  " : "FAIL") nothing is hidden while every page is shown")
        EditorRemote.shared.drawing = false
        model.path = []
        await pause(800)
        model.open(id)
        await pause(1500)
        let reopened = NoteSession.live.object(forKey: id as NSString)
        say("\(reopened?.visiblePages == 1 ? "ok  " : "FAIL") reopened, the empty pages are left off again (\(reopened?.visiblePages ?? -1) shown of \(filePages()))")
    }

    /// A picture in a note that has just been opened, clicked and dragged with the pointer itself:
    /// events through the app's queue, at the place on screen where the picture is.
    @MainActor private static func clickChecks(model: AppModel, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        model.path = []
        await pause(600)
        model.createNote()
        await pause(1500)
        guard let id = model.path.last, let first = find(NoteTextView.self, in: window()?.contentView).first, let png = testPicture() else {
            say("FAIL: no note for the click checks")
            return
        }
        first.window?.makeFirstResponder(first)
        first.insertText("first paragraph\nsecond paragraph\nthird paragraph", replacementRange: first.selectedRange())
        await pause(300)
        let board = NSPasteboard(name: NSPasteboard.Name("snotes-editor-check-4"))
        board.clearContents()
        board.setData(png, forType: .png)
        _ = first.controller?.onPastePicture?(board, (first.string as NSString).length)
        board.releaseGlobally()
        await pause(2200)
        // Closed and opened again: nothing has been typed in this view.
        model.path = []
        await pause(900)
        model.open(id)
        await pause(1800)
        guard let session = NoteSession.live.object(forKey: id as NSString), let view = find(NoteTextView.self, in: window()?.contentView).first,
              let text = view.controller, let window = view.window, let object = session.note?.document.floating.first?.id else {
            say("FAIL: the note did not open again for the click checks")
            return
        }
        guard let frame = text.pictureFrames[object] else {
            say("FAIL a note just opened knows where its picture is (\(text.pictureFrames.count) places known)")
            return
        }
        say("ok   a note just opened knows where its picture is (\(Int(frame.width)) x \(Int(frame.height)) points)")
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        say("\(session.pictureSelection == nil ? "ok  " : "FAIL") nothing is picked before the click")
        if let down = event(.leftMouseDown, centre) { NSApp.postEvent(down, atStart: false) }
        if let up = event(.leftMouseUp, centre) { NSApp.postEvent(up, atStart: false) }
        await pause(700)
        say("\(session.pictureSelection == object ? "ok  " : "FAIL") a click on the picture picks it")
        await shot("e14-clicked", 600)
        // A handle dragged inwards with the pointer: the picture gets smaller.
        let wide = session.note?.document.floating.first { $0.id == object }?.rect.width ?? 0
        let corner = CGPoint(x: frame.maxX, y: frame.maxY)
        if let down = event(.leftMouseDown, corner) { NSApp.postEvent(down, atStart: false) }
        for step in 1...8 {
            if let move = event(.leftMouseDragged, CGPoint(x: corner.x - 12 * CGFloat(step), y: corner.y - 8 * CGFloat(step))) { NSApp.postEvent(move, atStart: false) }
        }
        if let up = event(.leftMouseUp, CGPoint(x: corner.x - 96, y: corner.y - 64)) { NSApp.postEvent(up, atStart: false) }
        await pause(1500)
        let narrow = session.note?.document.floating.first { $0.id == object }?.rect.width ?? 0
        let ratio = session.note?.document.floating.first { $0.id == object }.map { $0.rect.width / max($0.rect.height, 1) } ?? 0
        say("\(narrow < wide - 40 && abs(ratio - 1.5) < 0.05 ? "ok  " : "FAIL") dragging the corner handle made it smaller and kept its shape (\(Int(wide)) -> \(Int(narrow)) units, \(String(format: "%.2f", ratio)) wide for its height)")
        guard let level = text.pictureFrames[object] else { say("FAIL: the resized picture has no place"); return }
        // The handle above the picture, dragged a quarter of the way round to its right side.
        func turn() -> Double { session.note?.document.floating.first { $0.id == object }?.rotation ?? -1 }
        let hub = CGPoint(x: level.midX, y: level.midY)
        let arm = level.height / 2 + PictureGripView.turnReach
        await tick()
        if let down = event(.leftMouseDown, CGPoint(x: hub.x, y: hub.y - arm)) { NSApp.postEvent(down, atStart: false) }
        for step in 1...9 {
            let angle = Double(step) * 10 * .pi / 180
            if let move = event(.leftMouseDragged, CGPoint(x: hub.x + arm * sin(angle), y: hub.y - arm * cos(angle))) { NSApp.postEvent(move, atStart: false) }
        }
        await pause(300)
        await shot("e17-turning", 300)
        if let up = event(.leftMouseUp, CGPoint(x: hub.x + arm - 2, y: hub.y + 3)) { NSApp.postEvent(up, atStart: false) }
        await pause(1500)
        let stored = (try? model.store.load(id))?.document.floating.first { $0.id == object }?.rotation ?? -1
        say("\(turn() == 90 && stored == 90 ? "ok  " : "FAIL") dragging the handle above the picture round to its side turned it a quarter turn (\(turn()) on screen, \(stored) stored)")
        let upright = text.pictureFrames[object] ?? .zero
        say("\(abs(upright.width - level.height) < 3 && abs(upright.height - level.width) < 3 ? "ok  " : "FAIL") and the text made room for it standing on end (\(Int(level.width)) x \(Int(level.height)) -> \(Int(upright.width)) x \(Int(upright.height)) points)")
        await shot("e18-turned", 600)
        await tick()
        model.undoManagerForChecks?.undo()
        await pause(1500)
        await tick()
        say("\(turn() == 0 ? "ok  " : "FAIL") undo turned it back (\(turn()))")
        guard let small = text.pictureFrames[object] else { say("FAIL: the picture has no place after turning back"); return }
        let middle = CGPoint(x: small.midX, y: small.midY)
        // Pressed and dragged up to the top of the text in one go.
        let before = text.text.string
        if let down = event(.leftMouseDown, middle) { NSApp.postEvent(down, atStart: false) }
        let lift = small.minY + 4
        for step in 1...12 {
            let point = CGPoint(x: middle.x, y: middle.y - lift * CGFloat(step) / 12)
            if let move = event(.leftMouseDragged, point) { NSApp.postEvent(move, atStart: false) }
        }
        await pause(400)
        await shot("e15-dragging", 300)
        if let up = event(.leftMouseUp, CGPoint(x: middle.x, y: middle.y - lift)) { NSApp.postEvent(up, atStart: false) }
        await pause(900)
        let after = text.text.string
        say("\(after.hasPrefix("\u{FFFC}") && before.hasSuffix("\u{FFFC}") ? "ok  " : "FAIL") dragging it to the top moved it there: \(after.replacingOccurrences(of: "\u{FFFC}", with: "[picture]").replacingOccurrences(of: "\n", with: " | "))")
        // A click in the text lets go of it.
        if let last = text.pictureFrames[object] {
            let below = CGPoint(x: last.midX, y: last.maxY + 40)
            // Given to the text view itself: a text view lets the first click on a window that
            // is not the active one pass, and this window, run by a script, may not be.
            if let down = event(.leftMouseDown, below), let up = event(.leftMouseUp, below) {
                NSApp.postEvent(up, atStart: false)
                view.mouseDown(with: down)
            }
            await pause(600)
            say("\(session.pictureSelection == nil && text.pickedObject == nil ? "ok  " : "FAIL") a press in the text lets go of the picture")
        }
    }

    /// A picture that does not fit in what is left of a page goes to the next page whole, in the
    /// editor as in what is stored.
    @MainActor private static func breakChecks(model: AppModel, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        model.path = []
        await pause(600)
        model.createNote()
        await pause(1500)
        guard let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString),
              let view = find(NoteTextView.self, in: window()?.contentView).first, let text = view.controller, let png = testPicture() else {
            say("FAIL: no note for the page break checks")
            return
        }
        view.window?.makeFirstResponder(view)
        view.insertText((0..<20).map { "line \($0)" }.joined(separator: "\n"), replacementRange: view.selectedRange())
        await pause(400)
        for number in 0..<2 {
            let board = NSPasteboard(name: NSPasteboard.Name("snotes-editor-check-5-\(number)"))
            board.clearContents()
            board.setData(png, forType: .png)
            _ = text.onPastePicture?(board, (view.string as NSString).length)
            board.releaseGlobally()
            await pause(2200)
        }
        let pictures = (try? model.store.load(id))?.document.floating.filter(\.inText) ?? []
        guard pictures.count == 2, let container = view.textContainer as? PagedTextContainer, container.stride > container.room, container.room > 10 else {
            say("FAIL: two pictures and a paged column were expected (\(pictures.count) pictures)")
            return
        }
        // In the editor: neither picture lies across a break.
        var whole = true
        var places: [String] = []
        for picture in pictures {
            guard let frame = text.pictureFrames[picture.id] else { whole = false; continue }
            let within = frame.minY.truncatingRemainder(dividingBy: container.stride)
            if within + frame.height > container.room + 1 { whole = false }
            places.append("page \(Int(frame.minY / container.stride) + 1) at \(Int(within)) of \(Int(container.room))")
        }
        say("\(whole ? "ok  " : "FAIL") in the editor each picture lies on one page: \(places.joined(separator: "; "))")
        let second = pictures.max { (text.pictureFrames[$0.id]?.minY ?? 0) < (text.pictureFrames[$1.id]?.minY ?? 0) }
        say("\((text.pictureFrames[second?.id ?? ""]?.minY ?? 0) >= container.stride - 1 ? "ok  " : "FAIL") the second picture, which had no room left, starts the second page")
        // As stored: the same.
        let column = (try? model.store.load(id)).map { TextColumn($0.document) }
        let stored = pictures.allSatisfy { $0.rect.minY >= (column?.top ?? 0) - 1 && $0.rect.maxY <= (column?.pageHeight ?? 0) - (column?.bottom ?? 0) + 1 }
        say("\(stored && pictures.contains { $0.pageIndex == 1 } ? "ok  " : "FAIL") and as stored: pages \(pictures.map { "\(($0.pageIndex ?? 0) + 1)" }.joined(separator: ", ")), each within its page")
        say("\(session.visiblePages == 2 ? "ok  " : "FAIL") both pages are shown (\(session.visiblePages))")
        if let frame = text.pictureFrames[second?.id ?? ""] { view.scrollToVisible(frame.insetBy(dx: 0, dy: -260)) }
        await shot("e16-page-break", 1200)
    }

    /// An event of its own through the app's queue: undo steps are grouped by event, so steps
    /// made here by direct calls need one between them to be steps apart, as separate clicks are.
    @MainActor static func tick() async {
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// Pictures: picked at once, resized, moved between paragraphs and across the column,
    /// removed with the key, and moved freely on a page.
    @MainActor private static func pictureChecks(model: AppModel, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        model.path = []
        await pause(600)
        model.createNote()
        await pause(1500)
        guard let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString),
              let view = find(NoteTextView.self, in: window()?.contentView).first, let text = view.controller, let png = testPicture() else {
            say("FAIL: no session for the picture checks")
            return
        }
        view.window?.makeFirstResponder(view)
        view.insertText("first paragraph\nsecond paragraph\nthird paragraph", replacementRange: view.selectedRange())
        await pause(300)
        let board = NSPasteboard(name: NSPasteboard.Name("snotes-editor-check-2"))
        board.clearContents()
        board.setData(png, forType: .png)
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        _ = text.onPastePicture?(board, end)
        board.releaseGlobally()
        await pause(2200)
        func floating() -> [NoteObject] { (try? model.store.load(id))?.document.floating ?? [] }
        guard let picture = floating().first, text.pictureFrames[picture.id] != nil else {
            say("FAIL: the pasted picture has no frame (\(floating().count) objects, \(text.pictureFrames.count) frames)")
            return
        }
        let object = picture.id
        let first = text.pictureFrames[object] ?? .zero
        say("ok   the picture is in the text with a frame of \(Int(first.width)) x \(Int(first.height)) points")

        // Pressed: picked, the keyboard is the text's.
        session.pointAtPicture(object)
        say("\(session.pictureSelection == object && text.pickedObject == object ? "ok  " : "FAIL") pressing the picture picks it")
        await shot("e11-picture-picked", 1200)

        // Resized from a handle: half the size, in the page's units; the text flows round it.
        let units = floating().first { $0.id == object }?.rect.size ?? .zero
        await tick()
        session.resizePicture(object, to: CGSize(width: units.width / 2, height: units.height / 2))
        await pause(1500)
        await tick()
        let after = floating().first { $0.id == object }?.rect.size ?? .zero
        let framed = text.pictureFrames[object] ?? .zero
        say("\(abs(after.width - units.width / 2) < 1 && abs(after.height - units.height / 2) < 1 ? "ok  " : "FAIL") resizing stored half the size (\(Int(units.width)) -> \(Int(after.width)) units)")
        say("\(abs(framed.height - first.height / 2) < 3 ? "ok  " : "FAIL") and the picture in the text followed at once (\(Int(first.height)) -> \(Int(framed.height)) points)")
        model.undoManagerForChecks?.undo()
        await pause(1200)
        await tick()
        let undone = floating().first { $0.id == object }?.rect.size ?? .zero
        say("\(abs(undone.width - units.width) < 1 ? "ok  " : "FAIL") undo gave the size back (\(Int(undone.width)) units)")

        // Moved: to the top, then to the bottom, and across the column.
        let column = view.textContainer?.size.width ?? 600
        func place() -> (String, Int) {
            let string = text.text.string
            let at = string.utf16.firstIndex(of: 0xFFFC).map { string.utf16.distance(from: string.utf16.startIndex, to: $0) } ?? -1
            let paragraph = text.text.paragraphs(touching: max(at, 0)..<(max(at, 0) + 1)).lowerBound
            return (string.replacingOccurrences(of: "\u{FFFC}", with: "[picture]"), text.text.alignment(paragraph))
        }
        var frame = text.pictureFrames[object] ?? first
        text.moveObject(object, droppedFrame: CGRect(x: column * 0.5 - frame.width / 2, y: 0, width: frame.width, height: frame.height))
        await pause(500)
        var now = place()
        say("\(now.0.hasPrefix("[picture]\nfirst") && now.1 == 2 ? "ok  " : "FAIL") moved to the top, in the middle: \(now.0.replacingOccurrences(of: "\n", with: " | ")), alignment \(now.1)")
        frame = text.pictureFrames[object] ?? frame
        text.moveObject(object, droppedFrame: CGRect(x: column * 0.92 - frame.width / 2, y: 9000, width: frame.width, height: frame.height))
        await pause(500)
        now = place()
        say("\(now.0.hasSuffix("third paragraph\n[picture]") && now.1 == 1 ? "ok  " : "FAIL") moved to the bottom, on the right: \(now.0.replacingOccurrences(of: "\n", with: " | ")), alignment \(now.1)")
        frame = text.pictureFrames[object] ?? frame
        let secondTop = (view.layoutManager?.boundingRect(forGlyphRange: NSRange(location: 0, length: 15), in: view.textContainer!).maxY ?? 30) + 2
        text.moveObject(object, droppedFrame: CGRect(x: column * 0.1, y: secondTop, width: frame.width, height: frame.height))
        await pause(500)
        now = place()
        say("\(now.0.contains("first paragraph\n[picture]\nsecond") && now.1 == 0 ? "ok  " : "FAIL") moved between the first and second paragraph, on the left: \(now.0.replacingOccurrences(of: "\n", with: " | ")), alignment \(now.1)")
        let stored = (try? model.edits.richText(id))?.body.string ?? ""
        await pause(1200)
        let saved = (model.edits.richText(id)?.body.string ?? "")
        say("\(saved.contains("\u{FFFC}") && saved.hasPrefix("first paragraph") ? "ok  " : "FAIL") and the move was saved (\(stored.count) -> \(saved.count) characters)")
        let spots = floating().filter { $0.inText }
        say("\(spots.count == 1 ? "ok  " : "FAIL") still one picture in the note (\(spots.count))")

        // Delete takes the picked picture, not a letter.
        session.pointAtPicture(object)
        let letters = (view.string as NSString).length
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        await pause(1800)
        say("\(floating().isEmpty && !text.text.string.contains("\u{FFFC}") && text.text.string.hasPrefix("first paragraph") ? "ok  " : "FAIL") Delete removed the picture and no letter (\(letters) -> \((view.string as NSString).length) characters, \(floating().count) pictures)")

        // A picture placed on a page: moved to another place on it.
        let board2 = NSPasteboard(name: NSPasteboard.Name("snotes-editor-check-3"))
        board2.clearContents()
        board2.setData(png, forType: .png)
        if let file = PictureFile(pasteboard: board2) {
            session.addPicture(file, onPage: (0, CGRect(x: 100, y: 900, width: 300, height: 200)))
        }
        board2.releaseGlobally()
        await pause(2200)
        guard let free = floating().first(where: { !$0.inText }) else { say("FAIL: no picture placed on the page"); return }
        await tick()
        session.movePicture(free.id, to: CGRect(x: 250, y: 1000, width: 300, height: 200), page: 0)
        await pause(1500)
        let moved = floating().first { $0.id == free.id }
        say("\(abs((moved?.rect.minX ?? 0) - 250) < 1 && abs((moved?.rect.minY ?? 0) - 1000) < 1 && moved?.inText == false ? "ok  " : "FAIL") a free picture moved to 250, 1000 (now \(Int(moved?.rect.minX ?? -1)), \(Int(moved?.rect.minY ?? -1)))")
        session.resizePicture(free.id, to: CGSize(width: 150, height: 100))
        await pause(1200)
        let smaller = floating().first { $0.id == free.id }
        say("\(abs((smaller?.rect.width ?? 0) - 150) < 1 && abs((smaller?.rect.minX ?? 0) - 250) < 1 ? "ok  " : "FAIL") and resized, keeping its corner (\(Int(smaller?.rect.width ?? -1)) wide at \(Int(smaller?.rect.minX ?? -1)))")
        session.pointAtPicture(free.id)
        await shot("e12-free-picture-picked", 1200)
        EditorRemote.shared.showLabels = true
        await shot("e13-labels", 900)
        EditorRemote.shared.showLabels = false
    }

    static func finish(_ folder: URL) {
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        // Should a sheet or a panel left open keep the app from quitting, it ends all the same.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
        NSApplication.shared.terminate(nil)
    }
}
