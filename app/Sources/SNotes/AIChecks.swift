import AppKit
import SamsungNotesKit

extension EditorChecks {
    /// Calculations answered as they are typed, and text written to order by the Mac's own
    /// language model (which this check really asks, so it needs Apple Intelligence switched on).
    @MainActor static func aiChecks(model: AppModel, shot: @MainActor (String) async -> Void) async {
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func verdict(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
        model.path = []
        await pause(500)
        model.createNote()
        await pause(2000)
        guard let id = model.path.last, let session = NoteSession.live.object(forKey: id as NSString), let view = session.text.view else { say("FAIL: no note to type in"); return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        await pause(400)
        let text = session.text
        func type(_ string: String) async {
            for character in string { view.insertText(String(character), replacementRange: view.selectedRange()); await pause(15) }
            await pause(250)
        }
        func line(_ index: Int) -> String { text.text.string.components(separatedBy: "\n")[safe: index] ?? "" }
        func isResult(_ offset: Int) -> Bool { text.text.property(NoteText.foreground, at: offset) == TextController.resultValue }

        // A sum typed with its "=" is answered where it stands, in the colour of results.
        await type("10+5=")
        say("\(verdict(line(0) == "10+5=15" && isResult(5) && isResult(6) && !isResult(4))) typing 10+5= writes the answer after it: \(line(0))")
        say("\(verdict(view.selectedRange().location == 7)) and the caret stands after the answer")
        // What is typed after the answer is ordinary text, not part of it.
        await type(" apples")
        say("\(verdict(line(0) == "10+5=15 apples" && !isResult(8) && isResult(6))) what is typed after the answer is ordinary text")
        // A changed calculation changes its answer.
        await type("\n2+2=")
        let second = (text.text.string as NSString).range(of: "2+2=4")
        say("\(verdict(second.location != NSNotFound && line(1) == "2+2=4")) a second line is answered too: \(line(1))")
        view.setSelectedRange(NSRange(location: second.location + 1, length: 0))
        await type("0")
        say("\(verdict(line(1) == "20+2=22")) changing the calculation changes its answer: \(line(1))")
        // Names given a value earlier in the note are known.
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        await type("\nwidth = 12\nwidth * 3=")
        say("\(verdict(line(3) == "width * 3=36")) a name given a value above is known: \(line(3))")
        // Plain prose with a sign in it is left alone.
        await type("\nname=")
        say("\(verdict(line(4) == "name=")) a line that is no calculation is left as it is")
        await shot("a1-calculations")
        await pause(700)
        session.saveNow()
        await pause(900)
        let stored = (try? model.store.load(id))?.document.body.plain ?? ""
        say("\(verdict(stored.contains("10+5=15 apples") && stored.contains("20+2=22"))) the answers are part of the note as it is stored")

        guard NoteIntelligence.unavailable == nil else { say("     (Apple Intelligence is not available here: \(NoteIntelligence.unavailable ?? ""); the rest was not tried)"); return }
        // A calculation in words is read by the language model and worked out here.
        await type("\n15% of 240=")
        for _ in 0..<80 where line(5) == "15% of 240=" { await pause(250) }
        say("\(verdict(line(5) == "15% of 240=36")) a calculation in words is answered with the model's help: \(line(5))")

        // The toolbar has the button; its panel writes to order.
        await type("\n")
        await pause(500)
        let toolbarButton = window()?.toolbar?.items.contains { $0.label == "Write with AI" } == true
        say("\(verdict(toolbarButton && model.writesWithAI)) the toolbar has the button to write with AI")
        await shot("a2-write-button")
        let writer = NoteWriter()
        writer.write("Write one short sentence about the sea.", title: session.title, before: text.text.plain)
        for _ in 0..<240 where writer.isWriting || writer.draft.isEmpty { await pause(250); if writer.problem != nil { break } }
        let draft = writer.draft
        say("\(verdict(!draft.isEmpty && writer.problem == nil && draft.count > 15)) asked for a sentence, the model writes one (\(draft.count) characters)\(writer.problem.map { ": " + $0 } ?? "")")
        window()?.makeKeyAndOrderFront(nil)
        session.writerOpen = true
        await pause(800)
        let panelShown = NSApp.windows.contains { $0.isVisible && NSStringFromClass(Swift.type(of: $0)).contains("Popover") }
        say("\(verdict(panelShown)) the toolbar button's panel opens")
        await shot("a3-write-panel")
        session.writerOpen = false
        let at = text.selection.lowerBound
        text.insert(draft, at: at, name: "Write with AI")
        await pause(600)
        say("\(verdict(!draft.isEmpty && text.text.plain.contains(draft))) and Insert puts it into the note at the caret")
        session.undoManager?.undo()
        await pause(600)
        say("\(verdict(!draft.isEmpty && !text.text.plain.contains(draft))) one Undo takes it out again")
    }
}
