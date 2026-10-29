import AppKit
import SamsungNotesKit
import SwiftUI

/// The scripted checks of the picture's menu, the pointer over a picture, the pages at the side,
/// finding in a note and note styles. Part of `--editor-check`; alone with `--menu-only`.
extension EditorChecks {
    @MainActor static func menuChecks(model: AppModel, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        model.path = []
        await pause(600)
        model.createNote()
        await pause(1500)
        guard let id = model.path.last, let first = find(NoteTextView.self, in: window()?.contentView).first, let png = testPicture() else {
            say("FAIL: no note for the menu checks")
            return
        }
        first.window?.makeFirstResponder(first)
        first.insertText("Apples and pears\nA second line about apples\nThe last line", replacementRange: first.selectedRange())
        await pause(300)
        let board = NSPasteboard(name: NSPasteboard.Name("snotes-editor-check-7"))
        board.clearContents()
        board.setData(png, forType: .png)
        _ = first.controller?.onPastePicture?(board, (first.string as NSString).length)
        board.releaseGlobally()
        await pause(2500)
        guard let session = NoteSession.live.object(forKey: id as NSString), let view = find(NoteTextView.self, in: window()?.contentView).first,
              let text = view.controller, let window = view.window, let object = session.note?.document.floating.first?.id, let frame = text.pictureFrames[object] else {
            say("FAIL: the note for the menu checks has no picture in place")
            return
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func stored() -> NoteObject? { (try? model.store.load(id))?.document.floating.first { $0.id == object } }
        func shown() -> NoteObject? { session.note?.document.floating.first { $0.id == object } }

        // The pointer: a hand over the picture, a closed hand while it is dragged. The events are
        // handed to the picture's grip itself and the pointer read at once: where the real
        // pointer happens to rest on the screen must not decide the outcome.
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        guard let hand = find(PictureGripView.self, in: window.contentView).first else { say("FAIL: the picture has no grip"); return }
        if let move = event(.mouseMoved, centre) { hand.mouseMoved(with: move) }
        let over = NSCursor.current
        if let down = event(.leftMouseDown, centre) { hand.mouseDown(with: down) }
        let pressed = NSCursor.current
        var held = NSCursor.current
        for step in 1...6 { if let move = event(.leftMouseDragged, CGPoint(x: centre.x + CGFloat(step), y: centre.y + CGFloat(step) * 2)) { hand.mouseDragged(with: move); held = NSCursor.current } }
        // While it is held, the text beneath does not take the pointer back.
        if let move = event(.mouseMoved, centre) { view.mouseMoved(with: move) }
        let stayed = NSCursor.current
        if let up = event(.leftMouseUp, centre) { hand.mouseUp(with: up) }
        let after = NSCursor.current
        await pause(900)
        say("\(verdict(over == NSCursor.openHand)) the pointer over a picture is an open hand")
        say("\(verdict(pressed == NSCursor.closedHand && held == NSCursor.closedHand)) and a closed hand from the press on, while the picture is dragged")
        say("\(verdict(stayed == NSCursor.closedHand)) the text under the picture leaves the pointer alone")
        say("\(verdict(after == NSCursor.openHand)) let go, it is an open hand again")
        if let corner = event(.mouseMoved, CGPoint(x: frame.maxX, y: frame.maxY)) { hand.mouseMoved(with: corner) }
        say("\(verdict(NSCursor.current != NSCursor.openHand && NSCursor.current != NSCursor.arrow)) over a corner handle it is the arrows for resizing")

        // The menu of a right click.
        guard let grip = find(PictureGripView.self, in: window.contentView).first, let menu = grip.makeMenu?(grip) else {
            say("FAIL: the picture has no menu")
            return
        }
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        let wanted = ["Cut", "Copy", "Paste", "Delete", "Crop", "Lasso Crop", "Remove Anchor to Text", "Fit to Page Width", "Share…", "Save Image…"]
        say("\(verdict(titles == wanted)) a right click offers: \(titles.joined(separator: ", "))")
        func choose(_ title: String, in menu: NSMenu? = nil) {
            guard let item = (menu ?? grip.makeMenu?(grip))?.items.first(where: { $0.title == title }), let action = item.action else { say("FAIL: no menu item “\(title)”"); return }
            _ = item.target?.perform(action, with: item)
        }
        if let right = event(.rightMouseDown, centre) { session.pickPicture(nil); _ = grip.menu(for: right) }
        say("\(verdict(session.pictureSelection == object)) a right click picks the picture")

        // Copy puts the picture on the clipboard as a picture.
        let general = NSPasteboard.general
        let kept = general.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        choose("Copy")
        let copied = general.data(forType: .png)
        say("\(verdict(copied == png)) Copy puts the picture's own file on the clipboard (\(copied?.count ?? 0) bytes)")
        // Paste sets a second picture after it.
        choose("Paste")
        await pause(2500)
        say("\(verdict(text.text.objectIDs.count == 2 && session.note?.document.floating.count == 2)) Paste sets the copied picture after it (\(text.text.objectIDs.count) pictures in the text)")
        // What was on the clipboard before goes back.
        general.clearContents()
        if !kept.isEmpty { general.writeObjects(kept) }
        if let second = text.text.objectIDs.last, second != object {
            session.removePicture(second)
            await pause(1800)
        }

        // Fit to page width.
        choose("Fit to Page Width")
        await pause(1500)
        let column = session.note.map { TextColumn($0.document).width } ?? 0
        say("\(verdict(abs((shown()?.rect.width ?? 0) - column) < 1 && abs((stored()?.rect.width ?? 0) - column) < 1)) Fit to Page Width makes it as wide as the text's column (\(Int(shown()?.rect.width ?? 0)) of \(Int(column)) units)")
        await tick()
        model.undoManagerForChecks?.undo()
        await pause(1200)
        await tick()
        say("\(verdict((shown()?.rect.width ?? 0) < column - 40)) and undo gives it its size back (\(Int(shown()?.rect.width ?? 0)) units)")
        await shot("m1-menu-note", 500)

        // Freed from the text and set into it again.
        choose("Remove Anchor to Text")
        await pause(2200)
        let freed = stored()
        say("\(verdict(freed?.inText == false && !text.text.objectIDs.contains(object) && shown()?.inText == false)) Remove Anchor to Text frees it: it lies on page \((freed?.pageIndex ?? -1) + 1) and has no place in the text any more")
        let lines = text.text.string
        say("\(verdict(!lines.contains("\u{FFFC}") && lines.contains("The last line"))) the text closed up under it: \(lines.replacingOccurrences(of: "\n", with: " | "))")
        await shot("m2-freed", 500)
        guard let free = find(PictureGripView.self, in: window.contentView).first, let freeMenu = free.makeMenu?(free) else { say("FAIL: the freed picture has no menu"); return }
        say("\(verdict(freeMenu.items.contains { $0.title == "Anchor to Text" })) its menu now offers Anchor to Text")
        choose("Anchor to Text", in: freeMenu)
        await pause(2500)
        say("\(verdict(stored()?.inText == true && text.text.objectIDs == [object])) Anchor to Text sets it into the text again: \(text.text.string.replacingOccurrences(of: "\u{FFFC}", with: "[picture]").replacingOccurrences(of: "\n", with: " | "))")
        say("\(verdict(text.pictureFrames[object] != nil)) and the text makes room for it")
        // No step of undo leads back to a text without the picture's place: that would take the picture out of the note.
        await tick()
        model.undoManagerForChecks?.undo()
        await pause(400)
        session.saveNow()
        await pause(1800)
        say("\(verdict(stored()?.inText == true && text.text.objectIDs == [object] && (try? model.store.load(id))?.document.floating.count == 1)) undo after that leaves the picture in the note and in the text")
        await shot("m3-anchored", 500)

        // Finding.
        session.finding = true
        await pause(500)
        text.find("apples")
        await pause(300)
        say("\(verdict(text.found.count == 2 && text.foundIndex == 0)) finding “apples” marks both places, whatever their case (\(text.found.count) found)")
        text.findStep(1)
        say("\(verdict(text.foundIndex == 1)) the next place is the second")
        text.findStep(1)
        say("\(verdict(text.foundIndex == 0)) and after the last it goes round to the first")
        await shot("m4-find", 500)
        text.find("zebra")
        say("\(verdict(text.found.isEmpty)) what is not there is not found")
        session.finding = false
        await pause(400)

        // The pages at the side.
        EditorRemote.shared.pages = true
        await pause(900)
        let before = session.visiblePages
        session.addPage(after: before - 1)
        await pause(1500)
        session.addPage(after: session.visiblePages - 1)
        await pause(1500)
        say("\(verdict(session.visiblePages == before + 2)) two pages added: \(before) -> \(session.visiblePages) shown")
        await shot("m5-pages", 700)
        say("\(verdict(!session.pageHoldsSomething(session.visiblePages - 1))) an empty page is known to be empty")
        session.removePage(session.visiblePages - 1)
        await pause(1500)
        say("\(verdict(session.visiblePages == before + 1)) and one deleted again: \(session.visiblePages) shown")
        EditorRemote.shared.pages = false
        await pause(500)
        await cropChecks(model: model, session: session, object: object, shot: shot)
        await insertChecks(model: model, session: session, shot: shot)
        await styleChecks(model: model, session: session, shot: shot)
        await settingsChecks(model: model, shot: shot)
    }

    /// Syncing through a folder (iCloud Drive's place is taken by a folder given with
    /// `--sync-folder`) or through a cloud (Google Drive's place is taken by a folder given with
    /// `--google-stand-in`, or all of Google's by a stand-in server given with
    /// `--google-test-server`, which is then signed in to on its page): this app is one Mac, and a
    /// second library in this process plays another.
    @MainActor static func syncChecks(model: AppModel, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        let standIn = Launch.value("--google-stand-in").map { URL(fileURLWithPath: $0) }
        let server = Launch.value("--google-test-server")
        if server != nil {
            // Choosing Google Drive shows Google's page; its answer comes back to the app, which is then signed in and syncing.
            say("\(verdict(model.provider != .google && !model.googleSignedIn)) before signing in, the notes are not synced with Google Drive")
            model.chooseProvider(.google)
            await pause(600)
            say("\(verdict(model.googleSigningIn || model.googleSignedIn)) choosing Google Drive opens the sign-in page")
            for _ in 0..<120 { await pause(250); if model.provider == .google { break } }
            say("\(verdict(model.provider == .google && model.googleSignedIn && model.googleEmail == "user@example.com")) the page's answer comes back to the app, which is signed in as \(model.googleEmail ?? "nobody") and syncs with Google Drive")
            if let problem = model.lastError { say("     (\(problem))") }
        }
        let mirrored = standIn != nil || server != nil
        guard let folder = model.syncFolder, Launch.value("--sync-folder") != nil || mirrored else { say("FAIL: no folder to sync with (give --sync-folder, --google-stand-in or --google-test-server)"); return }
        func settle() async { for _ in 0..<40 { await pause(250); if !model.isSyncing { break } }; await pause(300) }
        say("\(verdict(model.provider == (mirrored ? .google : .icloud))) the notes are synced with \(model.provider.title)")
        if mirrored { say("\(verdict(model.googleSignedIn && model.syncFolder?.lastPathComponent == "google")) through this Mac's copy of what the Google account's Drive holds") }
        let other = LocalStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snotes-other-mac-\(UUID().uuidString)"))
        let otherEdits = LocalEdits(store: other)
        // The other Mac reaches the same cloud through a copy of its own, or the same folder directly.
        let otherFolder = mirrored ? other.root.appendingPathComponent("google") : folder
        let otherCloud: CloudFiles? = standIn.map { DirectoryCloud(folder: $0) } ?? (server != nil ? model.google.drive() : nil)
        let otherMirror = otherCloud.map { CloudMirror(store: other, cloud: $0, folder: otherFolder) }
        let otherMac = FolderSync(store: other, folder: otherFolder, deviceName: "Other Mac")
        let otherKey = Box<Vault?>(nil)
        @discardableResult func otherSync() async -> FolderSync.Outcome? {
            if let otherMirror { return try? await otherMirror.sync(prepare: { $0.vault = otherKey.value; $0.seals = otherKey.value != nil }) }
            otherMac.vault = otherKey.value
            otherMac.seals = otherKey.value != nil
            return try? otherMac.sync()
        }
        let inCloud = standIn ?? folder
        func type(_ edits: LocalEdits, _ id: String, _ more: String) {
            guard var body = edits.richText(id)?.body else { return }
            body.replace(body.length..<body.length, with: more)
            _ = try? edits.saveRich(id, title: nil, body: body)
        }
        func text(_ store: LocalStore, _ id: String) -> String { (try? store.load(id))?.document.body.plain ?? "" }

        // A note made here reaches the other Mac; one made there arrives here.
        model.path = []
        await pause(500)
        model.createNote()
        await pause(1500)
        guard let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString), let view = session.text.view else { say("FAIL: no note"); return }
        view.window?.makeFirstResponder(view)
        view.insertText("Written on this Mac", replacementRange: view.selectedRange())
        session.saveNow()
        await pause(1200)
        model.syncNow()
        await settle()
        await otherSync()
        say("\(verdict(text(other, id) == "Written on this Mac")) a note written here is on the other Mac after a sync")
        let theirs = (try? otherEdits.createTextNote(title: "From the other Mac", body: "hello")) ?? ""
        type(otherEdits, id, "\nand a line from the other Mac")
        await otherSync()
        model.syncNow()
        await settle()
        say("\(verdict(model.library.notes[theirs]?.title == "From the other Mac")) a note made on the other Mac arrives here")
        await pause(1500)
        say("\(verdict(session.text.text.string.contains("and a line from the other Mac"))) and its change to the open note shows in the open note")

        // Changed on both: nothing is overwritten, and the choice is asked for.
        view.insertText("\nchanged here", replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
        session.saveNow()
        await pause(1200)
        type(otherEdits, id, "\nchanged there")
        await otherSync()
        model.syncNow()
        await settle()
        say("\(verdict(model.syncConflicts.map(\.id) == [id] && text(model.store, id).contains("changed here") && !text(model.store, id).contains("changed there"))) changed on both Macs, the note waits to be decided and keeps what was written here")
        model.showConflicts = true
        await pause(1200)
        if let sheet = NSApplication.shared.windows.first(where: { $0.isSheet }), let data = capture(sheet), let out = Launch.value("--editor-check") {
            try? data.write(to: URL(fileURLWithPath: out).appendingPathComponent("s1-conflict.png"))
        }
        if let conflict = model.syncConflicts.first { model.resolve(conflict, .keepBoth) }
        await settle()
        await pause(1500)
        let copies = model.library.notes.values.filter { $0.title.contains("this Mac's version") }
        say("\(verdict(model.syncConflicts.isEmpty && text(model.store, id).contains("changed there") && copies.count == 1 && text(model.store, copies.first?.id ?? "").contains("changed here"))) keeping both gives the other Mac's version and this Mac's as a note of its own")

        // Locked notes are encrypted in the folder once a password is set.
        say("\(verdict(!model.encryptsLocked && model.vaultInFolder == nil)) locked notes are not encrypted until it is asked for")
        say("\(verdict(model.startEncrypting(password: "a long password"))) an encryption password is set")
        await settle()
        try? model.edits.setLocked(id, true, owner: "")
        model.changed()
        model.syncNow()
        await settle()
        var all = Data()
        if server != nil {
            // Everything the Drive holds of the note, fetched afresh.
            for file in (try? await model.google.drive().changes(since: nil))?.changed ?? [] {
                if file.name.hasPrefix("notes/\(id)/"), let data = try? Data(contentsOf: file.url) { all.append(data) }
                try? FileManager.default.removeItem(at: file.url)
            }
        } else {
            for case let file as URL in FileManager.default.enumerator(at: inCloud.appendingPathComponent("notes/\(id)"), includingPropertiesForKeys: nil) ?? FileManager.default.enumerator(atPath: "/dev/null")! {
                if let data = try? Data(contentsOf: file) { all.append(data) }
            }
        }
        say("\(verdict(model.encryptsLocked && !all.isEmpty && all.range(of: Data("Written on this Mac".utf8)) == nil)) the locked note's file in the folder cannot be read")
        let before = await otherSync()?.sealedWithoutKey ?? -1
        say("\(verdict(before == 1 && !text(other, id).isEmpty)) the other Mac, without the password, keeps its older copy and waits")
        if let locked = otherMac.lockedVault(), let vault = try? Vault(locked, password: "a long password") {
            otherKey.value = locked.active ? vault : nil
            await otherSync()
            say("\(verdict((try? other.load(id))?.document.isLocked == true && text(other, id).contains("changed there"))) with the password typed there, it reads the encrypted note")
        } else {
            say("FAIL: the other Mac could not open the vault with the password")
        }
        await shot("s2-synced", 500)
        try? FileManager.default.removeItem(at: other.root)
        guard let out = Launch.value("--editor-check").map({ URL(fileURLWithPath: $0) }) else { return }

        // Settings name the service in use, and for Google Drive whose Drive it is and the way out.
        // Google Drive is offered only by a build registered with Google, or while it is in use.
        say("\(verdict(model.offeredProviders.contains(.google) == (mirrored || GoogleRegistration.client != nil))) Google Drive is \(model.offeredProviders.contains(.google) ? "offered" : "not offered") in Settings")
        func settings() -> NSWindow? { NSApplication.shared.windows.first { $0.isVisible && !$0.isSheet && $0.identifier?.rawValue.contains("Settings") == true } }
        model.showSyncSettings()
        await pause(1500)
        if let window = settings(), let data = capture(window) { try? data.write(to: out.appendingPathComponent("s3-settings.png")) }
        say("\(verdict(settings() != nil)) Settings show the service in use and how sync stands")
        settings()?.close()
    }

    /// What Settings gives a new note, a note of one page that grows, and the lock on a note.
    @MainActor static func settingsChecks(model: AppModel, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        // A new note takes the default note style: here an endless page of yellow paper with narrow lines.
        model.defaultEndless = true
        model.defaultPaper = PaperColors.all[7].argb
        model.defaultTemplate = .lineNarrow
        model.path = []
        await pause(600)
        model.createNote()
        await pause(2000)
        defer { model.defaultEndless = false; model.defaultPaper = PaperColors.plain; model.defaultTemplate = .blank }
        guard let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString) else { say("FAIL: no new note is open"); return }
        func stored() -> NoteDocument? { (try? model.store.load(id))?.document }
        say("\(verdict(stored()?.isEndless == true && stored()?.pages.count == 1 && stored()?.pages.first?.background == PaperColors.all[7].argb && stored()?.pages.first?.template == .lineNarrow)) a new note takes the default style: one endless page, yellow, narrow lines")
        let first = stored()?.pages.first?.height ?? 0
        if let view = session.text.view {
            view.window?.makeFirstResponder(view)
            view.insertText((1...70).map { "Line \($0) of a long note" }.joined(separator: "\n"), replacementRange: view.selectedRange())
        }
        session.saveNow()
        await pause(2500)
        let now = stored()
        let height = now?.pages.first?.height ?? 0
        say("\(verdict(now?.pages.count == 1 && height > first && first > 0 && height.truncatingRemainder(dividingBy: first) == 0 && session.visiblePages == 1 && !session.hasPages)) written past its foot, the page grows by its first height and stays one page (\(Int(first)) to \(Int(height)) units)")
        await shot("m17-endless-note", 600)
        // With saving as one types switched off, what is typed waits for ⌘S.
        model.autoSave = false
        defer { model.autoSave = true }
        let before = now?.body.plain ?? ""
        session.text.view?.insertText(" and more", replacementRange: session.text.view?.selectedRange() ?? NSRange(location: 0, length: 0))
        await pause(2200)
        say("\(verdict(stored()?.body.plain == before && session.unsaved)) with auto save off, what is typed is not stored as it is typed")
        session.saveNow()
        await pause(1800)
        say("\(verdict(stored()?.body.plain == before + " and more" && !session.unsaved)) and is stored on Save")
        // The lock: marked on the note as the Windows client marks it, with the account's password behind it.
        // The lock, as the Windows client marks it (the question of who is there is Touch ID's, which a check cannot answer).
        try? model.edits.setLocked(id, true, owner: model.lockOwner ?? "")
        model.changed()
        await pause(900)
        say("\(verdict(model.library.notes[id]?.isLocked == true && session.isLocked && !session.canEdit)) a locked note is closed until it is unlocked")
        await shot("m18-locked-note", 500)
        try? model.edits.setLocked(id, false, owner: "")
        model.changed()
        await pause(700)
        say("\(verdict(model.library.notes[id]?.isLocked == false && !session.isLocked)) and open again with the lock taken off")
    }

    /// The handles, menus and panels of an open table, as the Windows client has them.
    @MainActor static func tableChecks(model: AppModel, session: NoteSession, table id: String?, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        guard let id else { say("FAIL: no table to open"); return }
        func stored() -> SamsungTable? { (try? model.store.load(session.noteID))?.document.floating.first { $0.id == id }?.table }
        func grips(_ prefix: String) -> [PointerGrip.Grip] { find(PointerGrip.Grip.self, in: window()?.contentView).filter { $0.accessibilityLabel()?.hasPrefix(prefix) == true } }
        func open() -> TableLive? { EditorRemote.shared.tableOpen }
        func step(_ change: @escaping (TableLive) -> Void) async {
            EditorRemote.shared.tableChange = change
            EditorRemote.shared.tableStep += 1
            await pause(500)
        }
        func panel(_ name: String) async {
            await pause(900)
            let popover = NSApplication.shared.windows.first { $0.isVisible && $0 !== window() && String(describing: type(of: $0)).contains("Popover") }
            say("\(verdict(popover != nil)) the \(name) hangs on the table")
            if let popover, let data = capture(popover), let folder = Launch.value("--editor-check") { try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("m9t-\(name.replacingOccurrences(of: " ", with: "-")).png")) }
        }
        let before = stored()
        EditorRemote.shared.smartBegin = nil
        await pause(400)
        EditorRemote.shared.smartBegin = id
        await pause(1300)
        say("\(verdict(open()?.id == id && grips("Width of column").count == 3 && grips("Pick column").count == 1 && grips("Pick row").count == 1)) opened, the table has a grip above each column's edge, and a handle for the caret's column and row")
        // A column's edge dragged by its grip, 60 points to the left.
        let unit = Float((session.note?.document.density ?? 1) / max(session.text.metrics.scale, 0.01))
        if let grip = grips("Width of column 2").first, let width = open()?.table.columnWidths[safe: 1] {
            grip.drag?(CGSize(width: -30, height: 0))
            grip.drag?(CGSize(width: -60, height: 0))
            grip.end?()
            await pause(500)
            let now = open()?.table.columnWidths ?? []
            say("\(verdict(abs((now[safe: 1] ?? 0) - (width - 60 * unit)) < 0.5 && now[safe: 0] == before?.columnWidths[safe: 0])) dragging the grip above a column's edge narrows that column (\(Int(width)) to \(Int(now[safe: 1] ?? 0)) units)")
        } else {
            say("FAIL: no grip for the second column")
        }
        // The row's handle picks the row; pressed again, it opens the row's menu.
        grips("Pick row 1").first?.click?()
        await pause(500)
        say("\(verdict(open()?.pick == .row(0) && grips("Row 1: menu").count == 1)) a click on the handle beside a row picks the row")
        await shot("m9t1-row-picked", 400)
        grips("Row 1: menu").first?.click?()
        await pause(400)
        say("\(verdict(open()?.panel == .menu)) and a click on the picked handle opens its menu")
        await panel("row menu")
        // From the menu: a row added under it, then the cells' style.
        await step { $0.table.insertRow(at: 1); $0.beforePanel = $0.table; $0.panel = .cellStyle }
        await panel("cell style")
        await step { live in
            live.table.change(where: { row, _ in row == 0 }) { $0.background = TablePanel.papers[4]; $0.bold = true; $0.alignment = 2; $0.fontSize = 17 }
            live.panel = nil
        }
        await shot("m9t2-row-styled", 500)
        grips("Pick column 1").first?.click?()
        await pause(400)
        say("\(verdict(open()?.pick == .column(0))) the handle above a column picks the column")
        grips("Column 1: menu").first?.click?()
        await panel("column menu")
        await step { $0.panel = nil }
        await step { $0.pick = nil; $0.beforePanel = $0.table; $0.panel = .tableStyle }
        await panel("table style")
        await step { $0.table.setHeading(row: true); $0.table.setLines(.grid); $0.panel = nil }
        await shot("m9t2b-heading-and-lines", 500)
        EditorRemote.shared.smartDone += 1
        await pause(2600)
        let after = stored()
        say("\(verdict(after?.rows.count == (before?.rows.count ?? 0) + 1 && after?.texts[safe: 1] == ["", "", ""])) closed, the table has its new row under the first")
        say("\(verdict(after?.rows.first?.allSatisfy { $0.bold && $0.alignment == 2 && $0.fontSize == 17 && $0.background == TablePanel.papers[4] } == true && after?.rows.last?.first?.bold == false)) the first row's cells are bold, centred, larger and on blue paper")
        say("\(verdict(abs((after?.columnWidths[safe: 1] ?? 0) - ((before?.columnWidths[safe: 1] ?? 0) - 60 * unit)) < 0.5)) and the second column is as narrow as it was dragged")
        say("\(verdict(after?.headingRow == true && after?.headingColumn == false && after?.lines == .grid && after?.rows.first?.first?.color == 0xFF3A_3A3D && after?.paper(row: 0, column: 1) == 0xFFEE_EBE7)) its first row is a heading on the heading's paper, and its lines are a square grid")
        if let after, let object = session.pictureObject(id), let room = session.text.pictureFrames[id], let document = session.note?.document {
            let scale = session.text.metrics.scale / document.density
            say("\(verdict(abs(Double(room.height) / scale - (after.rect.height + NoteRenderer.tableRoom(document.density).height)) < 2 && abs(object.rect.height - after.rect.height) < 0.01)) the text has made room for the table's new height (\(Int(after.rect.height)) units)")
        }
        await shot("m9t3-table-closed", 500)
        session.undoManager?.undo()
        await pause(2400)
        say("\(verdict(stored()?.rows.count == before?.rows.count && stored()?.columnWidths == before?.columnWidths && stored()?.rows.first?.first?.bold == false)) Undo gives back the table as it was before it was opened")
        session.undoManager?.redo()
        await pause(2400)
        say("\(verdict(stored()?.rows.count == (before?.rows.count ?? 0) + 1)) and Redo the changes")
    }

    /// A sticky note, a table, a recording and a PDF put into the note.
    @MainActor static func insertChecks(model: AppModel, session: NoteSession, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        let id = session.noteID
        func floating() -> [NoteObject] { session.note?.document.floating ?? [] }
        func stored() -> NoteDocument? { (try? model.store.load(id))?.document }
        func grips() -> [PictureGripView] { find(PictureGripView.self, in: window()?.contentView) }
        func pads() -> [NSTextView] { find(NSTextView.self, in: window()?.contentView).filter { !($0 is NoteTextView) && !$0.isFieldEditor && $0.isEditable } }

        // A sticky note of Samsung's own kind: a custom object of its page, with a document of its own.
        guard let sticky = session.addSticky(page: 0, text: "Call the plumber on Monday") else { say("FAIL: no sticky note was added"); return }
        await pause(2200)
        var found = session.stickyObject(sticky)
        let side = LocalEdits.stickySide(pageWidth: session.note?.document.pages.first?.width ?? 0)
        say("\(verdict(found?.page == 0 && abs((found?.object.rect.width ?? 0) - side) < 0.01 && found?.object.stickyIsExact == true)) a sticky note lies folded on the page, a square of \(Int(side)) units")
        say("\(verdict(found?.object.sticky?.text == "Call the plumber on Monday" && found?.object.paper == StickyDocument.papers[0])) what it says is read back from its own file")
        let firstFile = found?.object.attachFile ?? ""
        var files = stored()?.files.map(\.id) ?? []
        say("\(verdict(files.contains(firstFile) && model.store.loadLibrary().notes[id]?.unsentFiles?.contains(firstFile) == true)) its file is listed in the note and waits to be sent")
        session.changeSticky(sticky, text: "Call the plumber on Tuesday", paper: StickyDocument.papers[3])
        await pause(2200)
        found = session.stickyObject(sticky)
        files = stored()?.files.map(\.id) ?? []
        let kept = stored()?.pages.first?.objects.first { $0.id == sticky }
        say("\(verdict(kept?.sticky?.text == "Call the plumber on Tuesday" && kept?.paper == StickyDocument.papers[3] && found?.object.sticky?.text == "Call the plumber on Tuesday")) changed, it says the new words on its new paper")
        say("\(verdict(!files.contains(firstFile) && files.contains(kept?.attachFile ?? "-"))) and the file of what it said before is no longer listed")
        // Moved by its square, as a drag does.
        if let place = found?.object.rect {
            session.moveSticky(sticky, to: place.offsetBy(dx: -220, dy: 140), page: 0)
            await pause(1500)
            let now = stored()?.pages.first?.objects.first { $0.id == sticky }?.rect ?? .zero
            say("\(verdict(abs(now.minX - (place.minX - 220)) < 0.01 && abs(now.minY - (place.minY + 140)) < 0.01 && abs(now.width - place.width) < 0.01)) dragged, it lies where it was dropped")
        }
        await shot("m9a-sticky-folded", 500)
        // One click on the folded square opens it; it is written on where it lies.
        let centre = { (view: NSView) in view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        if let grip = grips().first(where: { $0.clickOpens }), let host = grip.window {
            func press(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: centre(grip), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let down = press(.leftMouseDown) { grip.mouseDown(with: down) }
            if let up = press(.leftMouseUp) { grip.mouseUp(with: up) }
            await pause(1200)
            let open = pads()
            say("\(verdict(open.count == 1 && open.first?.string == "Call the plumber on Tuesday" && open.first?.window?.firstResponder === open.first)) a click opens it with its words and the caret in it")
            open.first?.insertText(" at nine", replacementRange: NSRange(location: (open.first?.string as NSString?)?.length ?? 0, length: 0))
            await shot("m9a1-sticky-open", 600)
            EditorRemote.shared.smartDone += 1
            await pause(2200)
            say("\(verdict(stored()?.pages.first?.objects.first { $0.id == sticky }?.sticky?.text == "Call the plumber on Tuesday at nine" && pads().isEmpty)) folded up again, it keeps what was typed")
        } else {
            say("FAIL: the sticky note has nothing to click on")
        }

        // A table of Samsung's own kind, set in the text: asked for by its rows and columns.
        let before = Set(floating().map(\.id))
        let made = session.addTable(rows: 3, columns: 3)
        await pause(2500)
        var table = floating().first { !before.contains($0.id) }
        say("\(verdict(table?.id == made && table?.kind == .table && table?.inText == true && session.text.text.objectIDs.contains(table?.id ?? "-"))) a table is set in the text")
        say("\(verdict(table?.tableIsExact == true && table?.table?.texts == Array(repeating: ["", "", ""], count: 3))) of three rows and three columns, empty, in Samsung's own form")
        let cells = [["Day", "Task", "Done"], ["Mon", "Plumber", "yes"], ["Tue", "A longer task that takes two lines in its cell", ""]]
        if let made { session.changeTable(made, texts: cells) }
        await pause(2500)
        table = floating().first { $0.id == made }
        say("\(verdict(table?.table?.texts == cells && stored()?.floating.first { $0.id == made }?.table?.texts == cells)) its cells are written into its record")
        let twoLines = (table?.table?.rect.height ?? 0) / max(table?.rect.height ?? 1, 1)
        say("\(verdict(abs(twoLines - 1) < 0.001 && (table?.rect.height ?? 0) > 3.5 * (15 * 1.35 + 8) * (session.note?.document.density ?? 1))) the row with two lines of text is higher (\(Int(table?.rect.height ?? 0)) units in all)")
        await shot("m9a2-table", 700)
        // Written in where it stands: the cells lie open over the table.
        if let table {
            EditorRemote.shared.smartBegin = table.id
            await pause(1200)
            let fields = find(NSTextField.self, in: window()?.contentView).filter { $0.isEditable }
            say("\(verdict(fields.count >= 9)) opened, the table's nine cells can be typed into where they stand (\(fields.count) fields)")
            // A real press on the last cell, then typing.
            // The cell lowest in the window and furthest to the right: by its top edge, since a
            // cell with more lines reaches further down than its neighbours.
            if let last = fields.max(by: { a, b in
                let pa = a.convert(a.bounds, to: nil), pb = b.convert(b.bounds, to: nil)
                return abs(pa.maxY - pb.maxY) > 4 ? pa.maxY > pb.maxY : pa.minX < pb.minX
            }), let host = last.window {
                let at = last.convert(CGPoint(x: last.bounds.midX, y: last.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let press = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(press, atStart: false) }
                }
                await pause(700)
                let editor = host.firstResponder as? NSTextView
                say("\(verdict(editor != nil && editor?.isFieldEditor == true)) a press on a cell puts the caret in it")
                editor?.insertText("no", replacementRange: editor?.selectedRange() ?? NSRange(location: 0, length: 0))
                await pause(400)
            }
            await shot("m9b-table-in-place", 500)
            EditorRemote.shared.smartDone += 1
            await pause(2500)
            var wanted = cells
            wanted[2][2] = "no"
            let now = stored()?.floating.first { $0.id == table.id }
            say("\(verdict(now?.table?.texts == wanted && now?.tableIsExact == true)) what was typed is in the table when it is closed: \(now?.table?.texts[safe: 2]?.joined(separator: " / ") ?? "nothing")")
            say("\(verdict(find(NSTextField.self, in: window()?.contentView).filter { $0.isEditable }.count < 9)) and the cells are closed again")
            // Where the text view shows the table is where the note says it lies.
            if let room = session.text.pictureFrames[table.id], let kept = now, let document = session.note?.document {
                let scale = session.text.metrics.scale / document.density
                let top = (Double(room.midY) - Double(session.text.view?.textContainerOrigin.y ?? 0)) / scale + TextColumn(document).top - kept.rect.height / 2
                say("\(verdict(abs(top - kept.rect.minY) < 1.5)) the table is shown where the note keeps it (\(Int(top)) against \(Int(kept.rect.minY)) units down)")
            }
        }
        EditorRemote.shared.smartBegin = nil
        await tableChecks(model: model, session: session, table: made, shot: shot)
        // Insert › Sticky Note: an empty one appears on the page, open to be written on.
        let stickies = Set(session.stickyIDs)
        EditorRemote.shared.insert = .sticky
        await pause(2800)
        let fresh = session.stickyIDs.first { !stickies.contains($0) }
        let open = pads()
        say("\(verdict(fresh != nil && open.count == 1 && open.first?.window?.firstResponder === open.first)) Insert › Sticky Note puts an empty one on the page with the caret in it (\(open.count) open)")
        open.first?.insertText("Buy milk", replacementRange: NSRange(location: 0, length: 0))
        await shot("m9b1-sticky-in-place", 600)
        EditorRemote.shared.smartDone += 1
        await pause(2500)
        say("\(verdict(fresh.flatMap { session.stickyObject($0)?.object.sticky?.text } == "Buy milk" && session.stickyIDs.count == 2)) what was written on it is kept when it is closed")
        if let fresh {
            session.removePicture(fresh)
            await pause(1500)
            let left = stored()?.pages.flatMap(\.objects).filter { $0.kind == .sticky }.map(\.id) ?? []
            say("\(verdict(left == [sticky] && (stored()?.files.count ?? 0) == session.stickyIDs.count + (stored()?.floating.filter { $0.pictureFile != nil }.count ?? 0))) deleted, it and its file are gone from the note")
        }
        EditorRemote.shared.insert = nil

        // Undo of what was written on a sticky note (a table's is checked with its handles, above).
        let said = stored()?.pages.first?.objects.first { $0.id == sticky }?.sticky?.text ?? "-"
        session.changeSticky(sticky, text: "Something else entirely", paper: StickyDocument.papers[1])
        await pause(2000)
        session.undoManager?.undo()
        await pause(2200)
        let back = stored()?.pages.first?.objects.first { $0.id == sticky }
        say("\(verdict(back?.sticky?.text == said && back?.paper == StickyDocument.papers[3])) Undo gives a sticky note its words and its paper back")

        // A sticky note and a table kept as pictures by an earlier build become Samsung's own when opened.
        let pictures = Set(floating().map(\.id))
        var old = SmartPicture.Table(rows: 2, columns: 2)
        old.cells = [["Item", "Price"], ["Tea", "3"]]
        if let file = SmartPicture.table(old).picture() { session.addPicture(file, at: session.text.text.length) }
        if let file = SmartPicture.sticky(SmartPicture.Sticky(text: "An old one", color: 0xFFC5_E1FB)).picture() {
            session.addPicture(file, onPage: (0, CGRect(x: 80, y: 900, width: 200, height: 200)))
        }
        await pause(3000)
        let olds = floating().filter { !pictures.contains($0.id) }
        say("\(verdict(olds.count == 2 && olds.allSatisfy { session.smartContent($0.id) != nil })) two pictures of an earlier build are in the note (\(olds.count))")
        for object in olds { EditorRemote.shared.smartBegin = object.id; await pause(3200); EditorRemote.shared.smartDone += 1; await pause(1200) }
        EditorRemote.shared.smartBegin = nil
        let after = stored()
        let newTable = after?.floating.first { $0.kind == .table && $0.id != made }
        let newSticky = after?.pages.first?.objects.first { $0.kind == .sticky && $0.id != sticky }
        say("\(verdict(after?.floating.contains { olds.map(\.id).contains($0.id) } == false)) opened, both pictures are gone from the note")
        say("\(verdict(newTable?.table?.texts == old.cells && newTable?.table?.rows.first?.map(\.bold) == [true, true] && newTable?.inText == true && newTable?.tableIsExact == true)) the table is a table of Samsung's own with the same cells, its heading bold")
        say("\(verdict(newSticky?.sticky?.text == "An old one" && newSticky?.paper == StickyDocument.papers[3] && abs((newSticky?.rect.minX ?? 0) - 80) < 0.01)) the sticky note is one of Samsung's own, saying the same, on the nearest paper, where the picture lay")
        say("\(verdict(session.text.text.objectIDs.contains(newTable?.id ?? "-") && !session.text.text.objectIDs.contains { olds.map(\.id).contains($0) })) and the text on screen holds the new table in the picture's place")
        await shot("m9b4-converted", 600)
        if let newSticky { session.removeSticky(newSticky.id); await pause(1200) }
        if let newTable { session.removePicture(newTable.id); await pause(1500) }

        // Over a bar of buttons that floats over the text the pointer is an arrow, not the text's I-beam.
        if let view = session.text.view, let host = view.window {
            let bars = find(BarShield.Shield.self, in: host.contentView)
            let inText = bars.filter { bar in
                let frame = bar.convert(bar.bounds, to: nil)
                return view.convert(view.visibleRect, to: nil).contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            say("\(verdict(bars.count >= 3)) the bars of buttons have a shield behind them (\(bars.count))")
            if let bar = inText.first ?? bars.first {
                let frame = bar.convert(bar.bounds, to: nil)
                let at = CGPoint(x: frame.midX, y: frame.midY)
                if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    NSCursor.iBeam.set()
                    view.mouseMoved(with: moved)
                    say("\(verdict(NSCursor.current == NSCursor.arrow)) over a bar the text view shows an arrow, not its I-beam (\(inText.isEmpty ? "bar beside the text" : "bar over the text"))")
                    NSCursor.iBeam.set()
                    bar.mouseMoved(with: moved)
                    say("\(verdict(NSCursor.current == NSCursor.arrow)) and the bar itself asks for an arrow")
                }
            }
        }
        EditorRemote.shared.tableSetup = true
        await pause(1200)
        if let sheet = NSApplication.shared.windows.first(where: { $0.isSheet }), let data = capture(sheet), let folder = Launch.value("--editor-check") {
            try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("m9b2-table-properties.png"))
        }
        EditorRemote.shared.tableSetup = false
        await pause(900)

        // A recording: a second of silence as a sound file.
        var wave = Data("RIFF".utf8)
        let rate: UInt32 = 8_000, count = rate
        func little<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        wave += little(UInt32(36 + count * 2)) + Data("WAVEfmt ".utf8) + little(UInt32(16)) + little(UInt16(1)) + little(UInt16(1)) + little(rate) + little(rate * 2) + little(UInt16(2)) + little(UInt16(16))
        wave += Data("data".utf8) + little(count * 2) + Data(count: Int(count) * 2)
        let sound = FileManager.default.temporaryDirectory.appendingPathComponent("Morning memo.wav")
        try? wave.write(to: sound)
        session.addRecording(from: sound)
        await pause(1800)
        let recordings = session.note?.document.recordings ?? []
        say("\(verdict(recordings.count == 1 && recordings.first?.title == "Morning memo" && abs((recordings.first?.seconds ?? 0) - 1) < 0.2)) a sound file is kept with the note as a recording: \(recordings.first?.title ?? "none"), \(RecordingDesk.clock(recordings.first?.seconds ?? 0))")
        files = (try? model.store.load(id))?.document.files.map(\.id) ?? []
        say("\(verdict(recordings.first?.file.map { files.contains($0) } == true)) its file is in the note's list of files")
        await shot("m9c-recording", 600)
        if let first = recordings.first {
            session.removeRecording(first.file ?? "")
            await pause(1500)
            say("\(verdict(session.note?.document.recordings.isEmpty == true)) and deleting the recording takes it out")
        }
        try? FileManager.default.removeItem(at: sound)

        // A PDF of two pages becomes two pages of the note.
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-check.pdf")
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        if let pdf = CGContext(pdfURL as CFURL, mediaBox: &box, nil) {
            for number in 1...2 {
                pdf.beginPDFPage(nil)
                pdf.setFillColor(CGColor(srgbRed: number == 1 ? 0.9 : 0.2, green: 0.5, blue: 0.3, alpha: 1))
                pdf.fill(CGRect(x: 60, y: 200, width: 300, height: 200))
                pdf.endPDFPage()
            }
            pdf.closePDF()
        }
        let pagesBefore = session.visiblePages, picturesBefore = floating().count
        var landed: Int?
        session.addPDF(pdfURL) { landed = $0 }
        await pause(4000)
        // As Samsung's clients keep them: pages of the PDF's shape that name the document and their page in it, not pictures.
        let pdfPages = (session.note?.document.pages ?? []).enumerated().filter { $0.element.pdf != nil }
        let placed = pdfPages.map(\.offset)
        let numbered: [Int?] = pdfPages.map { $0.element.pdf?.page }
        let shaped = pdfPages.allSatisfy { abs($0.element.height / max($0.element.width, 1) - 595.0 / 420) < 0.01 }
        let pdfAdded: Bool = session.visiblePages == pagesBefore + 2 && floating().count == picturesBefore && placed == [pagesBefore, pagesBefore + 1] && numbered == [0, 1] && shaped && landed == pagesBefore
        say("\(verdict(pdfAdded)) a PDF of two pages adds two pages of its shape, each showing its page of the document (\(pagesBefore) -> \(session.visiblePages) pages)")
        let pdfFile: String = session.note?.document.pages[safe: pagesBefore]?.pdf?.file ?? ""
        let pdfKept: Bool = !pdfFile.isEmpty && model.store.hasFile(session.noteID, pdfFile) && model.library.notes[session.noteID]?.unsentFiles?.contains(pdfFile) == true
        say("\(verdict(pdfKept)) the document is kept with the note, to be sent with it")
        // "Import PDF" makes a note of the document: its pages, and no page of the note's own in front of them.
        let notesBefore = Set(model.library.notes.keys)
        NoteFiles.importFiles([pdfURL], in: model)
        await pause(2500)
        let imported = Set(model.library.notes.keys).subtracting(notesBefore)
        let pdfNote: LoadedNote? = imported.first.flatMap { try? model.store.load($0) }
        let pdfNotePages: [Int?] = pdfNote?.document.pages.map { $0.pdf?.page } ?? []
        let pdfNoteShown: Int = pdfNote.map { NoteLayout.shownPageCount(of: $0.document) } ?? 0
        let pdfNoteTitle: String = model.library.notes[imported.first ?? ""]?.title ?? ""
        let pdfNoteRight: Bool = imported.count == 1 && pdfNotePages == [0, 1, nil] && pdfNoteTitle == "snotes-check" && pdfNoteShown == 2
        say("\(verdict(pdfNoteRight)) Import PDF makes a note named after the file, of the PDF's two pages")
        for id in imported { model.edits.deleteForever(id) }
        model.changed(sync: false)
        EditorRemote.shared.page = pagesBefore
        await shot("m9d-pdf-page", 1200)
        EditorRemote.shared.page = 0
        try? FileManager.default.removeItem(at: pdfURL)
        // Tidied away again for the checks that follow.
        session.removePage(session.visiblePages - 1)
        await pause(1500)
        session.removePage(session.visiblePages - 1)
        await pause(1500)
        say("\(verdict(session.visiblePages == pagesBefore)) and deleting those pages takes their pictures with them (\(floating().count) pictures left)")
    }

    /// A picture of every panel that floats over the window (a popover is a window of its own).
    @MainActor static func panelShot(_ name: String, to folder: URL?) {
        guard let folder else { return }
        for (index, panel) in NSApplication.shared.windows.filter({ $0.isVisible && String(describing: type(of: $0)).contains("Popover") }).enumerated() {
            if let data = capture(panel) { try? data.write(to: folder.appendingPathComponent("\(name)-panel\(index).png")) }
        }
    }

    @MainActor static func cropChecks(model: AppModel, session: NoteSession, object: String, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        let id = session.noteID
        func stored() -> NoteObject? { (try? model.store.load(id))?.document.floating.first { $0.id == object } }
        func shown() -> NoteObject? { session.note?.document.floating.first { $0.id == object } }
        guard let before = shown() else { say("FAIL: no picture to crop"); return }
        session.cropping = NoteSession.Cropping(id: object, lasso: false)
        await pause(900)
        guard let crop = find(CropNSView.self, in: window()?.contentView).first, let window = crop.window else { say("FAIL: cropping shows no crop view"); return }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: crop.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // The right side dragged in by a quarter, then the bottom by half.
        let whole = crop.whole
        let right = CGPoint(x: whole.maxX, y: whole.midY)
        if let down = event(.leftMouseDown, right) { NSApp.postEvent(down, atStart: false) }
        for step in 1...5 { if let move = event(.leftMouseDragged, CGPoint(x: right.x - whole.width * 0.05 * CGFloat(step), y: right.y)) { NSApp.postEvent(move, atStart: false) } }
        if let up = event(.leftMouseUp, CGPoint(x: right.x - whole.width * 0.25, y: right.y)) { NSApp.postEvent(up, atStart: false) }
        await pause(400)
        let bottom = CGPoint(x: whole.minX + whole.width * 0.375, y: whole.maxY)
        if let down = event(.leftMouseDown, bottom) { NSApp.postEvent(down, atStart: false) }
        for step in 1...5 { if let move = event(.leftMouseDragged, CGPoint(x: bottom.x, y: bottom.y - whole.height * 0.1 * CGFloat(step))) { NSApp.postEvent(move, atStart: false) } }
        if let up = event(.leftMouseUp, CGPoint(x: bottom.x, y: bottom.y - whole.height * 0.5)) { NSApp.postEvent(up, atStart: false) }
        await pause(500)
        await shot("m6-cropping", 400)
        say("\(verdict(abs(crop.crop.width - 0.75) < 0.02 && abs(crop.crop.height - 0.5) < 0.02)) dragging the right side and the bottom in keeps \(String(format: "%.2f x %.2f", crop.crop.width, crop.crop.height)) of the picture")
        crop.done?()
        await pause(1800)
        let after = shown(), kept = stored()
        say("\(verdict(session.cropping == nil)) Done ends the cropping")
        say("\(verdict(abs((after?.crop?.width ?? 0) - 0.75) < 0.02 && abs((after?.crop?.height ?? 0) - 0.5) < 0.02)) the picture shows that part: \(after?.crop.map { String(format: "%.2f, %.2f, %.2f x %.2f", $0.minX, $0.minY, $0.width, $0.height) } ?? "all of it")")
        say("\(verdict(abs((after?.rect.width ?? 0) - before.rect.width * 0.75) < 2 && abs((after?.rect.height ?? 0) - before.rect.height * 0.5) < 2)) and is that much smaller on the page (\(Int(before.rect.width)) x \(Int(before.rect.height)) -> \(Int(after?.rect.width ?? 0)) x \(Int(after?.rect.height ?? 0)) units)")
        say("\(verdict(kept?.crop != nil && abs((kept?.crop?.width ?? 0) - 0.75) < 0.02 && abs((kept?.rect.width ?? 0) - before.rect.width * 0.75) < 2)) the crop is stored with the note: \(kept?.crop.map { String(format: "%.2f, %.2f, %.2f x %.2f", $0.minX, $0.minY, $0.width, $0.height) } ?? "nothing stored")")
        func node() -> SamsungNotesKit.XMLNode? {
            guard let data = try? Data(contentsOf: model.store.directory(id).appendingPathComponent("note.xml")), let tree = try? XMLTree.parse(data) else { return nil }
            return tree.descendants("object").first { $0["id"] == object && $0["type"] != nil }
        }
        func corners(_ node: SamsungNotesKit.XMLNode?) -> String { node.map { "\($0["l"] ?? "?"),\($0["t"] ?? "?"),\($0["r"] ?? "?"),\($0["b"] ?? "?")" } ?? "none" }
        let pixels = corners(node()?.child("cropRect")), frame = node()?.child("imageOriginalRect").map { CGRect(x: $0.double("l") ?? 0, y: $0.double("t") ?? 0, width: ($0.double("r") ?? 0) - ($0.double("l") ?? 0), height: ($0.double("b") ?? 0) - ($0.double("t") ?? 0)) } ?? .zero
        say("\(verdict(pixels == "0,0,270,120")) as Samsung's clients keep it: the part in the file's pixels, left, top, right, bottom (\(pixels) of 360 x 240)")
        say("\(verdict(abs(frame.width - before.rect.width) < 2 && abs(frame.height - before.rect.height) < 2 && abs(frame.minX - (kept?.rect.minX ?? -99)) < 2)) with the frame the whole picture would have (\(Int(frame.width)) x \(Int(frame.height)) units)")
        let file = kept?.pictureFile.flatMap { (try? model.store.load(id))?.fileURL($0) }
        say("\(verdict(file.flatMap { try? Data(contentsOf: $0) } == testPicture())) the picture's file is untouched")
        await shot("m7-cropped", 500)
        // Cropping again starts from the whole picture.
        session.cropping = NoteSession.Cropping(id: object, lasso: false)
        await pause(900)
        if let again = find(CropNSView.self, in: window.contentView).first {
            say("\(verdict(abs(again.whole.width / max(again.whole.height, 1) - 1.5) < 0.03)) cropping again shows the whole picture (\(Int(again.whole.width)) x \(Int(again.whole.height)) points)")
            again.cancel?()
        }
        await pause(500)
        await tick()
        model.undoManagerForChecks?.undo()
        await pause(1500)
        await tick()
        say("\(verdict(shown()?.crop == nil && abs((shown()?.rect.width ?? 0) - before.rect.width) < 2)) undo shows all of it again")

        // A loop drawn on the picture cuts it out.
        session.cropping = NoteSession.Cropping(id: object, lasso: true)
        await pause(900)
        guard let lasso = find(CropNSView.self, in: window.contentView).first else { say("FAIL: the loop has no crop view"); return }
        let area = lasso.whole
        let centre = CGPoint(x: area.midX, y: area.midY), radius = min(area.width, area.height) * 0.36
        func on(_ angle: Double) -> CGPoint { CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle)) }
        func lassoEvent(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: lasso.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = lassoEvent(.leftMouseDown, on(0)) { NSApp.postEvent(down, atStart: false) }
        for step in 1...30 { if let move = lassoEvent(.leftMouseDragged, on(Double(step) * 2 * .pi / 36)) { NSApp.postEvent(move, atStart: false) } }
        await pause(400)
        await shot("m8-loop", 300)
        for step in 31...36 { if let move = lassoEvent(.leftMouseDragged, on(Double(step) * 2 * .pi / 36)) { NSApp.postEvent(move, atStart: false) } }
        if let up = lassoEvent(.leftMouseUp, on(0)) { NSApp.postEvent(up, atStart: false) }
        await pause(1800)
        let cut = shown(), cutStored = stored()
        say("\(verdict(cut?.crop != nil && session.cropping == nil)) a loop drawn on the picture cuts it out along the loop")
        say("\(verdict(abs((cut?.rect.width ?? 0) - (cut?.rect.height ?? -9)) < 6)) what is left is as wide as it is high, like the loop (\(Int(cut?.rect.width ?? 0)) x \(Int(cut?.rect.height ?? 0)) units)")
        let source = before.pictureFile ?? ""
        let made = cutStored?.imageID.flatMap { (try? model.store.load(id))?.fileURL($0) }.flatMap { try? Data(contentsOf: $0) }
        let clear = made.flatMap { NSBitmapImageRep(data: $0) }.map { $0.hasAlpha && ($0.colorAt(x: 2, y: 2)?.alphaComponent ?? 1) == 0 && ($0.colorAt(x: $0.pixelsWide / 2, y: $0.pixelsHigh / 2)?.alphaComponent ?? 0) == 1 } ?? false
        say("\(verdict(cutStored?.originalImageID == source && cutStored?.imageID != source && cutStored?.crop != nil)) the note keeps it as Samsung's clients do: a cut-out copy is shown, the first picture is kept as its original")
        say("\(verdict(clear)) the copy is clear outside the loop and whole inside it")
        say("\(verdict(node()?["originalImageId"] == source && node()?["isTransparency"] == "True" && node()?.child("cropRect") != nil)) with originalImageId, isTransparency and a cropRect for the loop's box (\(corners(node()?.child("cropRect"))))")
        let listed = (try? model.store.load(id))?.document.files.map(\.id) ?? []
        say("\(verdict(listed.contains(source) && listed.contains(cutStored?.imageID ?? "-"))) both files are in the note's list of files")
        await shot("m9-cut-out", 600)
        // Its menu's Crop, then "Show Whole Picture", brings all of it back.
        session.cropPicture(object, crop: nil, restore: true, rect: before.rect, page: before.pageIndex ?? 0)
        await pause(1500)
        let back = stored()
        say("\(verdict(back?.isCropped == false && back?.imageID == source && back?.originalImageID == nil)) showing the whole picture again brings the first picture back and takes the crop out of the note")
        let left = (try? model.store.load(id))?.document.files.map(\.id) ?? []
        say("\(verdict(left.contains(source) && left.count == 1)) and the cut-out copy is no longer among the note's files (\(left.count) listed)")
        await tick()
        model.undoManagerForChecks?.undo()
        await pause(1800)
        await tick()
        say("\(verdict(stored()?.originalImageID == source && stored()?.crop != nil)) undo brings the cut-out back")
        model.undoManagerForChecks?.undo()
        await pause(1800)
        await tick()
        say("\(verdict(stored()?.isCropped == false && stored()?.imageID == source)) and undo once more the whole picture")
    }

    @MainActor static func styleChecks(model: AppModel, session: NoteSession, shot: @MainActor (String, Int) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        let id = session.noteID
        func pages() -> [NotePage] { (try? model.store.load(id))?.document.pages ?? [] }
        let folder = Launch.value("--editor-check").map { URL(fileURLWithPath: $0) }
        EditorRemote.shared.style = true
        await pause(1200)
        panelShot("m10-style-page", to: folder)
        EditorRemote.shared.style = false
        await pause(500)
        session.setPaperColor(0xFFFF_E984)
        await pause(1500)
        say("\(verdict(!pages().isEmpty && pages().allSatisfy { $0.background == 0xFFFF_E984 })) a paper colour is given to every page of the note, the spare one too (\(pages().count) pages)")
        session.setTemplate(.gridMedium, page: nil)
        await pause(1500)
        say("\(verdict(!pages().isEmpty && pages().allSatisfy { $0.template == .gridMedium })) a template for all pages is stored on every page")
        await shot("m11-yellow-squares", 700)
        // Lined paper: the text sits on the lines, one line of text to each ruled line.
        session.setPaperColor(PaperColors.plain)
        session.setTemplate(.lineNarrow, page: nil)
        EditorRemote.shared.pages = true
        await pause(1800)
        if let view = find(NoteTextView.self, in: window()?.contentView).first, let layout = view.layoutManager, let controller = view.controller, layout.numberOfGlyphs > 0 {
            var first = NSRange(), second = NSRange()
            let one = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &first)
            let two = NSMaxRange(first) < layout.numberOfGlyphs ? layout.lineFragmentRect(forGlyphAt: NSMaxRange(first), effectiveRange: &second) : one
            let step = (two.minY - one.minY) / max(controller.metrics.scale, 0.01)
            say("\(verdict(abs(step - PageTemplate.lineNarrow.pitch) < 0.4)) lines of text are as far apart as the narrow ruling: \(String(format: "%.2f", step)) units to the ruling's \(PageTemplate.lineNarrow.pitch)")
        }
        await shot("m11b-lined", 700)
        EditorRemote.shared.pages = false
        session.setPaperColor(0xFFFF_E984)
        session.setTemplate(.gridMedium, page: nil)
        await pause(1500)
        session.setTemplate(.oxford, page: 0)
        await pause(1500)
        say("\(verdict(pages().first?.template == .oxford && pages().dropFirst().allSatisfy { $0.template == .gridMedium })) a template for one page is stored on that page only")
        session.setPaperColor(0xFF00_0000)
        await pause(1500)
        await shot("m12-black-ruled", 700)
        session.setPaperColor(PaperColors.plain)
        session.setTemplate(.blank, page: nil)
        await pause(1500)
        say("\(verdict(pages().allSatisfy { $0.template == nil && $0.background == PaperColors.plain })) Blank and the plain colour take them off again")
        if let png = testPicture(), let file = PictureFile(data: png) {
            session.setTemplate(picture: file, page: 0)
            await pause(1800)
            let first = pages().first
            say("\(verdict(first?.backgroundImage != nil && (try? model.store.load(id))?.fileURL(first?.backgroundImage ?? "") != nil)) a picture of one's own lies under the first page, and its file is kept with the note")
            await shot("m13-own-paper", 700)
            session.setTemplate(.blank, page: nil)
            await pause(1500)
            say("\(verdict(pages().first?.backgroundImage == nil)) and Blank takes it away again")
        }
        if let file = try? Data(contentsOf: model.store.directory(id).appendingPathComponent("note.xml")), let tree = try? XMLTree.parse(file) {
            let note = tree.name == "NoteResource" ? tree : (tree.descendant("NoteResource") ?? tree)
            say("\(verdict(note.child("noteTree").map(NoteHash.verify) == true)) every hash in the note's tree holds after all of this")
        }

        // The pages one at a time, and two at a time.
        session.addPage(after: session.visiblePages - 1)
        await pause(1500)
        EditorRemote.shared.scroll = .horizontal
        await pause(1200)
        let one = find(NoteTextView.self, in: window()?.contentView).count
        await shot("m14-horizontal", 600)
        EditorRemote.shared.page = 1
        await pause(1000)
        await shot("m15-horizontal-page2", 600)
        say("\(verdict(one == 1)) shown a page at a time, the note still has its one text view")
        EditorRemote.shared.page = 0
        EditorRemote.shared.scroll = .twoPage
        await pause(1500)
        await shot("m16-two-pages", 700)
        EditorRemote.shared.scroll = .vertical
        await pause(900)
        say("\(verdict(find(NoteTextView.self, in: window()?.contentView).count == 1)) and back to scrolling down the pages")
    }
}
