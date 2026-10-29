import AppKit
import SamsungNotesKit
import SwiftUI

/// Text boxes: a frame of text set down anywhere on a page, apart from the note's own text,
/// as the Windows client's keyboard tool makes them. Each is an object of its page.
extension NoteSession {
    /// A text box of the note, and the page it lies on.
    func textBoxObject(_ id: String) -> (object: NoteObject, page: Int)? {
        for (index, page) in (note?.document.pages ?? []).enumerated() {
            if let found = page.objects.first(where: { $0.kind == .textBox && $0.id == id }) { return (found, index) }
        }
        return nil
    }

    var textBoxIDs: [String] { (note?.document.pages ?? []).flatMap { $0.objects.filter { $0.kind == .textBox }.map(\.id) } }

    /// What a box says, set as it was: in the look of its first letters, or as a new box's text.
    private static func boxText(_ text: String, like old: RichText?) -> RichText? {
        guard !text.isEmpty else { return nil }
        if var run = old?.runs.first {
            run.text = text
            return RichText(runs: [run])
        }
        return RichText(NoteText.uniform(text, like: nil, body: true))
    }

    private static func kept(_ rect: CGRect, on sheet: NotePage) -> CGRect {
        var placed = rect
        placed.size.width = min(placed.width, sheet.width)
        placed.origin.x = min(max(placed.minX, 0), max(sheet.width - placed.width, 0))
        placed.origin.y = min(max(placed.minY, 0), max(sheet.height - placed.height, 0))
        return placed
    }

    /// The room a new text box takes: a third of the page wide and two lines high, near the top
    /// left corner of what is in view of the page the note is at.
    func newTextBoxPlace(viewTop: Double) -> (page: Int, rect: CGRect)? {
        guard let document = note?.document, let layout = text.pages, layout.pageCount > 0 else { return nil }
        let unit = text.metrics.unit
        let step = layout.pageWidth / 360 * 10
        let page = min(max(layout.page(at: max(viewTop, 0) * unit + step * 2), 0), min(layout.pageCount, document.pages.count) - 1)
        guard let sheet = document.pages[safe: page] else { return nil }
        let width = (sheet.width / 3).rounded()
        let height = NoteFile.textBoxHeight("", width: width, pageWidth: sheet.width)
        var origin = CGPoint(x: step, y: max(viewTop * unit - layout.top(page), 0) + step)
        // Not on top of one that already lies there.
        while sheet.objects.contains(where: { $0.kind == .textBox && abs($0.rect.minX - origin.x) < step && abs($0.rect.minY - origin.y) < step }), origin.y + height + step * 2 < sheet.height {
            origin.x += step * 2
            origin.y += step * 2
        }
        return (page, NoteSession.kept(CGRect(origin: origin, size: CGSize(width: width, height: height)), on: sheet))
    }

    /// Sets a text box down on a page. Returns its id.
    @discardableResult
    func addTextBox(page: Int, rect: CGRect, text: String, grows: Bool = true, id: String = UUID().uuidString.lowercased()) -> String? {
        guard canEdit, var note, let sheet = note.document.pages[safe: page], !text.isEmpty else { return nil }
        let placed = NoteSession.kept(rect, on: sheet)
        var object = NoteObject(id: id, kind: .textBox, rawType: "textBox", rect: placed, pageIndex: page)
        object.text = NoteSession.boxText(text, like: nil)
        object.margins = NoteFile.textBoxMargins
        object.growsWithText = grows
        note.document.pages[page].objects.append(object)
        self.note = note
        bump(page)
        pictureRevision += 1
        let noteID = noteID
        write("The text box could not be added.") { edits in
            if try edits.addTextBox(noteID, page: page, rect: placed, text: text, id: id, sized: !grows) == nil { throw CocoaError(.fileWriteUnknown) }
        }
        undoManager?.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.removeTextBox(id) } }
        undoManager?.setActionName("Add Text Box")
        return id
    }

    /// Gives a text box what it now says, where it now lies, or both. `grows` false: the user
    /// gave it its size, and it keeps it.
    func changeTextBox(_ id: String, text: String? = nil, rect: CGRect? = nil, page: Int? = nil, grows: Bool? = nil, name: String = "Edit Text Box") {
        guard canEdit, var note, let found = textBoxObject(id) else { return }
        let target = page ?? found.page
        guard let sheet = note.document.pages[safe: target] else { return }
        let old = found.object
        let oldText = old.text?.plain ?? ""
        var object = old
        if let text { object.text = NoteSession.boxText(text, like: old.text) }
        if let rect { object.rect = NoteSession.kept(rect, on: sheet) }
        if let grows { object.growsWithText = grows }
        let changedText = text != nil && text != oldText
        guard changedText || object.rect != old.rect || target != found.page || object.growsWithText != old.growsWithText else { return }
        if target == found.page, let index = note.document.pages[target].objects.firstIndex(where: { $0.kind == .textBox && $0.id == id }) {
            note.document.pages[target].objects[index] = object
        } else {
            note.document.pages[found.page].objects.removeAll { $0.kind == .textBox && $0.id == id }
            note.document.pages[target].objects.append(object)
        }
        self.note = note
        bump(found.page); bump(target)
        pictureRevision += 1
        let noteID = noteID, placed = object.rect, sized = !object.growsWithText
        write("The text box could not be changed.") { edits in
            try edits.setTextBox(noteID, id: id, text: changedText ? text : nil, rect: placed, page: target, sized: sized)
        }
        let oldRect = old.rect, oldPage = found.page, oldGrows = old.growsWithText
        undoManager?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.changeTextBox(id, text: changedText ? oldText : nil, rect: oldRect, page: oldPage, grows: oldGrows, name: name) }
        }
        undoManager?.setActionName(name)
    }

    func removeTextBox(_ id: String) {
        guard canEdit, var note, let found = textBoxObject(id) else { return }
        note.document.pages[found.page].objects.removeAll { $0.kind == .textBox && $0.id == id }
        self.note = note
        bump(found.page)
        pictureRevision += 1
        if pictureSelection == id { pickPicture(nil) }
        let noteID = noteID
        write("The text box could not be removed.") { edits in try edits.removeTextBox(noteID, id: id) }
        let old = found.object, page = found.page
        undoManager?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { _ = session.addTextBox(page: page, rect: old.rect, text: old.text?.plain ?? "", grows: old.growsWithText, id: id) }
        }
        undoManager?.setActionName("Delete Text Box")
    }

    /// While a box is being written in, the page under it is drawn without its text: the
    /// letters on screen are the editor's. `nil` puts the text back.
    func hideTextBoxText(_ id: String?) {
        if let was = hiddenTextBox, was.id != id {
            hiddenTextBox = nil
            setBoxText(was.id, was.text)
        }
        guard let id, hiddenTextBox == nil, let found = textBoxObject(id) else { return }
        hiddenTextBox = (id, found.object.text)
        setBoxText(id, nil)
    }

    /// After the note was read anew: what is being written in is taken off the page again.
    func hideOpenTextBoxAgain() {
        guard let was = hiddenTextBox else { return }
        guard let found = textBoxObject(was.id) else { hiddenTextBox = nil; return }
        hiddenTextBox = (was.id, found.object.text)
        setBoxText(was.id, nil, bumping: false)
    }

    private func setBoxText(_ id: String, _ text: RichText?, bumping: Bool = true) {
        guard var note else { return }
        for page in note.document.pages.indices {
            guard let index = note.document.pages[page].objects.firstIndex(where: { $0.kind == .textBox && $0.id == id }) else { continue }
            note.document.pages[page].objects[index].text = text
            self.note = note
            if bumping { bump(page) }
            return
        }
    }
}

/// A text box that is being written in, where it stands.
struct BoxLive: Equatable {
    var id: String
    var page: Int
    /// Its frame, in its page's units.
    var rect: CGRect
    var text: String
    var original: String
    /// It grows downwards with what is written in it.
    var grows = true
    /// Not in the note yet: it is put there when something has been written in it.
    var isNew = false
    /// The size and colour of its letters.
    var fontSize = NoteFile.textBoxFontSize
    var color: UInt32 = 0xFF25_2525
    var bold = false
    var italic = false
}

/// The letters of a text box while they are written: a text view of its own, laid over the
/// box's place, with the margins and the lines of the box as it is drawn.
struct TextBoxEditor: NSViewRepresentable {
    @Binding var text: String
    /// Points on screen per unit of text size.
    let scale: CGFloat
    let fontSize: Double
    let color: NSColor
    var bold = false
    var italic = false
    let done: () -> Void

    final class View: NSTextView {
        var done: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                window.makeFirstResponder(self)
                self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
            }
            // A press anywhere else ends the writing; the press itself goes where it was going.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, event.window === self.window, !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.done?() }
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            super.viewWillMove(toWindow: newWindow)
        }

        override func cancelOperation(_ sender: Any?) { done?() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextBoxEditor
        init(_ parent: TextBoxEditor) { self.parent = parent }
        /// What is typed in the box is undone in the box, while it is open: the note's own
        /// list of changes gets the box's change as one, when the writing is done.
        let undo = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { undo }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private var attributes: [NSAttributedString.Key: Any] {
        let size = CGFloat(fontSize) * scale
        var font = NSFont.systemFont(ofSize: size)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty, let styled = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) { font = styled }
        // From one line to the next is 1.35 times the letters' size, as the box is drawn.
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = size * 1.35
        paragraph.maximumLineHeight = size * 1.35
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.setAccessibilityLabel("Text box")
        view.string = text
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        context.coordinator.parent = self
        view.done = done
        view.textContainerInset = NSSize(width: NoteFile.textBoxMargins.left * scale, height: NoteFile.textBoxMargins.top * scale)
        let attributes = attributes
        view.typingAttributes = attributes
        view.insertionPointColor = color
        if view.string != text { view.string = text }
        if let storage = view.textStorage, storage.length > 0 { storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length)) }
    }
}
