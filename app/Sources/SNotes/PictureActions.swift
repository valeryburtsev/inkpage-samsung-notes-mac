import AppKit
import ImageIO
import SamsungNotesKit
import UniformTypeIdentifiers

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, symbol: String? = nil, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// What can be done to a picture of a note from its menu.
extension NoteSession {
    /// A picture as a file: for the clipboard, for sharing and for saving.
    struct PictureExport {
        var data: Data
        var type: UTType
        var name: String
    }

    func pictureObject(_ id: String) -> NoteObject? { note?.document.floating.first { $0.id == id } }

    /// The picture as it is shown: the whole file when it is not cropped, else the part that
    /// is left of it, as a PNG.
    func pictureExport(_ id: String) -> PictureExport? {
        guard let note, let object = pictureObject(id), let hash = object.pictureFile, let url = note.fileURL(hash), let data = try? Data(contentsOf: url) else { return nil }
        let base = NoteFiles.fileName(title.isEmpty ? "Picture" : title)
        if object.isCropped, let source = CGImageSourceCreateWithData(data as CFData, nil),
           let whole = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 8192] as CFDictionary),
           let shown = object.shown(whole) {
            let out = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, shown, nil)
                if CGImageDestinationFinalize(destination) { return PictureExport(data: out as Data, type: .png, name: base + ".png") }
            }
        }
        let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) } ?? .png
        return PictureExport(data: data, type: type, name: base + "." + (type.preferredFilenameExtension ?? "png"))
    }

    @discardableResult
    func copyPicture(_ id: String) -> Bool {
        guard let export = pictureExport(id) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(export.data, forType: NSPasteboard.PasteboardType(export.type.identifier))
        return board.writeObjects([item])
    }

    func cutPicture(_ id: String) {
        guard copyPicture(id) else { return }
        removePicture(id)
        pickPicture(nil)
    }

    /// True when the clipboard holds something a note can take: a picture or text.
    static var canPaste: Bool {
        let board = NSPasteboard.general
        return board.availableType(from: [.png, PictureFile.jpegType, .tiff, .fileURL, .string]) != nil
    }

    /// Pastes the clipboard next to a picture: a picture after it in the text, or beside it on
    /// its page; text after it in the text.
    func paste(nextTo id: String) {
        guard canEdit, let object = pictureObject(id) else { return }
        let board = NSPasteboard.general
        if let file = PictureFile(pasteboard: board) {
            if object.inText {
                addPicture(file, at: text.offset(afterObject: id))
            } else if let document = note?.document {
                let size = fitted(file.pixels)
                let density = document.density
                let rect = CGRect(x: object.rect.minX + 12 * density, y: object.rect.minY + 12 * density, width: size.width * density, height: size.height * density)
                addPicture(file, onPage: (object.pageIndex ?? 0, rect))
            }
        } else if let string = board.string(forType: .string), !string.isEmpty {
            let at = object.inText ? (text.offset(afterObject: id) ?? text.text.length) : text.selection.lowerBound
            text.insert(object.inText ? "\n" + string : string, at: at)
        }
    }

    /// As wide as the page lets it be: the text's column for a picture set in the text, the
    /// whole page for one that lies freely on it. It keeps its proportions.
    func fitPictureToPageWidth(_ id: String) {
        guard let document = note?.document, let object = pictureObject(id), object.rect.width > 0, object.rect.height > 0 else { return }
        let ratio = object.rect.height / object.rect.width
        if object.inText {
            let column = TextColumn(document)
            // Turned on its side, it is its height that lies across the column.
            let room = NoteObject.turned(CGSize(width: 1, height: ratio), by: object.rotation)
            let width = column.width / max(room.width, 0.01)
            resizePicture(id, to: CGSize(width: width, height: width * ratio))
        } else {
            let width = NoteLayout(document).pageWidth
            let height = width * ratio
            movePicture(id, to: CGRect(x: 0, y: object.rect.midY - height / 2, width: width, height: height), page: object.pageIndex ?? 0)
        }
    }

    /// Frees a picture from the text: it stays where it is, at `rect` on page `page` (in the
    /// page's units), and the text closes up under it.
    func freePicture(_ id: String, at rect: CGRect, page: Int) {
        guard canEdit, let object = pictureObject(id), object.inText else { return }
        saveNow()
        // On screen and in the text at once, so that nothing typed or saved meanwhile sees the
        // picture half moved; the write follows in its turn, before any save of the text.
        _ = show(id) { shown in
            shown.layoutType = "3"
            shown.rect = rect
            shown.pageIndex = page
        }
        text.settle(object: id, at: nil)
        let note = noteID
        write("The picture could not be changed.", { edits in
            try edits.setFloatingAnchor(note, id: id, inText: false, rect: rect, page: page)
        }, then: { [weak self] in
            guard let self else { return }
            Task { await self.load(text: false) }
        })
    }

    /// Sets a picture that lies freely on a page into the text, at a place in it.
    func anchorPicture(_ id: String, at offset: Int) {
        guard canEdit, let object = pictureObject(id), !object.inText else { return }
        saveNow()
        // Its place is in the text on screen from this moment (and no step of undo leads back
        // to a text without it): a text saved without the place would take the picture away.
        _ = show(id) { $0.layoutType = "2" }
        text.settle(object: id, at: offset)
        text.forgetPictures()
        let note = noteID
        write("The picture could not be changed.", { edits in
            try edits.setFloatingAnchor(note, id: id, inText: true, textOffset: offset)
        }, then: { [weak self] in
            guard let self else { return }
            Task {
                await self.load(text: false)
                self.text.forgetPictures()
            }
        })
    }

    /// A picture as it is at one moment: the file it shows, the file that was made from, the
    /// part shown and where. What undoing a crop goes back to.
    struct PictureState: Equatable {
        var imageID: String?
        var originalImageID: String?
        var crop: CGRect?
        var rect: CGRect
        var page: Int
    }

    private func state(of object: NoteObject) -> PictureState {
        PictureState(imageID: object.imageID, originalImageID: object.originalImageID, crop: object.crop, rect: object.rect, page: object.pageIndex ?? 0)
    }

    /// Shows a state of a picture from memory at once. Returns what it was before.
    private func show(_ id: String, _ change: (inout NoteObject) -> Void) -> NoteObject? {
        guard var note, let index = note.document.floating.firstIndex(where: { $0.id == id }) else { return nil }
        let old = note.document.floating[index]
        change(&note.document.floating[index])
        self.note = note
        for page in pageRevisions.indices { bump(page) }
        if old.inText { text.forgetPictures() }
        return old
    }

    private func undoable(_ id: String, back old: NoteObject, name: String) {
        let before = state(of: old)
        undoManager?.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.restorePicture(id, before, name: name) } }
        undoManager?.setActionName(name)
    }

    /// Shows another part of a picture: `crop` in fractions of the whole picture, nil for all of
    /// it. With `restore`, a picture that was cut out along a loop becomes the picture it was
    /// cut from again. `rect` is the frame the shown part then has, in the units of page
    /// `page`; of a picture set in the text only its size counts. The picture's file is not touched.
    func cropPicture(_ id: String, crop: CGRect?, restore: Bool = false, rect: CGRect, page: Int) {
        guard let object = pictureObject(id), rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        var part = crop.map { $0.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        if let whole = part, whole.isNull || whole.isEmpty || (whole.minX < 0.0005 && whole.minY < 0.0005 && whole.maxX > 0.9995 && whole.maxY > 0.9995) { part = nil }
        let back = restore && object.originalImageID != nil
        var placed = rect
        if object.inText { placed.origin = object.rect.origin }
        guard part != object.crop || back || placed != object.rect else { return }
        let target = object.inText ? object.pageIndex ?? 0 : page
        guard let old = show(id, { shown in
            shown.crop = part
            shown.outline = nil
            shown.rect = placed
            shown.pageIndex = target
            if back { shown.imageID = shown.originalImageID; shown.originalImageID = nil }
        }) else { return }
        let noteID = noteID
        write("The picture could not be cropped.") { edits in try edits.setFloatingCrop(noteID, id: id, crop: part, restore: back, rect: placed, page: target) }
        undoable(id, back: old, name: "Crop Picture")
    }

    /// Cuts a picture out along a loop drawn on it: `loop` in fractions of the whole picture.
    /// What is left is the loop's bounding box, at `rect`; outside the loop it is clear. The
    /// picture it was cut from is kept, and comes back with "Show Whole Picture".
    func lassoPicture(_ id: String, loop: [CGPoint], rect: CGRect, page: Int) {
        guard let object = pictureObject(id), loop.count > 2, rect.width > 0, rect.height > 0 else { return }
        let box = loop.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0, box.height > 0 else { return }
        var placed = rect
        if object.inText { placed.origin = object.rect.origin }
        let target = object.inText ? object.pageIndex ?? 0 : page
        // Shown from memory until the cut-out copy has been made: the first picture, the box, the loop.
        guard let old = show(id, { shown in
            let source = shown.originalImageID ?? shown.imageID
            shown.imageID = source
            shown.originalImageID = source
            shown.crop = box
            shown.outline = loop.map { CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) }
            shown.rect = placed
            shown.pageIndex = target
        }) else { return }
        let noteID = noteID
        write("The picture could not be cut out.", { edits in try edits.lassoCrop(noteID, id: id, loop: loop, rect: placed, page: target) }, then: { [weak self] in
            guard let self else { return }
            Task { await self.load(text: false) }
        })
        undoable(id, back: old, name: "Lasso Crop")
    }

    /// Puts a picture back as it was at an earlier moment.
    func restorePicture(_ id: String, _ state: PictureState, name: String) {
        guard let imageID = state.imageID, let old = show(id, { shown in
            shown.imageID = state.imageID
            shown.originalImageID = state.originalImageID
            shown.crop = state.crop
            shown.outline = nil
            shown.rect = state.rect
            shown.pageIndex = state.page
        }) else { return }
        let noteID = noteID
        write("The picture could not be changed.", { edits in
            try edits.setFloatingPicture(noteID, id: id, imageID: imageID, originalImageID: state.originalImageID, crop: state.crop, rect: state.rect, page: state.page)
        }, then: { [weak self] in
            guard let self else { return }
            Task { await self.load(text: false) }
        })
        undoable(id, back: old, name: name)
    }

    func sharePicture(_ id: String, from view: NSView) {
        guard let export = pictureExport(id) else { return }
        // A file with a name of its own: the stored one is named by its content.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SNotesShare-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent(export.name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try export.data.write(to: url)
        } catch {
            fail("The picture could not be shared.", error)
            return
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds.insetBy(dx: view.bounds.width / 2 - 1, dy: view.bounds.height / 2 - 1), of: view, preferredEdge: .minY)
    }

    func savePicture(_ id: String) {
        guard let export = pictureExport(id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [export.type]
        panel.nameFieldStringValue = export.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try export.data.write(to: url, options: .atomic) } catch { fail("The picture could not be saved.", error) }
    }
}
