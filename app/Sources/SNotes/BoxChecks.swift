import AppKit
import SamsungNotesKit

extension EditorChecks {
    /// Text boxes: set down, written in where they stand, grown, moved, given a size, deleted and brought back.
    @MainActor static func boxChecks(model: AppModel, shot: @MainActor (String) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        model.path = []
        await pause(500)
        model.createNote()
        await pause(2000)
        guard let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString), let body = session.text.view else { say("FAIL: no note to put a text box in"); return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        body.window?.makeKeyAndOrderFront(nil)
        body.window?.makeFirstResponder(body)
        await pause(300)
        for character in "The note itself" { body.insertText(String(character), replacementRange: body.selectedRange()) }
        await pause(300)
        func editor() -> TextBoxEditor.View? { window().flatMap { find(TextBoxEditor.View.self, in: $0.contentView).first } }
        func ask(_ action: EditorRemote.BoxAction) async {
            EditorRemote.shared.boxAction = action
            EditorRemote.shared.boxStep += 1
            await pause(700)
            await tick()
        }
        func type(_ string: String) async {
            guard let view = editor() else { return }
            for character in string { view.insertText(String(character), replacementRange: view.selectedRange()) }
            await pause(300)
        }
        /// The boxes as they are stored, read anew from the note's file.
        func stored() -> [NoteObject] { (try? model.store.load(id))?.document.pages.flatMap { $0.objects.filter { $0.kind == .textBox } } ?? [] }
        let pageWidth = session.note?.document.pages.first?.width ?? 0

        // The keyboard's panel has the button; a new box opens to be written in, and is not in the note yet.
        EditorRemote.shared.drawing = false
        EditorRemote.shared.panel = true
        await ask(.new)
        let opened = editor() != nil
        say("\(verdict(opened && session.textBoxIDs.isEmpty)) a new text box opens to be written in, and is not in the note until something is written")
        await shot("b1-new-box")
        await ask(.done)
        let none = stored().isEmpty && editor() == nil
        say("\(verdict(none)) one left empty is not kept")

        await ask(.new)
        await type("Hello box")
        await ask(.done)
        await pause(600)
        let first = stored()
        let one = first.first
        let third = abs((one?.rect.width ?? 0) - (pageWidth / 3).rounded()) < 1
        say("\(verdict(first.count == 1 && one?.text?.plain == "Hello box" && third && one?.growsWithText == true)) what is written is stored as a text box of the page, a third of the page wide (\(Int(one?.rect.width ?? 0)) × \(Int(one?.rect.height ?? 0)))")
        let own = (try? model.store.load(id))?.document.body.plain.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        say("\(verdict(own == "The note itself")) and the note's own text is as it was (\(own.prefix(30)))")
        guard let box = one?.id else { say("FAIL: no text box was stored"); return }
        let grips = window().map { find(PictureGripView.self, in: $0.contentView).filter(\.box) } ?? []
        say("\(verdict(grips.count == 1 && editor() == nil)) the box on the page has its own handles")
        await shot("b2-box-on-page")

        // Opened again, it says what it said; more lines make it higher.
        await ask(.begin(box))
        let again = editor()?.string ?? ""
        await type("\nsecond\nthird\nfourth")
        await shot("b3-box-open")
        await ask(.done)
        await pause(600)
        let taller = stored().first
        say("\(verdict(again == "Hello box" && taller?.text?.plain == "Hello box\nsecond\nthird\nfourth" && (taller?.rect.height ?? 0) > (one?.rect.height ?? 0) + 20)) opened again and written on, it grows with its lines (\(Int(one?.rect.height ?? 0)) → \(Int(taller?.rect.height ?? 0)))")

        // Moved, then given a size by hand: it keeps that size.
        let was = taller?.rect ?? .zero
        await tick()
        session.changeTextBox(box, rect: was.offsetBy(dx: 120, dy: 200), name: "Move Text Box")
        await tick()
        await pause(600)
        let moved = stored().first?.rect ?? .zero
        say("\(verdict(abs(moved.minX - was.minX - 120) < 1 && abs(moved.minY - was.minY - 200) < 1)) moved, it is stored where it was put")
        session.changeTextBox(box, rect: CGRect(x: moved.minX, y: moved.minY, width: 400, height: moved.height + 60), grows: false, name: "Resize Text Box")
        await tick()
        await pause(600)
        let sized = stored().first
        say("\(verdict(sized?.growsWithText == false && abs((sized?.rect.width ?? 0) - 400) < 1)) given a size by hand, it is stored as one that keeps its size")
        await shot("b4-box-sized")
        session.undoManager?.undo()
        await tick()
        await pause(600)
        let unsized = stored().first
        say("\(verdict(unsized?.growsWithText == true && abs((unsized?.rect.width ?? 0) - was.width) < 1)) Undo gives it its size back (\(Int(unsized?.rect.width ?? 0)), grows \(unsized?.growsWithText == true))")

        // Emptied, it is taken off the page; Undo brings it back saying what it said.
        await ask(.begin(box))
        if let view = editor() { view.selectAll(nil); view.insertText("", replacementRange: view.selectedRange()) }
        await pause(200)
        await ask(.done)
        await pause(600)
        let gone = stored().isEmpty
        session.undoManager?.undo()
        await pause(700)
        let back = stored().first
        say("\(verdict(gone && back?.id == box && back?.text?.plain == "Hello box\nsecond\nthird\nfourth")) emptied, it is taken off the page, and Undo brings it back (gone \(gone), back \(back?.text?.plain.count ?? -1))")
        await shot("b5-box-back")
    }
}
