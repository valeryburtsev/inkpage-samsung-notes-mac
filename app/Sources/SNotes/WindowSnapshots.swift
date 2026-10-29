import AppKit
import Quartz
import SamsungNotesKit
import SwiftUI

/// Development aid: `--window-snapshot=<folder>` shows the real windows, saves a picture of each
/// screen, writes the menu bar's contents to `menus.txt`, and quits. Used with
/// `--store=<library> --demo` to look at real layouts.
///   --dark              in dark mode
///   --snapshot-edits    first makes a favorite, a trashed note and nested folders (changes the library: use a copy)
///   --snapshot-events   also clicks and types with made-up events, to check selection and the keyboard
///   --snapshot-sign-out with the events: signs out at the end, which removes the notes that are in the cloud from the library given with --store (notes never sent stay)
///   --only-events       only that (the rubber band and the click that deselects need the app in front)
///   --sign-in           the signed-out window and the sign-in sheet
@MainActor
enum WindowSnapshots {
    private static func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    private static func mainWindow() -> NSWindow? {
        NSApplication.shared.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
            ?? NSApplication.shared.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.height > 300 && !$0.isSheet && !($0 is NSPanel) && $0.identifier?.rawValue.contains("Settings") != true }
    }

    private static func window(_ part: String) -> NSWindow? {
        NSApplication.shared.windows.first { $0.isVisible && $0.identifier?.rawValue.contains(part) == true }
    }

    static func run(model: AppModel, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            NSApplication.shared.activate(ignoringOtherApps: true)
            for _ in 0..<12 where mainWindow() == nil { try? await Task.sleep(for: .milliseconds(400)) }
            mainWindow()?.setContentSize(NSSize(width: 1180, height: 780))
            @MainActor func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
            @MainActor func shot(_ name: String, wait: Int = 1100, of other: NSWindow? = nil) async {
                await pause(wait)
                if let window = other ?? mainWindow(), let data = capture(window) { try? data.write(to: folder.appendingPathComponent(name + ".png")) } else { say("snapshot: no picture for \(name)") }
            }
            if Launch.flag("--dark") { model.appearance = .dark } else { model.appearance = .light }
            model.section = .all
            model.gridStyle = .grid
            model.sort = .modified
            model.ascending = false
            if Launch.flag("--draw-test") {
                // Draws on a new note with real pointer events, erases one stroke and takes one back.
                model.createNote(handwritten: true)
                try? await Task.sleep(for: .milliseconds(1500))
                @MainActor func canvas(_ view: NSView?) -> InkCanvasView? {
                    guard let view else { return nil }
                    if let found = view as? InkCanvasView { return found }
                    for child in view.subviews { if let found = canvas(child) { return found } }
                    return nil
                }
                @MainActor func drag(_ view: InkCanvasView, _ points: [CGPoint]) {
                    guard let window = view.window else { return }
                    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
                        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    }
                    if let down = event(.leftMouseDown, points[0]) { view.mouseDown(with: down) }
                    for point in points.dropFirst() { if let move = event(.leftMouseDragged, point) { view.mouseDragged(with: move) } }
                    if let up = event(.leftMouseUp, points[points.count - 1]) { view.mouseUp(with: up) }
                }
                if let view = canvas(mainWindow()?.contentView) {
                    var wave: [CGPoint] = []
                    for step in 0..<60 {
                        let x: Double = 80 + Double(step) * 6
                        let y: Double = 120 + sin(Double(step) / 5) * 40
                        wave.append(CGPoint(x: x, y: y))
                    }
                    drag(view, wave)
                    try? await Task.sleep(for: .milliseconds(700))
                    var steps: [CGPoint] = []
                    for step in 0..<40 {
                        let x: Double = 100 + Double(step) * 7
                        let y: Double = 260 + Double(step % 9) * 5
                        steps.append(CGPoint(x: x, y: y))
                    }
                    if let again = canvas(mainWindow()?.contentView) { drag(again, steps) }
                    await shot("10-drawing", wait: 1500)
                    let first = model.items(in: .all).first?.record
                    say("draw-test: strokes after drawing = \(first?.hasInk ?? false), pending = \(String(describing: first?.pending))")
                } else {
                    say("draw-test: no canvas found")
                    await shot("10-drawing-missing")
                }
                model.path = []
                await shot("11-after-drawing", wait: 1500)
                NotePDF.removeScratch()
                exit(0)
            }
            if !Launch.flag("--only-sign-in") {
                if Launch.flag("--snapshot-edits") { arrange(model) }
                await shot("01-all-notes", wait: 2500)
                let items = model.items(in: .all)
                if Launch.flag("--only-events"), let window = mainWindow() {
                    await events(model: model, window: window, shot: { await shot($0, wait: 700) })
                    NotePDF.removeScratch()
                    exit(0)
                }
                if let ink = items.first(where: { $0.record.hasInk }) { model.path = [ink.id]; await shot("02-note-ink", wait: 1800) }
                if let text = items.first(where: { $0.record.hasText && !$0.record.hasInk && $0.record.coverFile == nil }) { model.path = [text.id]; await shot("03-note-text", wait: 1800) }
                if let picture = items.first(where: { $0.record.coverFile != nil }) { model.path = [picture.id]; await shot("04-note-image", wait: 1800) }
                model.path = []
                model.selection = Set(items.prefix(2).map(\.id))
                await shot("05-grid-selection")
                model.gridStyle = .list
                await shot("06-list-selection")
                model.clearSelection()
                await shot("07-list")
                model.gridStyle = .grid
                model.section = .favorites
                await shot("08-favorites")
                model.section = .trash
                await shot("09-trash")
                if let folder = model.folders(in: TreeNode.rootID).first {
                    model.section = .folder(folder.id)
                    model.renamingFolder = folder.id
                    await shot("10-folder")
                    model.renamingFolder = nil
                }
                model.section = .all
                if let first = items.first { model.select(first.id); model.renamingNote = first.id; await shot("11-rename-note"); model.renamingNote = nil; model.clearSelection() }
                model.syncError = SyncProblem(URLError(.notConnectedToInternet))
                await shot("12-sync-error")
                model.syncError = nil
                model.search = "a"
                await shot("13-search")
                model.search = ""

                // The menu bar, as text: titles, shortcuts, what is disabled.
                var menus = "— nothing selected —\n" + menuText()
                model.selection = Set(items.prefix(2).map(\.id))
                await pause(500)
                menus += "\n— two notes selected —\n" + menuText(only: ["File", "Note"])
                model.clearSelection()
                model.section = .trash
                if let trashed = model.items(in: .trash).first { model.select(trashed.id) }
                await pause(500)
                menus += "\n— a note in the Trash selected —\n" + menuText(only: ["File", "Note"])
                model.section = .all
                await pause(500)
                // The menu of a right click on a card, asked of the window as a right click asks it.
                if let window = window("") ?? NSApplication.shared.mainWindow, let content = window.contentView {
                    var found: NSMenu?
                    search: for y in stride(from: content.bounds.height - 140, through: 120, by: -40) {
                        for x in stride(from: CGFloat(260), through: content.bounds.width - 60, by: 60) {
                            let at = content.convert(CGPoint(x: x, y: y), to: nil)
                            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                                  let view = content.hitTest(content.convert(at, from: nil)) else { continue }
                            var holder: NSView? = view
                            while let now = holder {
                                if let menu = now.menu(for: event), menu.items.count > 4 { found = menu; break search }
                                holder = now.superview
                            }
                        }
                    }
                    menus += "\n— right click on a card —\n" + (found?.items.map { $0.isSeparatorItem ? "    ---" : "    \($0.title)\($0.isEnabled ? "" : "  (disabled)")" }.joined(separator: "\n") ?? "    no menu found")
                }
                try? menus.write(to: folder.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)

                // A note in a window of its own.
                if let first = items.first(where: { $0.record.hasInk }) ?? items.first {
                    model.showNoteWindow?(first.id)
                    await pause(1800)
                    if let window = window("note") { await shot("14-note-window", wait: 300, of: window); window.close() } else { say("snapshot: no note window; windows: \(windowList())") }
                }

                // The Settings window, tab by tab.
                for (name, tab) in [("15-settings-account", SettingsTab.account), ("15b-settings-general", .general), ("16-settings-appearance", .appearance), ("17-settings-advanced", .advanced)] {
                    model.settingsTab = tab
                    model.showSettingsWindow?()
                    await pause(1200)
                    if let window = window("Settings") { await shot(name, wait: 300, of: window) } else { say("snapshot: no settings window; windows: \(windowList())") }
                }
                window("Settings")?.close()

                if Launch.flag("--snapshot-events"), let window = mainWindow() { await events(model: model, window: window, shot: { await shot($0, wait: 700) }) }
            }
            if Launch.flag("--sign-in") {
                model.signedIn = false
                model.section = .all
                await shot("18-signed-out")
                model.showSignIn = true
                try? await Task.sleep(for: .seconds(14))
                if let sheet = NSApplication.shared.windows.first(where: { $0.isSheet && $0.isVisible }), let data = capture(sheet) {
                    try? data.write(to: folder.appendingPathComponent("19-sign-in.png"))
                }
            }
            NotePDF.removeScratch()
            exit(0)
        }
    }

    private static func windowList() -> String {
        NSApplication.shared.windows.map { "\($0.identifier?.rawValue ?? "?")|\($0.title)|\($0.isVisible)" }.joined(separator: "; ")
    }

    /// Gives the library a favorite, a trashed note and nested, coloured folders, so that every
    /// part of the sidebar has something to show.
    private static func arrange(_ model: AppModel) {
        let items = model.items(in: .all)
        guard items.count >= 3 else { return }
        model.setFavorite([items[0].id, items[2].id], true)
        if items.count > 4 { model.setTrashed([items[items.count - 1].id], true) }
        if let work = model.createFolder(named: "Projects"), let ideas = model.createFolder(named: "Ideas", in: work) {
            model.setFolderColor(work, FolderColor.palette[5].argb)
            model.setFolderColor(ideas, FolderColor.palette[4].argb)
            model.move([items[1].id], to: work)
            model.move([items[2].id], to: ideas)
        }
    }

    // MARK: Made-up events

    /// Clicks and types as a person would, and says what the selection became.
    private static func events(model: AppModel, window: NSWindow, shot: (String) async -> Void) async {
        @MainActor func pause(_ milliseconds: Int = 350) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        window.makeKeyAndOrderFront(nil)
        await pause()
        say("events: app active = \(NSApp.isActive), window key = \(window.isKeyWindow)")
        let height = window.contentView?.bounds.height ?? 780
        /// A click at a point measured from the window's top left corner.
        @MainActor func click(_ x: CGFloat, _ y: CGFloat, count: Int = 1, flags: NSEvent.ModifierFlags = []) async {
            for number in 1...count {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: height - y), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: number, pressure: type == .leftMouseDown ? 1 : 0) {
                        NSApp.postEvent(event, atStart: false)
                    }
                    await pause(60)
                }
            }
            await pause()
        }
        @MainActor func type(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                    window.sendEvent(event)
                }
            }
            await pause()
        }
        @MainActor func report(_ what: String) {
            let items = model.items(in: model.section ?? .all)
            let picked = items.enumerated().filter { model.selection.contains($0.element.id) }.map { String($0.offset) }.joined(separator: ",")
            say("events: \(what): selected [\(picked)] of \(items.count), open = \(model.path.count), section = \(model.section?.stored ?? "-")")
        }
        // The first card is about here in a 1180-point window with the sidebar at its usual width.
        let sidebar = (window.contentView?.bounds.width ?? 1180) > 1000 ? 260.0 : 240.0
        let first = CGPoint(x: sidebar + 32 + 95, y: 52 + 14 + 95)
        let pitch = 221.5
        model.clearSelection()
        await click(first.x, first.y); report("click card 0")
        await click(first.x + pitch * 2, first.y, flags: .shift); report("shift-click card 2")
        await click(first.x + pitch, first.y, flags: .command); report("command-click card 1")
        await shot("e1-clicks")
        await click(first.x, first.y); report("click card 0")
        await type("\u{F703}", code: 124); report("right arrow")
        await type("\u{F703}", code: 124, flags: .shift); report("shift-right arrow")
        await type("\u{F701}", code: 125); report("down arrow")
        await type("a", code: 0, flags: .command); report("command-A")
        await type("\u{1B}", code: 53); report("escape")
        await click(first.x + pitch, first.y); report("click card 1")
        await type("\r", code: 36); report("return")
        await shot("e2-opened-by-return")
        model.path = []
        await pause(700)
        await click(first.x, first.y, count: 2); report("double-click card 0")
        model.path = []
        await pause(700)
        await click(first.x, first.y); report("click card 0")
        await type("\u{7F}", code: 51); report("delete")
        model.undoManager?.undo(); await pause(); report("undo (\(model.undoManager == nil ? "no undo manager" : "undo manager present"))")
        model.undoManager?.redo(); await pause(); report("redo")
        model.undoManager?.undo(); await pause(); report("undo")
        // A click beside the cards deselects; a drag from there draws the selection rectangle.
        await click(first.x, first.y); report("click card 0")
        await click(first.x + pitch * 2, first.y + 330); report("click on empty space")
        let from = CGPoint(x: first.x + pitch * 2.5, y: first.y + 330), to = CGPoint(x: first.x + pitch * 0.9, y: first.y + 40)
        @MainActor func mouse(_ type: NSEvent.EventType, _ point: CGPoint) async {
            if let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: height - point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                NSApp.postEvent(event, atStart: false)
            }
            await pause(40)
        }
        await mouse(.leftMouseDown, from)
        for step in 1...10 {
            let t = Double(step) / 10
            await mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
        await shot("e3-rubber-band")
        report("rubber band, button still down")
        await mouse(.leftMouseUp, to)
        await pause(); report("rubber band over cards 1 and 2")
        model.clearSelection()

        // Notes as PDF, for Quick Look, sharing and printing.
        let ids = model.items(in: .all).map(\.id)
        let urls = await NotePDF.temporary(ids, in: model)
        let pages = urls.map { url -> String in
            guard let document = CGPDFDocument(url as CFURL) else { return "unreadable" }
            return String(document.numberOfPages)
        }
        say("events: \(urls.count) of \(ids.count) notes as PDF, pages: \(pages.joined(separator: ","))")
        if let id = ids.first {
            model.select(id)
            QuickLook.shared.show([id], in: model)
            await pause(1800)
            say("events: Quick Look panel visible = \(QuickLook.shared.isVisible)")
            // An arrow key typed in the panel moves the selection behind it.
            if let panel = QLPreviewPanel.shared(), let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                                                                  context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124) {
                let taken = QuickLook.shared.previewPanel(panel, handle: arrow)
                await pause(900)
                report("right arrow in the Quick Look panel (taken = \(taken))")
            }
            if let panel = NSApp.windows.first(where: { $0.className.contains("QLPreviewPanel") && $0.isVisible }), let data = capture(panel) {
                try? data.write(to: URL(fileURLWithPath: Launch.value("--window-snapshot") ?? ".").appendingPathComponent("e4-quick-look.png"))
            }
            QuickLook.shared.toggle([id], in: model)
            await pause(400)
            model.clearSelection()
        }

        // The questions asked before something that cannot be undone.
        let folder = URL(fileURLWithPath: Launch.value("--window-snapshot") ?? ".")
        @MainActor func answer(_ name: String, confirm: Bool) async {
            await pause(900)
            guard let sheet = window.attachedSheet else { return say("events: no question shown for \(name)") }
            if let data = capture(sheet) { try? data.write(to: folder.appendingPathComponent(name + ".png")) }
            window.endSheet(sheet, returnCode: confirm ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            await pause(700)
        }
        let before = model.items(in: .all)
        if before.count >= 3 {
            model.setTrashed(Set(before.suffix(2).map(\.id)), true)
            model.section = .trash
            await pause(500)
            let trashed = model.items(in: .trash)
            model.confirmDeleteForever([trashed[0].id])
            await answer("e5-delete-forever", confirm: false); report("delete forever, cancelled (trash holds \(model.count(.trash)))")
            model.confirmDeleteForever([trashed[0].id])
            await answer("e5-delete-forever", confirm: true); report("delete forever, confirmed (trash holds \(model.count(.trash)))")
            model.confirmEmptyTrash()
            await answer("e6-empty-trash", confirm: true); report("empty trash, confirmed (trash holds \(model.count(.trash)))")
            model.section = .all
        }
        if let top = model.folders(in: TreeNode.rootID).last {
            let folders = model.folders(in: TreeNode.rootID).count, notes = model.count(.all)
            model.confirmDeleteFolder(top.id)
            await answer("e7-delete-folder", confirm: true)
            say("events: delete folder: folders \(folders) -> \(model.folders(in: TreeNode.rootID).count), notes \(notes) -> \(model.count(.all)), trash \(model.count(.trash))")
            model.undoManager?.undo(); await pause()
            say("events: undo delete folder: folders \(model.folders(in: TreeNode.rootID).count), inside \(model.folders(in: TreeNode.rootID).last.map { model.folders(in: $0.id).count } ?? -1), notes \(model.count(.all)), trash \(model.count(.trash))")
        }
        var flushed = 0
        model.registerFlush("snapshot") { flushed += 1 }
        model.confirmSignOut()
        await answer("e8-sign-out", confirm: false)
        say("events: sign out, cancelled: signed in = \(model.signedIn), flushes run = \(flushed), notes = \(model.library.notes.count)")
        if Launch.flag("--snapshot-sign-out") {
            model.confirmSignOut()
            await answer("e8-sign-out", confirm: true)
            for _ in 0..<40 where model.signedIn || model.signingOut { await pause(250) }
            let left = (try? FileManager.default.contentsOfDirectory(atPath: model.store.directory("x").deletingLastPathComponent().path))?.count ?? -1
            say("events: sign out, confirmed: signed in = \(model.signedIn), flushes run = \(flushed), notes = \(model.library.notes.count), note folders left = \(left)")
            await shot("e9-signed-out")
        }
        model.unregisterFlush("snapshot")
    }

    // MARK: Menus

    private static func menuText(only: Set<String>? = nil) -> String {
        guard let main = NSApp.mainMenu else { return "no menu bar\n" }
        var out = ""
        func walk(_ menu: NSMenu, _ depth: Int) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items where !item.isHidden {
                let indent = String(repeating: "    ", count: depth)
                if item.isSeparatorItem { out += indent + "———\n"; continue }
                var keys = ""
                if !item.keyEquivalent.isEmpty {
                    let flags = item.keyEquivalentModifierMask
                    keys = "  [" + (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
                    let names: [String: String] = ["\u{8}": "⌫", "\u{7F}": "⌫", "\r": "↩", " ": "Space", "\u{1B}": "⎋"]
                    keys += (names[item.keyEquivalent] ?? item.keyEquivalent.uppercased()) + "]"
                }
                out += indent + item.title + keys + (item.state == .on ? "  ✓" : "") + (item.isEnabled ? "" : "  (disabled)") + "\n"
                if let submenu = item.submenu, depth < 3 { walk(submenu, depth + 1) }
            }
        }
        for top in main.items {
            guard let submenu = top.submenu, only?.contains(top.title) ?? true else { continue }
            out += top.title + "\n"
            walk(submenu, 1)
        }
        return out
    }

    /// A picture of one of this app's own windows as the window server composes it.
    private static func capture(_ window: NSWindow) -> Data? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
