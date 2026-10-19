import AVFoundation
import AppKit
import SamsungNotesKit
import UniformTypeIdentifiers

/// The things the Insert menu puts into a note, and the note's paper.
extension NoteSession {
    // MARK: PDF

    /// Adds the pages of a PDF to the note as pages of the note, after the pages it has: each
    /// shows its page of the document under what is written on it, as in Samsung's clients.
    /// `then` gets the first of the new pages.
    func addPDF(_ url: URL, then done: @escaping @MainActor (Int?) -> Void) {
        guard canEdit, note != nil else { return }
        saveNow()
        let id = noteID
        let last = visiblePages - 1
        // A note with nothing in it yet takes the PDF in the place of the page it has.
        let empty = visiblePages == 1 && !pageHoldsSomething(0) && text.text.isEmpty
        let first = Box<Int?>(nil), added = Box(0)
        undoManager?.removeAllActions(withTarget: self)
        structural("Insert PDF", "The PDF could not be added.", { edits in
            let made = try edits.addPDFPages(id, pdf: try Data(contentsOf: url), at: empty ? 0 : last + 1, replacing: empty)
            first.value = made.first
            added.value = empty ? made.count - 1 : made.count
        }, then: { [weak self] in
            guard let self else { return }
            self.revealedTo = self.visiblePages + added.value
            Task {
                await self.load(text: false)
                done(first.value)
            }
        })
    }

    // MARK: Paper

    /// The colour of the note's paper: every page gets it, as in the original.
    func setPaperColor(_ argb: UInt32) {
        guard canEdit, var note else { return }
        for index in note.document.pages.indices { note.document.pages[index].background = argb }
        self.note = note
        for page in pageRevisions.indices { bump(page) }
        text.forgetPictures()
        setPaper(.color(argb), page: nil)
    }

    /// A ruling for one page, or with `page` nil for every page. `.blank` takes the ruling, and
    /// a picture that lay under the page, away.
    func setTemplate(_ template: PageTemplate, page: Int?) {
        guard canEdit, var note else { return }
        for index in note.document.pages.indices where page == nil || page == index {
            note.document.pages[index].template = template == .blank ? nil : template
            note.document.pages[index].backgroundImage = nil
        }
        self.note = note
        for page in pageRevisions.indices { bump(page) }
        setPaper(.template(template), page: page)
    }

    /// A picture of one's own to lie under one page, or under every page.
    func setTemplate(picture file: PictureFile, page: Int?) {
        guard canEdit else { return }
        setPaper(.picture(data: file.data, fileExtension: file.fileExtension), page: page)
    }

    private func setPaper(_ paper: LocalEdits.PaperChange, page: Int?) {
        let id = noteID
        // The empty pages kept out of sight at the end follow the last page shown, so that
        // they stay its spare pages and stay out of sight.
        var pages: Set<Int>? = page.map { [$0] }
        if let page, page == visiblePages - 1, let count = note?.document.pages.count, count > visiblePages { pages?.formUnion(visiblePages..<count) }
        _ = page
        structural("Change Paper", "The note's style could not be changed.", { edits in try edits.setPaper(id, paper, pages: pages) })
    }
}

extension NoteSession {
    // MARK: Recordings

    func startRecording() {
        guard canEdit else { return }
        recordings.record()
    }

    /// Ends the recording under way and keeps it with the note.
    func stopRecording() {
        guard let done = recordings.finish() else { return }
        addRecording(from: done.url, seconds: done.seconds, removeAfter: true)
    }

    /// Keeps a sound file with the note as a recording.
    func addRecording(from url: URL, seconds known: Double? = nil, removeAfter: Bool = false) {
        guard canEdit else { return }
        let id = noteID
        write("The recording could not be added.", { edits in
            let data = try Data(contentsOf: url)
            // The sound's own length, when the file says it.
            let length = known ?? (try? AVAudioPlayer(data: data))?.duration ?? 0
            let type = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
            try edits.addRecording(id, data: data, fileExtension: type, title: removeAfter ? nil : url.deletingPathExtension().lastPathComponent, seconds: length)
            if removeAfter { try? FileManager.default.removeItem(at: url) }
        }, then: { [weak self] in
            guard let self else { return }
            Task { await self.load(text: false) }
        })
    }

    /// Takes a recording out of the note: `id` is its sound file's hash. Of two recordings of
    /// the same sound, one goes.
    func removeRecording(_ id: String) {
        guard canEdit else { return }
        let note = noteID
        write("The recording could not be removed.", { edits in try edits.removeRecording(note, fileHash: id) }, then: { [weak self] in
            guard let self else { return }
            Task { await self.load(text: false) }
        })
    }
}

extension NoteSession {
    // MARK: Tables

    /// Puts a new, empty table into the text at the caret: a table of Samsung's own kind, which
    /// every client shows and edits. Returns the id of its object.
    @discardableResult
    func addTable(rows: Int, columns: Int) -> String? {
        guard canEdit, let document = note?.document else { return nil }
        // The text on disk must be the text on screen before a table is set into it.
        saveNow()
        let id = UUID().uuidString.lowercased()
        let offset = min(max(text.selection.lowerBound, 0), text.text.length)
        let note = noteID
        write("The table could not be added.", { edits in
            _ = try edits.addTable(note, rows: rows, columns: columns, textOffset: offset, id: id)
        }, then: { [weak self] in
            guard let self else { return }
            Task { await self.load(text: false) }
        }, failed: { [weak self] error in
            guard let self else { return }
            self.fail("The table could not be added.", error)
            self.arriving[id] = nil
            self.text.removeObject(id)
        })
        // Its place is in the text on screen from this moment, with the room it will take.
        let column = TextColumn(document)
        let density = document.density
        arriving[id] = (nil, CGSize(width: column.width / density, height: Double(max(rows, 1)) * (15 * 1.35 + 8) + 20))
        text.insertObject(id, at: offset, tail: "3,2", name: "Insert Table")
        return id
    }

    /// Stores a table as it now is: its cells, their styles, its columns. Undo gives back what it was.
    func setTable(_ table: SamsungTable) {
        guard canEdit else { return }
        saveNow()
        let note = noteID
        var changed = table
        changed.touch()
        if var loaded = self.note, let index = loaded.document.floating.firstIndex(where: { $0.id == table.id }), let old = loaded.document.floating[index].table {
            undoManager?.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.setTable(old) } }
            undoManager?.setActionName("Edit Table")
            // In the note in memory at once, for the next change to start from.
            loaded.document.floating[index].table = changed
            loaded.document.floating[index].rect = changed.rect
            self.note = loaded
        }
        write("The table could not be changed.", { edits in
            if try !edits.setTable(note, table: changed) { throw CocoaError(.fileWriteUnknown) }
        }, then: { [weak self] in
            guard let self else { return }
            Task {
                await self.load(text: false)
                self.text.forgetPictures()
            }
        })
    }

    /// Gives a table what its cells now say, row by row, and which of them are bold or italic;
    /// rows and columns come and go with them.
    func changeTable(_ id: String, texts: [[String]], bold: [[Bool]]? = nil, italic: [[Bool]]? = nil) {
        guard canEdit else { return }
        saveNow()
        let note = noteID
        if var loaded = self.note, let index = loaded.document.floating.firstIndex(where: { $0.id == id }), let old = loaded.document.floating[index].table {
            // What it said before can be had back.
            let oldTexts = old.texts, oldBold = old.rows.map { $0.map(\.bold) }, oldItalic = old.rows.map { $0.map(\.italic) }
            undoManager?.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.changeTable(id, texts: oldTexts, bold: oldBold, italic: oldItalic) } }
            undoManager?.setActionName("Edit Table")
            // And what it says now is in the note in memory at once, for the next change to start from.
            let now = old.with(texts: texts, bold: bold, italic: italic)
            loaded.document.floating[index].table = now
            loaded.document.floating[index].rect = now.rect
            self.note = loaded
        }
        write("The table could not be changed.", { edits in
            if try !edits.setTable(note, id: id, texts: texts, bold: bold, italic: italic) { throw CocoaError(.fileWriteUnknown) }
        }, then: { [weak self] in
            guard let self else { return }
            Task {
                await self.load(text: false)
                self.text.forgetPictures()
            }
        })
    }
}
