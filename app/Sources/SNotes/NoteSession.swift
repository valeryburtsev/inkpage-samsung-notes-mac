import AppKit
import ImageIO
import SamsungNotesKit
import SwiftUI
import UniformTypeIdentifiers

/// Decoded pictures of one open note, shared by the page renders.
final class NoteImages: @unchecked Sendable {
    private let note: LoadedNote
    private var cache: [String: CGImage] = [:]
    private let lock = NSLock()
    init(note: LoadedNote) { self.note = note }

    func image(_ hash: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let image = cache[hash] { return image }
        let image = note.image(hash)
        cache[hash] = image
        return image
    }
}

/// What is picked on a page with the selection tool: strokes.
struct InkSelection: Equatable {
    var page: Int
    var strokes: Set<String> = []
    /// In the page's own units.
    var bounds: CGRect
    /// Text boxes and pictures placed freely on the page, picked with the handwriting by the pointer's rectangle.
    var objects: Set<String> = []
}

/// A picture ready to go into a note: the file as it will be kept, and its size in pixels.
struct PictureFile {
    var data: Data
    var fileExtension: String
    var pixels: CGSize

    /// Reads a picture from a file or from data in any format the system knows. Upright JPEG
    /// and PNG are kept as they are; anything else (HEIC, TIFF, a photo marked as taken
    /// sideways…) is drawn upright, at most 4096 pixels on its longer side, and kept as JPEG,
    /// or as PNG when it has see-through parts.
    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let type = CGImageSourceGetType(source).map { $0 as String } ?? ""
        // A photo taken sideways says so in its properties, which not every client heeds: such
        // a picture is drawn upright and kept that way, like one in another format.
        let upright = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1
        if upright, type == UTType.jpeg.identifier || type == UTType.png.identifier,
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue, let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, width > 0, height > 0 {
            self.init(data: data, fileExtension: type == UTType.jpeg.identifier ? "jpg" : "png", pixels: CGSize(width: width, height: height))
            return
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, (opaque ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, opaque ? [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        self.init(data: out as Data, fileExtension: opaque ? "jpg" : "png", pixels: CGSize(width: image.width, height: image.height))
    }

    init(data: Data, fileExtension: String, pixels: CGSize) {
        self.data = data; self.fileExtension = fileExtension; self.pixels = pixels
    }

    static let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    init?(pasteboard: NSPasteboard) {
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL])?.first, let data = try? Data(contentsOf: url) {
            self.init(data: data)
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: PictureFile.jpegType) ?? pasteboard.data(forType: .tiff) {
            self.init(data: data)
        } else {
            return nil
        }
    }
}

/// One open note: what is on screen of it, and the way every change made on screen gets to
/// the store. Changes show at once from memory; writing happens off the main thread, in order.
@MainActor @Observable
final class NoteSession {
    let noteID: String
    @ObservationIgnored let model: AppModel
    var note: LoadedNote?
    @ObservationIgnored private(set) var images: NoteImages?
    var failed = false
    /// One counter per page: a page is drawn again when its counter moves.
    var pageRevisions: [Int] = []
    /// Moves when pictures arrive or change, so the text shows them anew.
    var pictureRevision = 0
    var title = ""
    let text = TextController()
    /// What is picked of the text of a PDF under the note's pages.
    let pdfText = PDFTextSelection()
    /// The panel that writes text to order is open at the caret.
    var writerOpen = false
    @ObservationIgnored let recordings = RecordingDesk()
    var selection: InkSelection?
    /// The picture that is picked, set in the text or free on a page: it shows its handles.
    var pictureSelection: String?
    /// The text box being written in, and what it said: its page is drawn without its text meanwhile.
    @ObservationIgnored var hiddenTextBox: (id: String, text: RichText?)?
    /// Something the user should know, such as edits kept as a copy.
    var notice: String?
    var unlocked = false
    /// How many of the note's pages are on screen: up to the last that may hold anything (see
    /// `NoteLayout.shownPageCount`), and those added here. The note's last page is usually an
    /// empty spare, which Samsung's clients keep and do not show.
    var visiblePages = 1
    @ObservationIgnored var revealedTo = 0
    var canUndo = false
    var canRedo = false
    /// The bar for finding text in the note is open.
    var finding = false
    /// A picture being cropped: by a rectangle, or by a loop drawn on it.
    struct Cropping: Equatable {
        var id: String
        var lasso: Bool
    }
    var cropping: Cropping?

    @ObservationIgnored private var titleText = NoteText(hasSection: false)
    /// `LocalStore.arrivals` of the note when the text on screen was read from it.
    @ObservationIgnored private var loadedArrivals = 0
    /// Moves with every stroke drawn or erased: a read that started before is out of date.
    @ObservationIgnored private var inkEpoch = 0
    /// Pictures on their way into the note, shown before the note has been read again.
    @ObservationIgnored var arriving: [String: (image: CGImage?, size: CGSize)] = [:]
    @ObservationIgnored private var tableImages: [String: CGImage] = [:]
    @ObservationIgnored private let identity = UUID().uuidString
    @ObservationIgnored private var watch: NSObjectProtocol?
    static let written = Notification.Name("SNotesNoteWritten")
    @ObservationIgnored private var textDirty = false
    @ObservationIgnored private var titleDirty = false
    @ObservationIgnored private var saveSoon: Task<Void, Never>?
    @ObservationIgnored private var changedSoon: Task<Void, Never>?
    @ObservationIgnored private let queue = DispatchQueue(label: "snotes.note.write", qos: .userInitiated)
    @ObservationIgnored weak var undoManager: UndoManager? { didSet { if undoManager !== oldValue { watchUndo() } } }
    @ObservationIgnored private var undoWatch: [NSObjectProtocol] = []
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var reloadText: Bool?

    /// The open sessions by note id, for the scripted checks.
    static let live = NSMapTable<NSString, NoteSession>(keyOptions: .strongMemory, valueOptions: .weakMemory)

    init(noteID: String, model: AppModel) {
        self.noteID = noteID
        self.model = model
        NoteSession.live.setObject(self, forKey: noteID as NSString)
        text.onChange = { [weak self] in self?.textChanged() }
        text.onRelayout = { [weak self] in self?.refreshVisible() }
        text.onPointerDown = { [weak self] in self?.pickPicture(nil) }
        text.picture = { [weak self] id in self?.picture(object: id) ?? (nil, CGSize(width: 40, height: 40), 0, .zero) }
        text.onPastePicture = { [weak self] board, offset in
            guard let self, let file = PictureFile(pasteboard: board) else { return false }
            self.addPicture(file, at: offset)
            return true
        }
        // The same note open in another window: what is written there shows here.
        watch = NotificationCenter.default.addObserver(forName: NoteSession.written, object: nil, queue: .main) { [weak self] notice in
            let id = notice.userInfo?["note"] as? String, sender = notice.userInfo?["sender"] as? String
            MainActor.assumeIsolated {
                guard let self, id == self.noteID, sender != self.identity, self.note != nil else { return }
                Task { await self.load(text: true) }
            }
        }
    }

    /// The key this session's quit-time save is registered under: one per window on the note.
    var flushKey: String { noteID + "#" + identity }

    /// Called when the note leaves the screen: nothing of it stays on the undo stack.
    func close() {
        flush()
        if let undoManager {
            undoManager.removeAllActions(withTarget: self)
            undoManager.removeAllActions(withTarget: text)
        }
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
    }

    var record: NoteRecord? { model.library.notes[noteID] }
    var isTrashed: Bool { model.library.nodes[noteID]?.state == .trashed }
    var isLocked: Bool { record?.isLocked == true && !unlocked }
    var canEdit: Bool { note != nil && !isTrashed && !isLocked }

    // MARK: Loading

    private struct Loaded: @unchecked Sendable {
        var note: LoadedNote?
        var text: (title: NoteText, body: NoteText)?
        var arrivals: Int
    }

    /// Reads the note from the store. With `text` the title and text on screen are replaced
    /// too, unless something typed here is still unsaved.
    func load(text replaceText: Bool) async {
        // One read at a time: a request that comes while one is under way is done right after it.
        if loading {
            reloadText = (reloadText ?? false) || replaceText
            return
        }
        loading = true
        defer {
            loading = false
            if let again = reloadText {
                reloadText = nil
                Task { await self.load(text: again) }
            }
        }
        let store = model.store, edits = model.edits, id = noteID
        let epoch = inkEpoch
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Loaded, Never>) in
            // After the writes still under way, so what is read is what was last drawn or typed.
            queue.async {
                // The text and the number it is read under come in one piece; the pages after it,
                // so they are never older than the text.
                let text = edits.richTextAndArrivals(id)
                continuation.resume(returning: Loaded(note: try? store.load(id), text: text.map { ($0.title, $0.body) }, arrivals: text?.arrivals ?? store.arrivals(id)))
            }
        }
        // Something was drawn while the note was being read: what was read lacks it. Read again.
        guard epoch == inkEpoch else {
            reloadText = (reloadText ?? false) || replaceText
            return
        }
        let first = note == nil
        note = loaded.note
        hideOpenTextBoxAgain()
        pdfText.note = loaded.note
        text.pdf = pdfText
        // A press on a tape, with the keyboard in hand, opens or closes it.
        text.onPageClick = { [weak self] page, point in self?.toggleTape(at: point, page: page) ?? false }
        // A calculation put in words is read by the Mac's own language model, and worked out here.
        text.translate = { phrase in await NoteIntelligence.arithmetic(for: phrase) }
        text.calculates = model.mathResults
        images = loaded.note.map(NoteImages.init)
        failed = loaded.note == nil
        let count = loaded.note?.document.pages.count ?? 0
        pageRevisions = (0..<max(count, 1)).map { (pageRevisions[safe: $0] ?? 0) + 1 }
        pictureRevision += 1
        refreshVisible()
        var known = Set(loaded.note?.document.floating.map(\.id) ?? [])
        arriving = arriving.filter { !known.contains($0.key) }
        known.formUnion(stickyIDs)
        known.formUnion(textBoxIDs)
        if let selection, !(loaded.note?.document.pages.indices.contains(selection.page) ?? false) { self.selection = nil }
        if let picked = pictureSelection, !known.contains(picked) { pickPicture(nil) }
        if let cropped = cropping, !known.contains(cropped.id) { cropping = nil }
        guard let stored = loaded.text else { return }
        if first || (replaceText && !textDirty && !titleDirty) {
            loadedArrivals = loaded.arrivals
            titleText = stored.title
            title = stored.title.plain
            text.set(stored.body)
            textDirty = false
            titleDirty = false
        } else if !textDirty {
            // Saving may have tidied the text (numbers, a picture that is gone): show it as stored.
            text.adopt(stored.body)
            textDirty = false
            text.forgetPictures()
        } else {
            text.forgetPictures()
        }
    }

    /// The library changed: another device's version of this note may have arrived.
    func libraryChanged() {
        guard note != nil, model.library.notes[noteID] != nil else { return }
        guard model.store.arrivals(noteID) != loadedArrivals else { return }
        if textDirty || titleDirty {
            // What was typed here goes into a copy beside the newer version, then that version is shown.
            saveNow()
        } else {
            Task { await load(text: true) }
        }
    }

    private func picture(object id: String) -> (image: CGImage?, size: CGSize, rotation: Double, around: CGSize) {
        if let coming = arriving[id] { return (coming.image, coming.size, 0, .zero) }
        guard let note, let object = note.document.floating.first(where: { $0.id == id }) ?? note.document.allObjects.first(where: { $0.id == id }) else { return (nil, CGSize(width: 40, height: 40), 0, .zero) }
        let density = note.document.density
        let size = CGSize(width: object.rect.width / density, height: object.rect.height / density)
        if object.kind == .table {
            // A table is shown by a picture of itself, with the room Samsung's clients leave around one.
            let around = NoteRenderer.tableRoom(density)
            return (tableImage(object), size, 0, CGSize(width: around.width / density, height: around.height / density))
        }
        let images = images
        return (NoteRenderer.picture(of: object) { images?.image($0) }, size, object.rotation, .zero)
    }

    /// A table drawn as a picture, kept until the table or the look changes.
    func tableImage(_ object: NoteObject) -> CGImage? {
        guard let table = object.table else { return nil }
        let dark = text.metrics.dark
        let key = "\(table.id)|\(table.modified)|\(dark)|\(table.texts.hashValue)"
        if let known = tableImages[key] { return known }
        let made = NoteRenderer.tableImage(table, pixelWidth: 1800, dark: dark)
        if tableImages.count > 40 { tableImages = [:] }
        tableImages[key] = made
        return made
    }

    // MARK: Writing

    func fail(_ what: String, _ error: Error) {
        model.lastError = "\(what) \(AppModel.describe(error))"
    }

    /// Tells the rest of the app that the library changed, once for a burst of changes.
    private func announce() {
        changedSoon?.cancel()
        changedSoon = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.model.changed()
        }
    }

    /// Does a piece of writing in the background, in order. Afterwards, on the main thread:
    /// `then` when it worked; when it did not, the user is told and `failed` runs, or without
    /// one the note is read again so the screen shows what is really stored.
    func write(_ what: String, _ work: @escaping @Sendable (LocalEdits) throws -> Void, then: (@MainActor @Sendable () -> Void)? = nil, failed: (@MainActor @Sendable (Error) -> Void)? = nil) {
        let edits = model.edits
        queue.async { [weak self] in
            var failure: Error?
            do { try work(edits) } catch { failure = error }
            let problem = failure
            DispatchQueue.main.async {
                guard let self else { return }
                self.announce()
                if let problem {
                    if let failed { failed(problem) } else {
                        self.fail(what, problem)
                        Task { await self.load(text: false) }
                    }
                    return
                }
                NotificationCenter.default.post(name: NoteSession.written, object: nil, userInfo: ["note": self.noteID, "sender": self.identity])
                then?()
            }
        }
    }

    func bump(_ page: Int) {
        while pageRevisions.count <= page { pageRevisions.append(0) }
        pageRevisions[page] += 1
    }

    // MARK: Text

    private func textChanged() {
        textDirty = true
        refreshVisible()
        scheduleSave()
    }

    /// Works out how many pages to show: what the note's own pages and objects hold, where the
    /// text on screen ends, and the pages that were added here.
    func refreshVisible() {
        guard let document = note?.document else { return }
        var bottom: Double?
        if text.text.isEmpty {
            bottom = 0
        } else if let height = text.usedTextHeight {
            bottom = (document.bodyMargins.top + height) * document.density
        }
        let content = NoteLayout.shownPageCount(of: document, textBottom: bottom)
        let wanted = max(content, min(revealedTo, max(document.pages.count, 1)))
        if visiblePages != wanted { visiblePages = wanted }
    }

    /// Pages left off the screen because they are empty spare pages at the end.
    var hiddenPages: Int { max((note?.document.pages.count ?? 0) - visiblePages, 0) }

    func titleChanged() {
        guard title != titleText.plain else { return }
        titleDirty = true
        scheduleSave()
    }

    /// True while something typed has not been stored yet.
    var unsaved = false

    private func scheduleSave() {
        saveSoon?.cancel()
        if !unsaved { unsaved = true }
        // With saving as one types switched off, it waits for ⌘S or for the note to be left.
        guard model.autoSave else { return }
        saveSoon = Task { [weak self] in
            // A moment after the last keystroke.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes title and text if they changed since they were last written.
    func saveNow() {
        saveSoon?.cancel()
        if unsaved { unsaved = false }
        guard textDirty || titleDirty, note != nil else { return }
        var newTitle: NoteText?
        if titleDirty {
            let single = title.replacingOccurrences(of: "\n", with: " ")
            var changed = titleText
            if changed.isEmpty { changed = NoteText.uniform(single, like: nil, body: false) } else { changed.replace(0..<changed.length, with: single) }
            titleText = changed
            newTitle = changed
        }
        let savedTitle = newTitle
        let shownTitle = title
        let savedBody = textDirty ? text.text : nil
        let hadPictures = Set(note?.document.floating.filter(\.inText).map(\.id) ?? [])
        let lostPictures = textDirty && !hadPictures.subtracting(text.objectIDs).isEmpty
        textDirty = false
        titleDirty = false
        let id = noteID, arrivals = loadedArrivals
        let diverted = Box<String?>(nil)
        write("The note could not be saved.", { edits in
            diverted.value = try edits.saveRich(id, title: savedTitle, body: savedBody, typedInto: arrivals)
        }, then: { [weak self] in
            guard let self else { return }
            if diverted.value != nil {
                self.notice = "A newer version of this note arrived from another device while you were typing. What you typed was kept as a separate note, “\(shownTitle.isEmpty ? "Note" : shownTitle) (Mac copy)”."
                self.model.changed()
                Task { await self.load(text: true) }
            } else {
                // A picture deleted from the text is gone from the note now: going back to a text
                // that still shows it would show a picture that no longer exists.
                if lostPictures { self.text.forgetUndo() }
                Task { await self.load(text: false) }
            }
        }, failed: { [weak self] error in
            guard let self else { return }
            if self.model.store.loadLibrary().notes[id] == nil {
                // The note was deleted meanwhile, here or elsewhere: what was typed becomes a note of its own.
                self.rescue(title: savedTitle ?? self.titleText, body: savedBody ?? self.text.text, name: shownTitle)
                return
            }
            // Still unsaved: the next keystroke, or leaving the note, tries again.
            if savedBody != nil { self.textDirty = true }
            if savedTitle != nil { self.titleDirty = true }
            self.fail("The note could not be saved.", error)
        })
    }

    /// Keeps typed text whose note is gone as a new note.
    private func rescue(title: NoteText, body: NoteText, name: String) {
        var kept = title
        kept.replace(kept.length..<kept.length, with: kept.isEmpty ? "Note (Mac copy)" : " (Mac copy)")
        if kept.spans.isEmpty { kept = NoteText.uniform(kept.string, like: nil, body: false) }
        let edits = model.edits
        queue.async { [weak self] in
            let made = try? edits.createTextNote(title: "", body: "")
            if let made { _ = try? edits.saveRich(made, title: kept, body: body) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.changed()
                self.notice = made == nil ? "This note was deleted while you were typing, and what you typed could not be kept." : "This note was deleted while you were typing. What you typed was kept as a new note, “\(name.isEmpty ? "Note" : name) (Mac copy)”."
            }
        }
    }

    /// Writes everything still unwritten and waits until it is on disk. For quitting and closing.
    func flush() {
        saveNow()
        queue.sync {}
        changedSoon?.cancel()
        model.changed()
    }

    // MARK: Ink

    struct PageStroke {
        var page: Int
        var stroke: InkStroke
    }

    /// One step of drawing that can be taken back.
    private struct InkChange {
        var removed: [PageStroke] = []
        var added: [PageStroke] = []
        var name: String
    }

    private func watchUndo() {
        undoWatch.forEach(NotificationCenter.default.removeObserver)
        undoWatch = []
        guard let undoManager else { canUndo = false; canRedo = false; return }
        for name in [Notification.Name.NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup] {
            undoWatch.append(NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let manager = self.undoManager else { return }
                    if self.canUndo != manager.canUndo { self.canUndo = manager.canUndo }
                    if self.canRedo != manager.canRedo { self.canRedo = manager.canRedo }
                }
            })
        }
    }

    private func register(_ change: InkChange) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.revert(change) } }
        undoManager.setActionName(change.name)
    }

    private func revert(_ change: InkChange) {
        let back = InkChange(removed: change.added, added: change.removed, name: change.name)
        apply(back)
        register(back)
        selection = nil
    }

    /// Shows a change from memory and writes it.
    private func apply(_ change: InkChange) {
        guard var note else { return }
        inkEpoch += 1
        let gone = Set(change.removed.map(\.stroke.id))
        if !gone.isEmpty {
            note.strokes = note.strokes.filter { !gone.contains($0.key) }
            for page in Set(change.removed.map(\.page)) where note.document.pages.indices.contains(page) {
                note.document.pages[page].objects.removeAll { gone.contains($0.id) }
                bump(page)
            }
        }
        var byPage: [Int: [InkStroke]] = [:]
        for item in change.added where note.document.pages.indices.contains(item.page) {
            note.strokes[item.stroke.id] = item.stroke
            note.document.pages[item.page].objects.append(NoteObject(id: item.stroke.id, kind: .stroke, rect: item.stroke.bounds))
            byPage[item.page, default: []].append(item.stroke)
        }
        for page in byPage.keys { bump(page) }
        self.note = note
        let id = noteID
        let added = byPage.mapValues { strokes in strokes.map { NewStroke(points: $0.points, argb: $0.argb, penSize: $0.penSize, pen: $0.pen, id: $0.id, style: $0.style) } }
        write("The drawing could not be saved.") { edits in
            if !gone.isEmpty { try edits.eraseStrokes(id, ids: gone) }
            for page in added.keys.sorted() { try edits.addStrokes(id, page: page, strokes: added[page] ?? []) }
        }
    }

    /// Strokes just drawn on a page, in the page's own units.
    func draw(_ strokes: [NewStroke], page: Int, name: String = "Drawing") {
        let prepared = strokes.compactMap { LocalEdits.prepared($0) }.map { PageStroke(page: page, stroke: $0) }
        guard !prepared.isEmpty else { return }
        let change = InkChange(added: prepared, name: name)
        apply(change)
        register(change)
    }

    func erase(_ ids: Set<String>, name: String = "Erase") {
        guard let note, !ids.isEmpty else { return }
        var removed: [PageStroke] = []
        for (index, page) in note.document.pages.enumerated() {
            for object in page.objects where ids.contains(object.id) {
                if let stroke = note.strokes[object.id] { removed.append(PageStroke(page: index, stroke: stroke)) }
            }
        }
        guard !removed.isEmpty else { return }
        let change = InkChange(removed: removed, name: name)
        apply(change)
        register(change)
        if let selection, !selection.strokes.isDisjoint(with: ids) { self.selection = nil }
    }

    /// The line of text a highlighter is drawn over, for "Adjust thickness to text": of the PDF
    /// under the page, or of the note's own text. In the page's units.
    func textLine(under stroke: CGRect, page: Int) -> CGRect? {
        guard let note, note.document.pages.indices.contains(page) else { return nil }
        var lines = pdfText.lines(page: page)
        if let flow = TextFlow(note.document) {
            let top = NoteLayout(note.document).top(page)
            lines += flow.lineRects.map { $0.offsetBy(dx: 0, dy: -top) }
        }
        // The line the stroke lies over for the most part: its middle is within the line's height.
        return lines.filter { $0.minY <= stroke.midY && stroke.midY <= $0.maxY && $0.maxX > stroke.minX && $0.minX < stroke.maxX }
            .min { abs($0.midY - stroke.midY) < abs($1.midY - stroke.midY) }
    }

    /// Which strokes the eraser may take: all, only those of the highlighters, only tapes.
    enum InkFilter { case all, highlighters, tapes }

    private func passes(_ stroke: InkStroke, _ filter: InkFilter) -> Bool {
        switch filter {
        case .all: return true
        case .highlighters: return Pen.kind(named: stroke.penName).isMarker || stroke.style.topLayer
        case .tapes: return Pen.kind(named: stroke.penName) == .tape
        }
    }

    // MARK: Tape

    /// The tape that lies at a place on a page: the topmost, when several do.
    private func tape(at point: CGPoint, page: Int) -> InkStroke? {
        guard let note, let objects = note.document.pages[safe: page]?.objects else { return nil }
        for object in objects.reversed() where object.kind == .stroke {
            guard let stroke = note.strokes[object.id], Pen.kind(named: stroke.penName) == .tape,
                  stroke.bounds.insetBy(dx: -stroke.penSize, dy: -stroke.penSize).contains(point) else { continue }
            let band = InkRenderer.path(for: stroke).copy(strokingWithWidth: max(stroke.penSize, 4), lineCap: .butt, lineJoin: .round, miterLimit: 2)
            if band.contains(point) { return stroke }
        }
        return nil
    }

    var hasTapes: Bool { note?.strokes.values.contains { Pen.kind(named: $0.penName) == .tape } ?? false }
    /// True when every tape of the note has been tapped open.
    var tapesRevealed: Bool { note.map { note in note.strokes.values.filter { Pen.kind(named: $0.penName) == .tape }.allSatisfy(\.style.revealed) } ?? false }

    private func setRevealed(_ revealed: Bool, of tapes: [(page: Int, stroke: InkStroke)], name: String) {
        var removed: [PageStroke] = [], added: [PageStroke] = []
        for (page, stroke) in tapes where stroke.style.revealed != revealed {
            var style = stroke.style
            style.revealed = revealed
            guard let changed = LocalEdits.prepared(NewStroke(points: stroke.points, argb: stroke.argb, penSize: stroke.penSize, pen: stroke.pen, style: style)) else { continue }
            removed.append(PageStroke(page: page, stroke: stroke))
            added.append(PageStroke(page: page, stroke: changed))
        }
        guard !added.isEmpty else { return }
        let change = InkChange(removed: removed, added: added, name: name)
        apply(change)
        register(change)
    }

    /// A tap on a tape: what it covers shows through, or is covered again. False when no tape lies there.
    @discardableResult
    func toggleTape(at point: CGPoint, page: Int) -> Bool {
        guard canEdit, let found = tape(at: point, page: page) else { return false }
        setRevealed(!found.style.revealed, of: [(page, found)], name: found.style.revealed ? "Cover" : "Reveal")
        return true
    }

    /// Opens every tape of the note, or closes them all.
    func setAllTapes(revealed: Bool) {
        guard let note else { return }
        var tapes: [(page: Int, stroke: InkStroke)] = []
        for (index, page) in note.document.pages.enumerated() {
            for object in page.objects where object.kind == .stroke {
                if let stroke = note.strokes[object.id], Pen.kind(named: stroke.penName) == .tape { tapes.append((index, stroke)) }
            }
        }
        setRevealed(revealed, of: tapes, name: revealed ? "Reveal All Tapes" : "Cover All Tapes")
    }

    /// The strokes of a page that lie at a point, for the eraser.
    func strokes(at point: CGPoint, page: Int, reach: Double, only filter: InkFilter = .all) -> Set<String> {
        guard let note, note.document.pages.indices.contains(page) else { return [] }
        var hit: Set<String> = []
        for object in note.document.pages[page].objects where object.kind == .stroke {
            guard let stroke = note.strokes[object.id], passes(stroke, filter), stroke.bounds.insetBy(dx: -reach - stroke.penSize, dy: -reach - stroke.penSize).contains(point) else { continue }
            let wide = InkRenderer.path(for: stroke).copy(strokingWithWidth: max(stroke.penSize, reach * 2), lineCap: .round, lineJoin: .round, miterLimit: 2)
            if wide.contains(point) { hit.insert(stroke.id) }
        }
        return hit
    }

    /// Picks the strokes of a page that a loop drawn around them holds.
    /// Rubs a disc out of the strokes of a page: what lies in it goes, and a stroke it cuts
    /// through is left as the pieces on either side, each a stroke of the same pen.
    func eraseArea(at point: CGPoint, radius: Double, page: Int, only filter: InkFilter = .all) {
        guard let note, note.document.pages.indices.contains(page), radius > 0 else { return }
        var removed: [PageStroke] = [], added: [PageStroke] = []
        for object in note.document.pages[page].objects where object.kind == .stroke {
            guard let stroke = note.strokes[object.id], passes(stroke, filter) else { continue }
            // The line has a width: what the disc touches of it counts.
            let reach = radius + stroke.penSize / 2
            guard stroke.bounds.insetBy(dx: -reach, dy: -reach).contains(point), let pieces = InkEdit.cut(stroke.points, centre: point, radius: reach) else { continue }
            removed.append(PageStroke(page: page, stroke: stroke))
            for piece in pieces {
                // Each piece's times begin anew, as a stroke's do.
                let start = piece.first?.time ?? 0
                let points = piece.map { InkPoint(x: $0.x, y: $0.y, pressure: $0.pressure, time: $0.time.map { max($0 - start, 0) }) }
                if let kept = LocalEdits.prepared(NewStroke(points: points, argb: stroke.argb, penSize: stroke.penSize, pen: stroke.pen, style: stroke.style)) { added.append(PageStroke(page: page, stroke: kept)) }
            }
        }
        guard !removed.isEmpty else { return }
        let change = InkChange(removed: removed, added: added, name: "Erase")
        apply(change)
        register(change)
        if let selection, !selection.strokes.isDisjoint(with: Set(removed.map(\.stroke.id))) { self.selection = nil }
    }

    /// Every stroke of the note: what "Erase all handwriting" takes away.
    var inkIDs: Set<String> {
        guard let note else { return [] }
        return Set(note.document.pages.flatMap { $0.objects.filter { $0.kind == .stroke }.map(\.id) })
    }

    /// Gives the strokes that are picked another colour, another size, or both: "Change style".
    /// `level` is a size from 1 to 100 of each stroke's own pen.
    func restyleSelection(argb: UInt32? = nil, level: Double? = nil) {
        guard let selection, let note, let page = note.document.pages[safe: selection.page] else { return }
        var removed: [PageStroke] = [], added: [PageStroke] = []
        var bounds = CGRect.null
        for id in selection.strokes {
            // Handwriting only: a tape keeps its look, as in the Windows client.
            guard let stroke = note.strokes[id], Pen.kind(named: stroke.penName) != .tape else { continue }
            // The colour changes; how see-through the stroke is stays the stroke's own.
            let color = argb.map { ($0 & 0x00FF_FFFF) | (stroke.argb & 0xFF00_0000) } ?? stroke.argb
            let size = level.map { stroke.pen.size(level: $0, pageWidth: page.width, pageHeight: page.height) } ?? stroke.penSize
            var style = stroke.style
            style.colorType = 0
            if let level, style.lineType != 0 { style.sizeLevel = Int(level) }
            guard color != stroke.argb || abs(size - stroke.penSize) > 0.001,
                  let changed = LocalEdits.prepared(NewStroke(points: stroke.points, argb: color, penSize: size, pen: stroke.pen, style: style)) else { continue }
            removed.append(PageStroke(page: selection.page, stroke: stroke))
            added.append(PageStroke(page: selection.page, stroke: changed))
        }
        guard !added.isEmpty else { return }
        let change = InkChange(removed: removed, added: added, name: "Change Style")
        apply(change)
        register(change)
        // What is picked stays picked, under its new ids.
        var chosen = selection.strokes.subtracting(removed.map(\.stroke.id))
        chosen.formUnion(added.map(\.stroke.id))
        for stroke in added.map(\.stroke) { bounds = bounds.union(stroke.bounds.insetBy(dx: -stroke.penSize / 2, dy: -stroke.penSize / 2)) }
        for id in chosen.subtracting(added.map(\.stroke.id)) { if let kept = note.strokes[id] { bounds = bounds.union(kept.bounds.insetBy(dx: -kept.penSize / 2, dy: -kept.penSize / 2)) } }
        self.selection = InkSelection(page: selection.page, strokes: chosen, bounds: bounds, objects: selection.objects)
    }

    /// Picks the strokes a loop (or a rectangle) is drawn around. With `partial`, a stroke it
    /// only touches is picked too; without, only one that lies in it whole.
    func select(lasso: [CGPoint], page: Int, partial: Bool? = nil, objects: Bool = false) {
        pickPicture(nil)
        guard let note, note.document.pages.indices.contains(page), lasso.count > 2 else { selection = nil; return }
        let path = CGMutablePath()
        path.addLines(between: lasso)
        path.closeSubpath()
        var chosen: Set<String> = []
        var bounds = CGRect.null
        for object in note.document.pages[page].objects where object.kind == .stroke {
            guard let stroke = note.strokes[object.id], path.boundingBox.intersects(stroke.bounds.insetBy(dx: -1, dy: -1)) else { continue }
            let inside = stroke.points.filter { path.contains(CGPoint(x: $0.x, y: $0.y)) }.count
            // Touched at all, in whole, or (when it is not said) for the most part.
            let picked = partial.map { $0 ? inside > 0 : inside == stroke.points.count } ?? (inside * 10 >= stroke.points.count * 6)
            if picked {
                chosen.insert(stroke.id)
                bounds = bounds.union(stroke.bounds.insetBy(dx: -stroke.penSize / 2, dy: -stroke.penSize / 2))
            }
        }
        // With the pointer: the text boxes and the pictures placed freely on the page that the loop holds, or touches.
        var picked: Set<String> = []
        if objects {
            let area = path.boundingBox
            let free = note.document.floating.filter { ($0.kind == .image || $0.kind == .painting) && !$0.inText && ($0.pageIndex ?? 0) == page }
            for object in note.document.pages[page].objects.filter({ $0.kind == .textBox }) + free {
                let rect = NoteSession.turnedFrame(object.rect, by: object.rotation)
                guard partial == true ? area.intersects(rect) : area.contains(rect) else { continue }
                picked.insert(object.id)
                bounds = bounds.union(rect)
            }
        }
        selection = chosen.isEmpty && picked.isEmpty ? nil : InkSelection(page: page, strokes: chosen, bounds: bounds, objects: picked)
    }

    /// Picks what lies under a click: a picture placed on the page, else a stroke.
    func select(at point: CGPoint, page: Int, reach: Double) {
        pickPicture(nil)
        guard let note else { return }
        let hit = strokes(at: point, page: page, reach: reach)
        guard let id = hit.first, let stroke = note.strokes[id] else { selection = nil; return }
        selection = InkSelection(page: page, strokes: [id], bounds: stroke.bounds.insetBy(dx: -stroke.penSize / 2, dy: -stroke.penSize / 2))
    }

    /// Picks the block of handwriting a point is on: the stroke under it and every stroke near
    /// enough to one already picked, as far as they reach. Returns the block's frame, in the
    /// page's units; nil, and nothing picked, when there is no handwriting there.
    @discardableResult
    func selectBlock(at point: CGPoint, page: Int, reach: Double) -> CGRect? {
        pickPicture(nil)
        guard let note, let sheet = note.document.pages[safe: page] else { return nil }
        let hit = strokes(at: point, page: page, reach: reach)
        guard !hit.isEmpty else { return nil }
        // Letters of one word, words of one line: apart by less than this, they are one block.
        let gap = sheet.width * 0.025
        var rest: [(id: String, rect: CGRect)] = sheet.objects.compactMap { object in
            guard object.kind == .stroke, let stroke = note.strokes[object.id] else { return nil }
            return (object.id, stroke.bounds.insetBy(dx: -stroke.penSize / 2, dy: -stroke.penSize / 2))
        }
        var chosen = rest.filter { hit.contains($0.id) }
        rest.removeAll { hit.contains($0.id) }
        var grew = true
        while grew {
            grew = false
            for (index, candidate) in rest.enumerated().reversed() where chosen.contains(where: { $0.rect.insetBy(dx: -gap, dy: -gap).intersects(candidate.rect) }) {
                chosen.append(candidate)
                rest.remove(at: index)
                grew = true
            }
        }
        let bounds = chosen.reduce(CGRect.null) { $0.union($1.rect) }
        selection = InkSelection(page: page, strokes: Set(chosen.map(\.id)), bounds: bounds)
        return bounds
    }

    /// The frame a picture turned about its middle takes up.
    static func turnedFrame(_ rect: CGRect, by degrees: Double) -> CGRect {
        let size = NoteObject.turned(rect.size, by: degrees.isFinite ? degrees : 0)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Moves or resizes what is picked. `transform` is in the page's units.
    func transformSelection(_ transform: CGAffineTransform) {
        guard let selection, let note, !transform.isIdentity else { return }
        let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        var removed: [PageStroke] = [], added: [PageStroke] = []
        var bounds = CGRect.null
        // The text boxes and pictures picked with it go along, each as one step of the same Undo.
        for id in selection.objects {
            if let box = textBoxObject(id)?.object {
                let rect = box.rect.applying(transform)
                changeTextBox(id, rect: rect, page: selection.page, grows: scale == 1 ? nil : false, name: scale == 1 ? "Move" : "Resize")
                bounds = bounds.union(rect)
            } else if let picture = note.document.floating.first(where: { $0.id == id }), !picture.inText {
                let rect = picture.rect.applying(transform)
                movePicture(id, to: rect, page: selection.page)
                bounds = bounds.union(NoteSession.turnedFrame(rect, by: picture.rotation))
            }
        }
        for id in selection.strokes {
            guard let stroke = note.strokes[id] else { continue }
            removed.append(PageStroke(page: selection.page, stroke: stroke))
            let points = stroke.points.map { point -> InkPoint in
                let moved = CGPoint(x: point.x, y: point.y).applying(transform)
                return InkPoint(x: moved.x, y: moved.y, pressure: point.pressure, time: point.time)
            }
            guard let moved = LocalEdits.prepared(NewStroke(points: points, argb: stroke.argb, penSize: stroke.penSize * scale, pen: stroke.pen, style: stroke.style)) else { continue }
            added.append(PageStroke(page: selection.page, stroke: moved))
            bounds = bounds.union(moved.bounds.insetBy(dx: -moved.penSize / 2, dy: -moved.penSize / 2))
        }
        if !added.isEmpty {
            let change = InkChange(removed: removed, added: added, name: scale == 1 ? "Move" : "Resize")
            apply(change)
            register(change)
        }
        guard !bounds.isNull else { return }
        self.selection = InkSelection(page: selection.page, strokes: Set(added.map(\.stroke.id)), bounds: bounds, objects: selection.objects)
    }

    func deleteSelection() {
        if let picked = pictureSelection {
            removePicture(picked)
            pickPicture(nil)
            return
        }
        guard let selection else { return }
        if !selection.strokes.isEmpty { erase(selection.strokes, name: "Delete") }
        for id in selection.objects { removePicture(id) }
        self.selection = nil
    }

    // MARK: Picking a picture

    /// Picks a picture (or, with nil, none): its handles show, Delete removes it, and the
    /// strokes picked with the loop are let go.
    func pickPicture(_ id: String?) {
        if pictureSelection != id { pictureSelection = id }
        text.pickedObject = id
        if id != nil, selection != nil { selection = nil }
    }

    /// The picture is clicked or dragged: it is picked, and the keyboard goes to the text so
    /// that Delete reaches it.
    func pointAtPicture(_ id: String) {
        pickPicture(id)
        text.focus()
    }

    /// Gives a picture its new size, in the page's units. A picture set in the text keeps its
    /// place in the text, and the text flows around its new size; a picture placed on a page
    /// keeps its top left corner.
    func resizePicture(_ id: String, to size: CGSize) {
        guard let object = note?.document.floating.first(where: { $0.id == id }), size.width.isFinite, size.height.isFinite else { return }
        let width = min(max(size.width, 24), 20_000), height = min(max(size.height, 24), 20_000)
        let rect = CGRect(x: object.rect.minX, y: object.rect.minY, width: width, height: height)
        setRect(of: id, to: rect, page: object.pageIndex ?? 0, from: object.rect)
    }

    /// Turns a picture about its middle, to an angle in degrees clockwise.
    func rotatePicture(_ id: String, to degrees: Double) {
        guard var note, let index = note.document.floating.firstIndex(where: { $0.id == id }), degrees.isFinite else { return }
        let old = note.document.floating[index].rotation
        var within = degrees.truncatingRemainder(dividingBy: 360)
        if within > 180 { within -= 360 }
        if within <= -180 { within += 360 }
        let angle = within
        guard abs(angle - old) > 0.01 else { return }
        note.document.floating[index].rotation = angle
        let inText = note.document.floating[index].inText
        self.note = note
        for page in pageRevisions.indices { bump(page) }
        if inText { text.forgetPictures() }
        let noteID = noteID
        write("The picture could not be turned.") { edits in try edits.setFloatingRotation(noteID, id: id, degrees: angle) }
        undoManager?.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.rotatePicture(id, to: old) } }
        undoManager?.setActionName("Turn Picture")
    }

    /// Puts a picture placed on a page somewhere else on the page, or on another page: `rect`
    /// is in the units of the page `page`.
    func movePicture(_ id: String, to rect: CGRect, page: Int) {
        guard let object = note?.document.floating.first(where: { $0.id == id }), !object.inText else { return }
        setRect(of: id, to: rect, page: page, from: object.rect, fromPage: object.pageIndex ?? 0)
    }

    // MARK: Pictures

    private func setRect(of object: String, to rect: CGRect, page: Int, from old: CGRect, fromPage: Int? = nil) {
        guard var note, let index = note.document.floating.firstIndex(where: { $0.id == object }) else { return }
        let before = fromPage ?? note.document.floating[index].pageIndex ?? 0
        let moved = rect.origin != old.origin || page != before
        note.document.floating[index].rect = rect
        note.document.floating[index].pageIndex = page
        let inText = note.document.floating[index].inText
        self.note = note
        for page in pageRevisions.indices { bump(page) }
        if inText { text.forgetPictures() }
        let id = noteID
        write("The picture could not be changed.") { edits in try edits.setFloatingRect(id, id: object, rect: rect, page: page) }
        undoManager?.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.setRect(of: object, to: old, page: before, from: rect, fromPage: page) } }
        undoManager?.setActionName(moved ? "Move Picture" : "Resize Picture")
    }

    /// The size a picture set in the text is given, in units of text size: as the library fits it.
    func fitted(_ pixels: CGSize) -> CGSize {
        guard let document = note?.document, pixels.width > 0, pixels.height > 0 else { return CGSize(width: 80, height: 60) }
        let density = document.density
        let column = document.width - (document.bodyMargins.left + document.bodyMargins.right) * density
        let scale = min(column / pixels.width, document.width * 495 / 848 / pixels.height, 1)
        return CGSize(width: pixels.width * scale / density, height: pixels.height * scale / density)
    }

    /// Adds a picture: at a place in the text, or free on a page. Returns its object's id.
    @discardableResult
    func addPicture(_ file: PictureFile, at textOffset: Int? = nil, onPage placement: (page: Int, rect: CGRect)? = nil) -> String? {
        guard canEdit else { return nil }
        // The text on disk must be the text on screen before a picture is set into it.
        saveNow()
        let id = noteID
        let object = UUID().uuidString.lowercased()
        let where_: NoteFile.Placement = placement.map { .onPage($0.page, $0.rect) } ?? .inText
        let offset = min(max(textOffset ?? text.text.length, 0), text.text.length)
        write("The picture could not be added.", { edits in
            _ = try edits.addImage(id, data: file.data, fileExtension: file.fileExtension, pixelSize: file.pixels, placement: where_, textOffset: offset, objectID: object)
        }, then: { [weak self] in
            guard let self else { return }
            Task { await self.load(text: false) }
        }, failed: { [weak self] error in
            guard let self else { return }
            self.fail("The picture could not be added.", error)
            self.arriving[object] = nil
            if placement == nil { self.text.removeObject(object) }
        })
        if placement == nil {
            // Its place is in the text on screen from this moment, so that whatever is typed
            // next is saved with it.
            let image = CGImageSourceCreateWithData(file.data as CFData, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary) }
            arriving[object] = (image, fitted(file.pixels))
            text.insertObject(object, at: offset)
        }
        return object
    }

    func removePicture(_ object: String) {
        if stickyObject(object) != nil { removeSticky(object); return }
        if textBoxObject(object) != nil { removeTextBox(object); return }
        guard let note, let found = note.document.floating.first(where: { $0.id == object }) else { return }
        if found.inText {
            // Its place in the text goes; saving the text removes the picture itself.
            text.removeObject(object)
            return
        }
        let id = noteID
        write("The picture could not be removed.", { edits in try edits.removeFloating(id, ids: [object]) }, then: { [weak self] in
            guard let self else { return }
            Task { await self.load(text: false) }
        })
    }

    // MARK: Pages

    /// False for a note of one page that grows: it is not given pages.
    var hasPages: Bool { note?.document.isEndless != true }

    // MARK: Changes that Undo takes back whole

    /// A change of the note's pages or its paper. The note is kept as it stood before, and
    /// Undo puts it back so: pages, paper, what was drawn and placed on them.
    func structural(_ name: String, _ problem: String, _ work: @escaping @Sendable (LocalEdits) throws -> Void, then done: (@MainActor @Sendable () -> Void)? = nil) {
        let id = noteID
        let shown = visiblePages
        let kept = Box<NoteSnapshot?>(nil)
        write(problem, { edits in
            let snapshot = try edits.snapshot(id)
            do { try work(edits) } catch { snapshot.discard(); throw error }
            kept.value = snapshot
        }, then: { [weak self] in
            guard let self else { return }
            if let snapshot = kept.value {
                self.undoManager?.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.restore(snapshot, shown: shown, name: name) } }
                self.undoManager?.setActionName(name)
            }
            if let done { done() } else { Task { await self.load(text: false) } }
        })
    }

    /// Puts the note back as a snapshot has it; the way forward again is kept for Redo.
    private func restore(_ snapshot: NoteSnapshot, shown: Int, name: String) {
        saveNow()
        selection = nil
        pickPicture(nil)
        let id = noteID
        let wasShown = visiblePages
        let forward = Box<NoteSnapshot?>(nil)
        // Said now, while the step is being taken back, so that it counts as the step forward again.
        undoManager?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { if let again = forward.value { session.restore(again, shown: wasShown, name: name) } }
        }
        undoManager?.setActionName(name)
        write("The change could not be taken back.", { edits in
            forward.value = try edits.snapshot(id)
            try edits.restore(snapshot)
        }, then: { [weak self] in
            guard let self else { return }
            self.revealedTo = shown
            self.text.forgetPictures()
            Task { await self.load(text: true) }
        })
    }

    func addPage(after index: Int) {
        guard hasPages else { return }
        let id = noteID
        saveNow()
        undoManager?.removeAllActions(withTarget: self)
        // What is shown stays, and one page more. At the end, the empty page the note keeps
        // there already is that page: it is shown, and no page is added.
        revealedTo = visiblePages + 1
        if index >= visiblePages - 1, hiddenPages > 0 {
            refreshVisible()
            return
        }
        structural("Add Page", "The page could not be added.", { edits in _ = try edits.addPage(id, after: index) }, then: { [weak self] in self.map { session in Task { await session.load(text: false) } } })
    }

    func removePage(_ index: Int) {
        let id = noteID
        saveNow()
        selection = nil
        // Steps of drawing remember pages by their number, which is about to change.
        undoManager?.removeAllActions(withTarget: self)
        revealedTo = max(visiblePages - 1, 1)
        structural("Delete Page", "The page could not be removed.", { edits in try edits.removePage(id, index: index) }, then: { [weak self] in self.map { session in Task { await session.load(text: false) } } })
    }

    /// True when something is drawn or placed on a page: ink, or a picture that lies on it.
    /// The note's text is not the page's: it flows over whatever pages there are.
    func pageHoldsSomething(_ index: Int) -> Bool {
        guard let document = note?.document, document.pages.indices.contains(index) else { return false }
        let page = document.pages[index]
        return !page.objects.isEmpty || page.pdf != nil || page.backgroundImage != nil || document.floating.contains { !$0.inText && ($0.pageIndex ?? 0) == index }
    }

    func movePage(_ index: Int, to target: Int) {
        let id = noteID
        saveNow()
        selection = nil
        // Steps of drawing remember pages by their number, which is about to change.
        undoManager?.removeAllActions(withTarget: self)
        revealedTo = visiblePages
        structural("Move Page", "The page could not be moved.", { edits in try edits.movePage(id, from: index, to: target) }, then: { [weak self] in self.map { session in Task { await session.load(text: false) } } })
    }
}

/// A value handed from a background write to the main thread afterwards.
final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
