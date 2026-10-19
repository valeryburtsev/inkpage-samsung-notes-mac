import CoreGraphics
import Foundation

/// Changes made on this Mac. Each one updates the note's document and the library and leaves a
/// mark for the next sync to send it.
public struct LocalEdits: Sendable {
    public let store: LocalStore
    public init(store: LocalStore) { self.store = store }

    public enum Failure: Error, LocalizedError {
        case noteFull
        case pictureUnreadable
        public var errorDescription: String? {
            switch self {
            case .noteFull: return "This note holds as much handwriting as one note can. Continue in a new note."
            case .pictureUnreadable: return "The picture's file could not be read."
            }
        }
    }

    static func record(from file: NoteFile, serverID: String, commitID: String, pending: NoteRecord.Pending?, deviceName: String) throws -> NoteRecord {
        let data = file.data()
        let document = try NoteDocument(xml: data)
        let created = document.displayCreated ?? Date(timeIntervalSince1970: Double(document.createdMicros) / 1_000_000)
        return NoteRecord(id: document.id, serverID: serverID, commitID: commitID,
                          title: document.title.plain.trimmingCharacters(in: .whitespacesAndNewlines),
                          preview: String(document.body.plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)),
                          createdAt: created, modifiedAt: document.displayModified ?? created, isLocked: document.isLocked,
                          isFavorite: document.isFavorite, hasInk: document.hasInk, hasText: !document.body.isEmpty,
                          coverFile: document.firstImage, deviceName: deviceName, bytes: data.count, pending: pending, unsentStrokes: nil, pagesChanged: nil, revision: nil, nodeSent: nil, fullText: String(document.body.plain.prefix(40_000)), inkText: nil, unsentFiles: nil)
    }

    private func markNode(_ library: inout Library, _ id: String) {
        var dirty = library.dirtyNodes ?? []
        dirty.insert(id)
        library.dirtyNodes = dirty
    }

    /// A new text note, in a folder or at the top.
    @discardableResult
    public func createTextNote(title: String, body: String, parent: String = TreeNode.rootID, layout: NoteFile.Layout = NoteFile.Layout(), now: Date = Date()) throws -> String {
        try store.exclusive {
            let file = NoteFile.newTextNote(title: title, body: body, layout: layout, now: now)
            // An endless note's one page is as high as its text needs from the start.
            if layout.endless, !body.isEmpty { _ = try settleText(file, now: now) }
            try store.write(file)
            var record = try LocalEdits.record(from: file, serverID: "", commitID: "", pending: .create, deviceName: Host.current().localizedName ?? "Mac")
            record.revision = 1
            store.update { library in
                library.notes[record.id] = record
                library.nodes[record.id] = TreeNode(id: record.id, kind: .note, parentID: parent, name: title, now: now)
                markNode(&library, record.id)
            }
            return record.id
        }
    }

    /// Keeps a note as it is on this Mac as a new note beside the original: text, handwriting and
    /// pictures. Used when another device's version or deletion is about to replace it.
    @discardableResult
    public func keepCopy(of noteID: String, suffix: String = " (Mac copy)", now: Date = Date()) throws -> String {
        try store.exclusive {
            let file = try store.noteFile(noteID)
            let library = store.loadLibrary()
            let old = library.notes[noteID], node = library.nodes[noteID]
            var title = old?.title ?? ""
            if title.isEmpty { title = node?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            if title.isEmpty { title = "Note" }
            title += suffix
            let newID = UUID().uuidString.lowercased()
            let copy = try file.copy(newID: newID, title: title, now: now)
            let from = store.directory(noteID), to = store.directory(newID)
            try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            for folder in ["strokes", "media"] where FileManager.default.fileExists(atPath: from.appendingPathComponent(folder).path) {
                try? FileManager.default.copyItem(at: from.appendingPathComponent(folder), to: to.appendingPathComponent(folder))
            }
            try store.write(copy)
            var record = try LocalEdits.record(from: copy, serverID: "", commitID: "", pending: .create, deviceName: Host.current().localizedName ?? "Mac")
            record.revision = 1
            record.bytes = max(record.bytes, old?.bytes ?? 0)
            store.update { library in
                library.notes[newID] = record
                library.nodes[newID] = TreeNode(id: newID, kind: .note, parentID: node?.parentID ?? TreeNode.rootID, name: title, now: now)
                markNode(&library, newID)
            }
            return newID
        }
    }

    /// True when the note's text can be edited here without losing anything: text only, in one style.
    public func canEditText(_ noteID: String) -> Bool {
        guard let note = try? store.load(noteID), let file = try? store.noteFile(noteID) else { return false }
        let document = note.document
        return !document.isLocked && document.allObjects.isEmpty && file.textIsEditable
    }

    /// Saves a new title and text for a note. Nothing is touched when neither changed.
    public func saveText(_ noteID: String, title: String, body: String, now: Date = Date()) throws {
        try store.exclusive {
            let file = try store.noteFile(noteID)
            let before = try NoteDocument(xml: file.data())
            let titleChanged = before.title.plain != title, bodyChanged = before.body.plain != body
            guard titleChanged || bodyChanged else { return }
            if titleChanged { file.setTitle(title, now: now) }
            if bodyChanged { file.setBody(body, now: now) }
            try store.write(file)
            try refresh(noteID, file: file, now: now, renameNode: titleChanged ? title : nil)
        }
    }

    /// The same for a note put back from a snapshot: everything about its pages counts as changed.
    func refreshRestored(_ noteID: String, file: NoteFile, now: Date, strokes: [String], files: [String]) throws {
        try refresh(noteID, file: file, now: now, addedStrokes: strokes, addedFiles: files, pagesChanged: true)
    }

    /// Rereads the note's document into the library and marks it for upload.
    private func refresh(_ noteID: String, file: NoteFile, now: Date, renameNode: String? = nil, addedStrokes: [String] = [], addedFiles: [String] = [], pagesChanged: Bool = false, change: ((inout TreeNode) -> Void)? = nil) throws {
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        try store.update { library in
            let old = library.notes[noteID]
            let pending: NoteRecord.Pending = old?.pending == .create || (old?.serverID ?? "").isEmpty ? .create : .update
            var record = try LocalEdits.record(from: file, serverID: old?.serverID ?? "", commitID: old?.commitID ?? "", pending: pending, deviceName: Host.current().localizedName ?? "Mac")
            record.bytes = max(record.bytes, old?.bytes ?? 0)
            record.unsentStrokes = (old?.unsentStrokes ?? []) + addedStrokes
            record.pagesChanged = (old?.pagesChanged ?? false) || pagesChanged || !addedStrokes.isEmpty
            record.revision = (old?.revision ?? 0) + 1
            record.nodeSent = old?.nodeSent
            // Handwriting that changed has to be read again.
            record.inkText = addedStrokes.isEmpty && !pagesChanged ? old?.inkText : nil
            let files = (old?.unsentFiles ?? []) + addedFiles.filter { !(old?.unsentFiles ?? []).contains($0) }
            record.unsentFiles = files.isEmpty ? nil : files
            library.notes[noteID] = record
            var node = library.nodes[noteID] ?? TreeNode(id: noteID, kind: .note, name: record.title, now: now)
            if let renameNode { node.name = renameNode }
            node.syncModifiedTime = millis
            node.lastModifiedTime = millis
            change?(&node)
            library.nodes[noteID] = node
            markNode(&library, noteID)
        }
    }

    /// True when the note's title can be rewritten without losing formatting.
    public func canRename(_ noteID: String) -> Bool {
        guard let file = try? store.noteFile(noteID) else { return false }
        return TextStyle.read(encoded: file.titleObject?.value("text") ?? "").editable
    }

    /// Gives a note a new title, whatever else it holds.
    public func rename(_ noteID: String, to title: String, now: Date = Date()) throws {
        try store.exclusive {
            let file = try store.noteFile(noteID)
            guard TextStyle.read(encoded: file.titleObject?.value("text") ?? "").editable else { return }
            file.setTitle(title, now: now)
            try store.write(file)
            try refresh(noteID, file: file, now: now, renameNode: title)
        }
    }

    // MARK: Handwriting

    /// The width of the standard pen on a page: the same share of the page's width on every device.
    public static func standardPenSize(pageWidth: Double) -> Double { Pen.fountain.size(level: 30, pageWidth: pageWidth) }

    /// Saves strokes drawn on a page. Points are in the page's own units. Returns the strokes as stored.
    @discardableResult
    public func addStrokes(_ noteID: String, page: Int, strokes drawn: [(points: [InkPoint], argb: UInt32, penSize: Double, id: String?)], now: Date = Date()) throws -> [InkStroke] {
        try addStrokes(noteID, page: page, strokes: drawn.map { NewStroke(points: $0.points, argb: $0.argb, penSize: $0.penSize, id: $0.id) }, now: now)
    }

    /// A stroke as it will be stored: its points on the grid the record keeps them on.
    public static func prepared(_ item: NewStroke) -> InkStroke? {
        var raw = item.points.filter { $0.x.isFinite && $0.y.isFinite }.map { point -> InkPoint in
            var point = point
            if !point.pressure.isFinite { point.pressure = 1 }
            return point
        }
        guard var first = raw.first, item.penSize.isFinite, item.penSize > 0 else { return nil }
        // A dot is stored as the shortest stroke there is.
        if raw.count == 1 { first.x += 1.0 / 32; first.time = (first.time ?? 0) + 16; raw.append(first) }
        let points = StrokeEncoder.quantized(raw)
        var stroke = InkStroke(id: item.id ?? UUID().uuidString.lowercased(), bounds: StrokeEncoder.bounds(of: points), points: points)
        stroke.argb = item.argb
        stroke.penSize = item.penSize
        stroke.penName = item.pen.name
        stroke.setting = item.pen.setting
        stroke.style = item.style
        return stroke
    }

    /// Saves strokes of any pen. Strokes without an id are given one; `prepared` ones keep theirs.
    @discardableResult
    public func addStrokes(_ noteID: String, page: Int, strokes drawn: [NewStroke], now: Date = Date()) throws -> [InkStroke] {
        try store.exclusive {
            let file = try store.noteFile(noteID)
            guard file.objectWeight + drawn.count <= NoteFile.objectWeightLimit else { throw Failure.noteFull }
            let size = file.pageSize(page)
            let stamp = Int64(now.timeIntervalSince1970 * 1_000_000)
            var saved: [InkStroke] = []
            var entries: [(id: String, modifiedMicros: Int64, bounds: CGRect)] = []
            let folder = store.directory(noteID).appendingPathComponent("strokes")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (offset, item) in drawn.enumerated() {
                guard var stroke = LocalEdits.prepared(item) else { continue }
                let pens = file.penIDs(item.pen)
                stroke.penNameID = pens.name
                stroke.settingID = pens.setting
                let modified = stamp + Int64(offset)
                let data = StrokeEncoder.encode(stroke, modifiedMicros: modified, drawnMicros: modified - 1000, pageWidth: size.width, pageHeight: size.height, settingID: pens.setting, tolerance: item.pen.tolerance)
                try data.write(to: folder.appendingPathComponent(LocalStore.safeName(stroke.id) + ".bin"))
                entries.append((stroke.id, modified, stroke.bounds))
                saved.append(stroke)
            }
            guard let last = drawn.last, !entries.isEmpty else { return [] }
            file.addStrokes(entries, page: page, argb: last.argb, penSize: last.penSize, pen: last.pen, now: now)
            // Drawn near the foot of an endless note's page: the page grows under it.
            let grew = page == 0 && file.growEndlessPage(toHold: Double(entries.map(\.bounds.maxY).max() ?? 0), now: now)
            try store.write(file)
            try refresh(noteID, file: file, now: now, addedStrokes: entries.map(\.id), pagesChanged: grew)
            return saved
        }
    }

    /// Erases strokes from a note.
    public func eraseStrokes(_ noteID: String, ids: Set<String>, now: Date = Date()) throws {
        try store.exclusive {
            let file = try store.noteFile(noteID)
            let removed = file.removeObjects(ids, now: now)
            guard !removed.isEmpty else { return }
            try store.write(file)
            for id in removed { try? FileManager.default.removeItem(at: store.directory(noteID).appendingPathComponent("strokes").appendingPathComponent(LocalStore.safeName(id) + ".bin")) }
            try refresh(noteID, file: file, now: now, pagesChanged: true)
            store.update { $0.notes[noteID]?.unsentStrokes?.removeAll { removed.contains($0) } }
        }
    }

    public func setFavorite(_ noteID: String, _ favorite: Bool, now: Date = Date()) throws {
        try store.exclusive {
            let file = try store.noteFile(noteID)
            file.setFavorite(favorite, now: now)
            try store.write(file)
            try refresh(noteID, file: file, now: now)
        }
    }

    /// Moves a note to the trash or back out of it.
    public func setTrashed(_ noteID: String, _ trashed: Bool, now: Date = Date()) throws {
        try store.exclusive {
            let file = try store.noteFile(noteID)
            file.setState(trashed ? .trashed : .normal, now: now)
            try store.write(file)
            let millis = Int64(now.timeIntervalSince1970 * 1000)
            try refresh(noteID, file: file, now: now) { node in
                node.state = trashed ? .trashed : .normal
                node.trashedTime = trashed ? millis : 0
                node.restorePath = trashed ? "uncategorized:///" : nil
            }
        }
    }

    /// Deletes a note for good, here and, at the next sync, in Samsung Cloud.
    public func deleteForever(_ noteID: String, now: Date = Date()) {
        store.exclusive {
            let millis = Int64(now.timeIntervalSince1970 * 1000)
            store.update { library in
                if library.folderLinks?[noteID] != nil {
                    var deletes = library.folderDeletes ?? []
                    deletes.insert(noteID)
                    library.folderDeletes = deletes
                }
                if let record = library.notes[noteID], !record.serverID.isEmpty {
                    var deletes = library.pendingDeletes ?? [:]
                    deletes[noteID] = record.serverID
                    library.pendingDeletes = deletes
                    if var node = library.nodes[noteID] {
                        node.state = .deleted
                        node.syncModifiedTime = millis
                        node.lastModifiedTime = millis
                        node.restorePath = node.restorePath ?? "uncategorized:///"
                        library.nodes[noteID] = node
                        markNode(&library, noteID)
                    }
                } else if library.notes[noteID]?.nodeSent == true, var node = library.nodes[noteID] {
                    // The note never arrived, but the service was told of its place: take that back.
                    node.state = .deleted
                    node.syncModifiedTime = millis
                    node.lastModifiedTime = millis
                    library.nodes[noteID] = node
                    markNode(&library, noteID)
                } else {
                    // Never reached the service: there is nothing to tell it.
                    library.nodes[noteID] = nil
                    library.dirtyNodes?.remove(noteID)
                }
                library.notes[noteID] = nil
            }
            store.remove(noteID)
        }
    }

    public func move(_ noteID: String, to folder: String, now: Date = Date()) {
        store.exclusive {
            let millis = Int64(now.timeIntervalSince1970 * 1000)
            store.update { library in
                guard var node = library.nodes[noteID] else { return }
                node.parentID = folder
                node.syncModifiedTime = millis
                library.nodes[noteID] = node
                markNode(&library, noteID)
            }
        }
    }

    @discardableResult
    public func createFolder(name: String, parent: String = TreeNode.rootID, now: Date = Date()) -> String {
        store.exclusive {
            let id = UUID().uuidString.lowercased()
            store.update { library in
                library.nodes[id] = TreeNode(id: id, kind: .folder, parentID: parent, name: name, color: -48845, order: 0, now: now)
                markNode(&library, id)
            }
            return id
        }
    }

    public func renameFolder(_ id: String, to name: String, now: Date = Date()) {
        store.exclusive {
            let millis = Int64(now.timeIntervalSince1970 * 1000)
            store.update { library in
                guard var node = library.nodes[id], node.kind == .folder else { return }
                node.name = name
                node.syncModifiedTime = millis
                node.lastModifiedTime = millis
                library.nodes[id] = node
                markNode(&library, id)
            }
        }
    }

    // MARK: More of the library

    /// A second copy of a note, with everything in it.
    @discardableResult
    public func duplicate(_ noteID: String, now: Date = Date()) throws -> String {
        try keepCopy(of: noteID, suffix: " copy", now: now)
    }

    /// Deletes for good everything that is in the trash.
    public func emptyTrash(now: Date = Date()) {
        store.exclusive {
            let library = store.loadLibrary()
            for record in library.notes.values where library.state(of: record.id) == .trashed { deleteForever(record.id, now: now) }
        }
    }

    public func setFolderColor(_ id: String, _ color: Int32, now: Date = Date()) {
        changeFolder(id, now: now) { $0.color = color }
    }

    /// Puts a folder inside another, or at the top. A folder cannot go inside itself.
    public func moveFolder(_ id: String, to parent: String, now: Date = Date()) {
        guard !store.loadLibrary().subtree(of: id).contains(parent) else { return }
        changeFolder(id, now: now) { $0.parentID = parent }
    }

    private func changeFolder(_ id: String, now: Date, _ change: (inout TreeNode) -> Void) {
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        store.exclusive {
            store.update { library in
                guard var node = library.nodes[id], node.kind == .folder else { return }
                change(&node)
                node.syncModifiedTime = millis
                node.lastModifiedTime = millis
                library.nodes[id] = node
                markNode(&library, id)
            }
        }
    }

    /// Deletes a folder and the folders in it. Their notes go to the trash, from where they
    /// can be put back (they return to the top level, as their folder is gone).
    public func deleteFolder(_ id: String, now: Date = Date()) throws {
        try store.exclusive {
            let library = store.loadLibrary()
            let folders = library.subtree(of: id)
            for record in library.notes.values where folders.contains(library.nodes[record.id]?.parentID ?? "") && library.state(of: record.id) == .normal {
                move(record.id, to: TreeNode.rootID, now: now)
                try setTrashed(record.id, true, now: now)
            }
            let millis = Int64(now.timeIntervalSince1970 * 1000)
            store.update { library in
                for folder in folders {
                    guard var node = library.nodes[folder], node.kind == .folder else { continue }
                    node.state = .deleted
                    node.syncModifiedTime = millis
                    node.lastModifiedTime = millis
                    library.nodes[folder] = node
                    markNode(&library, folder)
                }
            }
        }
    }

    // MARK: Leaving the account

    /// Takes this Mac's library off the Samsung account, for signing out. Nothing the user made
    /// is lost:
    /// - notes that never reached the service stay, with the folders they are in;
    /// - changes to notes the service has, that were not sent, are kept as notes of their own
    ///   ("… (Mac copy)");
    /// - notes the service has and that are unchanged are removed from this Mac.
    /// The change feeds' places are forgotten, so the next account starts from the beginning.
    /// Notes that stay are marked to be sent when an account is signed in again.
    /// Forgets how the notes stand with Samsung's service and keeps every one of them: for
    /// signing out while the notes are synced with something else. Should the account be
    /// signed in to again, they are sent to it as new notes.
    public func forgetAccount() {
        store.exclusive {
            store.update { library in
                for id in library.notes.keys {
                    library.notes[id]?.serverID = ""
                    library.notes[id]?.commitID = ""
                    library.notes[id]?.nodeSent = nil
                    library.notes[id]?.pending = .create
                    library.notes[id]?.pagesChanged = nil
                    library.notes[id]?.unsentStrokes = nil
                    library.notes[id]?.unsentFiles = nil
                }
                library.dirtyNodes = Set(library.nodes.keys)
                library.pendingDeletes = nil
                library.failedDownloads = nil
                library.folderCursor = nil
                library.noteCursor = nil
                library.cloudBytes = nil
            }
        }
    }

    /// Makes everything on this Mac wait to be sent to Samsung's service: for turning to that
    /// service after the notes were synced with something else. Notes it has are sent as
    /// changed, the others as new, and every folder and place is told to it again.
    public func queueAllForAccount() {
        store.exclusive {
            store.update { library in
                for id in library.notes.keys where library.notes[id]?.pending == nil && (library.notes[id]?.serverID ?? "").isEmpty { library.notes[id]?.pending = .create }
                library.dirtyNodes = (library.dirtyNodes ?? []).union(library.nodes.values.filter { $0.state != .deleted || library.notes[$0.id] != nil }.map(\.id))
            }
        }
    }

    public func detachFromAccount(now: Date = Date()) throws {
        try store.exclusive {
            for record in store.loadLibrary().notes.values where !record.serverID.isEmpty && record.pending != nil {
                try keepCopy(of: record.id, now: now)
            }
            let library = store.loadLibrary()
            let leaving = library.notes.values.filter { !$0.serverID.isEmpty }.map(\.id)
            for id in leaving { store.remove(id) }
            store.update { library in
                for id in leaving { library.notes[id] = nil }
                let staying = Set(library.notes.keys)
                // Folders to keep: those holding a note that stays, those changed here and not
                // sent, and every folder above them.
                var folders: Set<String> = []
                func keepWithParents(_ start: String?) {
                    var current = start
                    var hops = 0
                    while let id = current, id != TreeNode.rootID, hops < 64, let node = library.nodes[id], node.kind == .folder {
                        folders.insert(id)
                        current = node.parentID
                        hops += 1
                    }
                }
                for id in staying { keepWithParents(library.nodes[id]?.parentID) }
                for id in library.dirtyNodes ?? [] where library.nodes[id]?.kind == .folder && library.nodes[id]?.state != .deleted { keepWithParents(id) }
                let kept = staying.union(folders)
                library.nodes = library.nodes.filter { kept.contains($0.key) }
                for id in staying where library.nodes[id] == nil {
                    // A note whose place in the tree was never known: it goes at the top.
                    library.nodes[id] = TreeNode(id: id, kind: .note, name: library.notes[id]?.title ?? "", now: now)
                }
                for id in kept {
                    guard var node = library.nodes[id] else { continue }
                    if node.parentID != TreeNode.rootID, !folders.contains(node.parentID) { node.parentID = TreeNode.rootID }
                    library.nodes[id] = node
                }
                for id in staying {
                    library.notes[id]?.nodeSent = nil
                    library.notes[id]?.commitID = ""
                    if library.notes[id]?.pending == nil { library.notes[id]?.pending = .create }
                }
                library.dirtyNodes = kept
                // Notes that left this Mac this way were not deleted: a sync folder keeps its own.
                library.folderLinks = library.folderLinks?.filter { staying.contains($0.key) }
                library.pendingDeletes = nil
                library.failedDownloads = nil
                library.folderCursor = nil
                library.noteCursor = nil
                library.lastSync = nil
                library.cloudBytes = nil
            }
        }
    }

    // MARK: Formatted text

    /// The size of every picture in a note's document, by object id.
    private static func objectSizes(_ document: NoteDocument) -> [String: CGSize] {
        var sizes: [String: CGSize] = [:]
        for object in document.allObjects where object.kind == .image || object.kind == .painting || object.kind == .table { sizes[object.id] = object.rect.size }
        return sizes
    }

    /// After the text changed: pictures set in it are moved to where the text now puts them,
    /// those whose place in the text is gone are removed, and pages are added until the text fits.
    func settleText(_ file: NoteFile, now: Date) throws -> Bool {
        var pagesChanged = false
        var document = try NoteDocument(xml: file.data())
        var text = file.bodyText
        let dangling = Set(text.objectIDs).subtracting(document.allObjects.map(\.id))
        if !dangling.isEmpty, text.removeObjects(dangling) { file.setBodyText(text, now: now) }
        let placed = Set(text.objectIDs)
        let orphans = Set(document.floating.filter { $0.inText && !placed.contains($0.id) }.map(\.id))
        if !orphans.isEmpty || !dangling.isEmpty {
            file.removeFloating(orphans, now: now)
            document = try NoteDocument(xml: file.data())
        }
        // An endless note has one page, which grows under its text instead of a next page being added.
        if file.isEndless {
            for _ in 0..<400 {
                guard let flow = TextFlow(document) else { break }
                let reach = flow.pagesUsed > 1 ? Double(file.pageSize(0).height) + 1 : flow.bottom
                guard file.growEndlessPage(toHold: reach, now: now) else { break }
                pagesChanged = true
                document = try NoteDocument(xml: file.data())
            }
        }
        // The text is set page by page: a line or a picture that does not fit in what is left
        // of a page starts the next one. Pages are added until all of it has a page.
        let flow = TextFlow(document)
        let column = flow?.column
        let stride = column?.stride ?? 0
        while let flow, !file.isEndless, file.pageCount < flow.pagesUsed, file.pageCount < 400 {
            if file.addPage(now: now) == nil { break }
            pagesChanged = true
        }
        let positions = flow?.positions ?? [:]
        let rooms = NoteRenderer.pictureSizes(document)
        for object in document.floating where object.inText {
            guard let position = positions[object.id], position.y.isFinite, stride > 0 else { continue }
            let index = min(column?.page(at: position.y) ?? 0, max(file.pageCount - 1, 0))
            // The text made room for the picture as it stands, turned or not: it lies in the middle of that room.
            let room = rooms[object.id] ?? object.rect.size
            let rect = CGRect(x: position.x + (room.width - object.rect.width) / 2, y: position.y - (column?.top(ofPage: index) ?? 0) + (room.height - object.rect.height) / 2,
                              width: object.rect.width, height: object.rect.height)
            if abs(rect.minX - object.rect.minX) > 0.5 || abs(rect.minY - object.rect.minY) > 0.5 || index != (object.pageIndex ?? 0) {
                file.setFloatingRect(object.id, rect, page: index, now: now)
            }
        }
        return pagesChanged
    }

    /// Saves a title and a text with their formatting. `nil` leaves that one as it is.
    ///
    /// `typedInto` is `LocalStore.arrivals(_:)` of the note as it was when the text on screen was
    /// read. When another device's version has replaced the note since, the typed text is not
    /// written over it: it is saved in a copy beside the note, and the copy's id is returned.
    @discardableResult
    public func saveRich(_ noteID: String, title: NoteText?, body: NoteText?, typedInto: Int? = nil, now: Date = Date()) throws -> String? {
        try store.exclusive { () throws -> String? in
            if let typedInto, store.arrivals(noteID) != typedInto, store.loadLibrary().notes[noteID] != nil {
                let copy = try keepCopy(of: noteID, now: now)
                try saveRich(copy, title: title.map { text in
                    var named = text
                    named.replace(named.length..<named.length, with: named.isEmpty ? "Note (Mac copy)" : " (Mac copy)")
                    return named
                }, body: body, now: now)
                return copy
            }
            let file = try store.noteFile(noteID)
            var renamed: String?
            var pagesChanged = false, changed = false
            if let title, title != file.titleText {
                file.setTitleText(title, now: now)
                renamed = title.plain.replacingOccurrences(of: "\n", with: " ")
                changed = true
            }
            if var text = body {
                text.renumber()
                text.hasSection = true
                if text != file.bodyText {
                    file.setBodyText(text, now: now)
                    pagesChanged = try settleText(file, now: now)
                    changed = true
                }
            }
            guard changed else { return nil }
            try store.write(file)
            try refresh(noteID, file: file, now: now, renameNode: renamed, pagesChanged: pagesChanged)
            return nil
        }
    }

    /// The title and the text of a note as stored, for editing.
    public func richText(_ noteID: String) -> (title: NoteText, body: NoteText)? {
        richTextAndArrivals(noteID).map { ($0.title, $0.body) }
    }

    /// The same with `LocalStore.arrivals` as it was at that very moment, for `saveRich(typedInto:)`.
    public func richTextAndArrivals(_ noteID: String) -> (title: NoteText, body: NoteText, arrivals: Int)? {
        store.exclusive {
            guard let file = try? store.noteFile(noteID) else { return nil }
            return (file.titleText, file.bodyText, store.arrivals(noteID))
        }
    }

    // MARK: Pictures and pages

    /// Runs a change on a note's document and stores the result.
    func change<T>(_ noteID: String, now: Date, pagesChanged: Bool = false, addedFiles: [String] = [], _ work: (NoteFile) throws -> T?) throws -> T? {
        try store.exclusive {
            let file = try store.noteFile(noteID)
            let pages = file.pageCount
            guard let result = try work(file) else { return nil }
            try store.write(file)
            // A page added along the way (for a picture that needed the room) has to be sent too.
            try refresh(noteID, file: file, now: now, addedFiles: addedFiles, pagesChanged: pagesChanged || file.pageCount != pages)
            return result
        }
    }

    /// Where the text of a note has got to: the y a picture added at its end is given.
    private func textBottom(_ file: NoteFile) -> Double {
        guard let document = try? NoteDocument(xml: file.data()), let flow = TextFlow(document) else { return file.textColumn.top }
        return flow.bottom + 4
    }

    /// Adds a picture to a note. `data` is the picture's file as it will be kept and sent
    /// (JPEG or PNG). Returns the new object's id.
    @discardableResult
    public func addImage(_ noteID: String, data: Data, fileExtension: String, pixelSize: CGSize, placement: NoteFile.Placement = .inText, fillWidth: Bool = false, textOffset: Int? = nil, objectID: String? = nil, now: Date = Date()) throws -> String? {
        let hash = NoteFile.sha256(data)
        return try change(noteID, now: now, addedFiles: [hash]) { file in
            store.writeFile(noteID, hash, data)
            var size = file.fittedSize(pixelSize, fillWidth: fillWidth)
            var top: Double?
            if case .inText = placement {
                top = textBottom(file)
            } else if case .onPage(_, let rect) = placement {
                size = rect.size
            }
            let id = file.addImage(fileHash: hash, fileExtension: fileExtension, size: size, placement: placement, top: top, textOffset: textOffset, objectID: objectID, now: now)
            if case .inText = placement { _ = try settleText(file, now: now) }
            return id
        }
    }

    /// Removes pictures and other floating objects.
    public func removeFloating(_ noteID: String, ids: Set<String>, now: Date = Date()) throws {
        _ = try change(noteID, now: now) { file in file.removeFloating(ids, now: now).isEmpty ? nil : true }
    }

    /// Moves or resizes a picture on its page.
    public func setFloatingRect(_ noteID: String, id: String, rect: CGRect, page: Int? = nil, now: Date = Date()) throws {
        _ = try change(noteID, now: now) { file -> Bool? in
            guard file.setFloatingRect(id, rect, page: page, now: now) else { return nil }
            // A picture set in the text keeps its place in it: what changed is its size, and the
            // text, the pictures after it and the pages follow.
            let inText = file.root.descendants("object").first { $0["id"] == id && $0["type"] != nil }?["layoutType"] == "2"
            if inText { _ = try settleText(file, now: now) }
            return true
        }
    }

    /// Turns a picture about its middle. A picture set in the text keeps its place in it, and
    /// the text makes room for it as it stands turned.
    public func setFloatingRotation(_ noteID: String, id: String, degrees: Double, now: Date = Date()) throws {
        _ = try change(noteID, now: now) { file -> Bool? in
            guard file.setFloatingRotation(id, degrees, now: now) else { return nil }
            let inText = file.root.descendants("object").first { $0["id"] == id && $0["type"] != nil }?["layoutType"] == "2"
            if inText { _ = try settleText(file, now: now) }
            return true
        }
    }

    /// Sets a picture into the text or frees it from the text (see `NoteFile.setFloatingAnchor`).
    public func setFloatingAnchor(_ noteID: String, id: String, inText: Bool, rect: CGRect? = nil, page: Int? = nil, textOffset: Int? = nil, now: Date = Date()) throws {
        _ = try change(noteID, now: now) { file -> Bool? in
            guard file.setFloatingAnchor(id, inText: inText, rect: rect, page: page, textOffset: textOffset, now: now) else { return nil }
            _ = try settleText(file, now: now)
            return true
        }
    }

    @discardableResult
    public func addPage(_ noteID: String, after index: Int? = nil, now: Date = Date()) throws -> Int? {
        try change(noteID, now: now, pagesChanged: true) { file in
            let at = file.addPage(after: index, now: now)
            if at != nil { _ = try settleText(file, now: now) }
            return at
        }
    }

    public func removePage(_ noteID: String, index: Int, now: Date = Date()) throws {
        _ = try change(noteID, now: now, pagesChanged: true) { file -> Bool? in
            guard let gone = file.removePage(index, now: now) else { return nil }
            for id in gone { try? FileManager.default.removeItem(at: store.directory(noteID).appendingPathComponent("strokes").appendingPathComponent(LocalStore.safeName(id) + ".bin")) }
            store.update { $0.notes[noteID]?.unsentStrokes?.removeAll { gone.contains($0) } }
            _ = try settleText(file, now: now)
            return true
        }
    }

    public func movePage(_ noteID: String, from index: Int, to target: Int, now: Date = Date()) throws {
        _ = try change(noteID, now: now, pagesChanged: true) { file -> Bool? in
            guard file.movePage(index, to: target, now: now) else { return nil }
            _ = try settleText(file, now: now)
            return true
        }
    }

    public func setPageColor(_ noteID: String, index: Int, argb: UInt32, now: Date = Date()) throws {
        _ = try change(noteID, now: now, pagesChanged: true) { file -> Bool? in file.setPageColor(index, argb, now: now); return true }
    }

    /// Remembers text recognised in a note's handwriting, for searching. Not a change to the note.
    public func setInkText(_ noteID: String, _ text: String, forRevision revision: Int?, commit: String) {
        store.update { library in
            // Only for the very version that was read: not one edited here or downloaded since.
            guard let record = library.notes[noteID], record.revision == revision, record.commitID == commit else { return }
            library.notes[noteID]?.inkText = text
        }
    }
}
