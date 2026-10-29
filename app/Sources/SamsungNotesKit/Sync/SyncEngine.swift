import Foundation

/// Keeps the local library and Samsung Cloud in step: takes the service's changes, then sends
/// what was changed here. Every change to the library goes through the store in one step, so
/// edits made in the app while a sync runs are not lost.
public actor SyncEngine {
    public struct Progress: Sendable {
        public var message: String
        public var done: Int
        public var total: Int?
    }

    private let account: AccountManager
    private let store: LocalStore
    private var running = false

    private let http: HTTPClient

    public init(account: AccountManager, store: LocalStore, http: HTTPClient = .shared) {
        self.account = account
        self.store = store
        self.http = http
    }

    public enum Failure: Error, CustomStringConvertible {
        case alreadyRunning
        public var description: String { "A sync is already running." }
    }

    private var api: NotesAPI!

    public var isRunning: Bool { running }

    /// Returns once no round is under way.
    public func idle() async {
        while running { try? await Task.sleep(for: .milliseconds(60)) }
    }

    private func makeAPI(forceNewToken: Bool) async throws -> NotesAPI {
        let token = try await account.cloudToken(forceNew: forceNewToken)
        return NotesAPI(base: await account.apiBase, token: token, deviceName: Host.current().localizedName ?? "Mac", http: http)
    }

    private var renewal: Task<NotesAPI, Error>?

    /// Runs one call; a token the service no longer takes is renewed once and the call repeated.
    /// Calls that run side by side and are refused together share one renewal.
    private func call<T>(_ work: (NotesAPI) async throws -> T) async throws -> T {
        let used: NotesAPI = api
        do { return try await work(used) } catch let error as HTTPError where error.status == 401 || error.status == 403 {
            if api.token == used.token {
                let task = renewal ?? Task { try await self.makeAPI(forceNewToken: true) }
                renewal = task
                defer { renewal = nil }
                api = try await task.value
            }
            return try await work(api)
        }
    }

    /// One round. Returns the library as it stands afterwards.
    public func sync(progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Library {
        guard !running else { throw Failure.alreadyRunning }
        running = true
        defer { running = false }
        api = try await makeAPI(forceNewToken: false)
        var firstError: Error?
        func attempt(_ work: () async throws -> Void) async {
            do { try await work() } catch { if firstError == nil { firstError = error } }
        }

        // The password of locked notes is the account's: the newer of the service's and this Mac's holds.
        try? await syncPasscode()

        progress?(Progress(message: "Checking folders…", done: 0, total: nil))
        try await pullFolders()
        await attempt { try await self.pushNodes() }

        progress?(Progress(message: "Checking notes…", done: 0, total: nil))
        let (changes, cursor) = try await pullChanges(progress: progress)
        let failedDownloads = await download(changes, progress: progress)
        // The place in the feed moves on either way: notes that failed are kept on a list of
        // their own and tried again, instead of walking the whole feed anew every time.
        store.update { $0.noteCursor = cursor }
        if failedDownloads > 0, firstError == nil { firstError = HTTPError(status: 0, what: "Download", detail: "\(failedDownloads) notes could not be downloaded; they will be tried again") }

        // A copy kept during the downloads has a new place in the tree: the service hears of the
        // place before it gets the note, as the Windows client does it.
        await attempt { try await self.pushNodes() }
        await attempt { try await self.pushNotes(progress: progress) }
        await attempt { try await self.pushDeletes() }

        let usage = await api.usage()
        // Notes the folder tree calls deleted are gone for good.
        let snapshot = store.loadLibrary()
        for node in snapshot.nodes.values where node.kind == .note && node.state == .deleted && snapshot.pendingDeletes?[node.id] == nil
            && (snapshot.notes[node.id] != nil || FileManager.default.fileExists(atPath: store.directory(node.id).path)) {
            removeLocally(node.id)
        }
        let library = store.update { library -> Library in
            library.lastSync = Date()
            library.cloudBytes = usage ?? library.cloudBytes
            return library
        }
        progress?(Progress(message: "Up to date", done: 0, total: nil))
        if let firstError { throw firstError }
        return library
    }

    /// As the Windows client settles it: one set here and newer than the service's is sent;
    /// a newer one of the service's replaces this Mac's; of equal age, nothing is done.
    private func syncPasscode() async throws {
        let theirs = try await call { try await $0.passcode() }
        let ours = await account.passcode, unsent = await account.passcodeUnsent
        if let ours, unsent, ours.time > (theirs?.time ?? 0) {
            try await call { try await $0.setPasscode(ours) }
            await account.setPasscode(ours, unsent: false)
        } else if let theirs, theirs.time > (ours?.time ?? 0) || ours == nil {
            await account.setPasscode(theirs, unsent: false)
        } else if unsent, let ours {
            // Overtaken by one set elsewhere at the same moment or later: the service's stands.
            await account.setPasscode(theirs ?? ours, unsent: false)
        }
    }

    /// The shape of an upload for the log: which parts it has and how large, and the note's
    /// marks that are no content (locked, encrypted, whether an owner is named, the formats).
    static func shape(of document: String) -> String {
        guard let root = try? XMLTree.parse(Data(document.utf8)) else { return "unreadable (\(document.utf8.count) bytes)" }
        var parts = ["\(document.utf8.count) bytes", "locked \(root["isLocked"] ?? "-")", "encrypted \(root["isEncrypted"] ?? "-")", "owner \((root["ownerId"] ?? "").isEmpty ? "none" : "named")"]
        let attributes = root.child("attributes")
        parts.append("format \(attributes?["formatVersion"] ?? "-")/\(attributes?["minFormatVersion"] ?? "-") type \(attributes?["documentType"] ?? "-") mode \(attributes?["pageMode"] ?? "-")")
        for child in root.children {
            switch child.name {
            case "pageList": parts.append("pages \(child.all("page").count)")
            case "floatingObjectList": parts.append("objects " + child.all("object").map { $0["type"] ?? "?" }.joined(separator: ","))
            case "contentFileList": parts.append("files \(child.all("contentFile").count)")
            case "bodyText": parts.append("body")
            default: break
            }
        }
        return parts.joined(separator: "; ")
    }

    // MARK: From the service

    private func pullFolders() async throws {
        let cursor = store.loadLibrary().folderCursor
        let folders = try await call { try await $0.folderChanges(cursor: cursor) }
        store.update { library in
            for node in folders.nodes {
                // A node changed here and not yet sent stands, unless the service's is newer.
                if library.dirtyNodes?.contains(node.id) == true, let local = library.nodes[node.id], local.syncModifiedTime >= node.syncModifiedTime { continue }
                library.nodes[node.id] = node
                library.dirtyNodes?.remove(node.id)
                // The note was changed elsewhere after it was deleted here: the newer version stays.
                if node.state != .deleted { library.pendingDeletes?[node.id] = nil }
            }
            if let next = folders.cursor { library.folderCursor = next }
        }
    }

    private func pullChanges(progress: (@Sendable (Progress) -> Void)?) async throws -> ([NoteChange], String?) {
        var pending: [NoteChange] = []
        var cursor = store.loadLibrary().noteCursor
        var pages = 0
        while pages < 20_000 {
            let from = cursor
            let page = try await call { try await $0.noteChanges(cursor: from) }
            pending.append(contentsOf: page.changes)
            if let next = page.cursor { cursor = next }
            pages += 1
            progress?(Progress(message: "Checking notes…", done: pending.count, total: nil))
            if !page.hasNext || (page.changes.isEmpty && page.cursor == nil) { break }
        }
        return (pending, cursor)
    }

    /// Removes a note from this Mac. What was changed here and never sent is kept as a copy first.
    private func removeLocally(_ noteID: String) {
        store.exclusive {
            if let record = store.loadLibrary().notes[noteID], record.pending != nil { _ = try? LocalEdits(store: store).keepCopy(of: noteID) }
            store.update { library in
                library.notes[noteID] = nil
                library.pendingDeletes?[noteID] = nil
                library.failedDownloads?[noteID] = nil
            }
            store.remove(noteID)
        }
    }

    /// Downloads what changed in the service. Returns how many notes failed.
    private func download(_ changes: [NoteChange], progress: (@Sendable (Progress) -> Void)?) async -> Int {
        // The feed lists a note once per change: the last entry for a note is its present state.
        var latest: [String: NoteChange] = [:]
        for change in changes { latest[change.resourceID] = change }
        for change in latest.values where change.isDeleted { removeLocally(change.resourceID) }
        let library = store.loadLibrary()
        var wanted = latest.values.filter { change in
            if change.isDeleted || change.isEncrypted { return false }
            if library.nodes[change.resourceID]?.state == .deleted || library.pendingDeletes?[change.resourceID] != nil { return false }
            return library.notes[change.resourceID]?.commitID != change.commitID || !FileManager.default.fileExists(atPath: store.noteURL(change.resourceID).path)
        }.sorted { $0.serverModifiedTime > $1.serverModifiedTime }
        // Notes that failed before, a few times at most.
        for (noteID, failure) in library.failedDownloads ?? [:] where latest[noteID] == nil && failure.attempts < 6 && library.nodes[noteID]?.state != .deleted {
            wanted.append(NoteChange(serverID: failure.serverID, resourceID: noteID))
        }

        // Four at a time: the feed gives one note per request, and a first sync may bring thousands.
        var done = 0, failed = 0
        let total = wanted.count
        progress?(Progress(message: "Downloading notes…", done: 0, total: total))
        await withTaskGroup(of: (change: NoteChange, ok: Bool).self) { group in
            var next = wanted.makeIterator()
            var running = 0
            while running < 4, let change = next.next() {
                running += 1
                group.addTask { await (change, (try? await self.downloadOne(change)) != nil) }
            }
            while let finished = await group.next() {
                done += 1
                if !finished.ok {
                    failed += 1
                    let change = finished.change
                    store.update { library in
                        var list = library.failedDownloads ?? [:]
                        list[change.resourceID] = Library.FailedDownload(serverID: change.serverID, attempts: (list[change.resourceID]?.attempts ?? 0) + 1)
                        library.failedDownloads = list
                    }
                }
                progress?(Progress(message: "Downloading notes…", done: done, total: total))
                if let change = next.next() {
                    group.addTask { await (change, (try? await self.downloadOne(change)) != nil) }
                }
            }
        }
        return failed
    }

    private func downloadOne(_ change: NoteChange) async throws {
        let note = try await call { try await $0.download(serverID: change.serverID) }
        let document = try NoteDocument(xml: note.xml)
        guard document.id == change.resourceID else {
            throw HTTPError(status: 0, what: "Note download", detail: "the service answered with another note")
        }
        // Checking for unsent work, keeping it and writing the downloaded note happen in one
        // piece, so an edit made in the app meanwhile is either kept as a copy or lands on top.
        let incoming = change.commitID.isEmpty ? (document.commitID ?? "") : change.commitID
        let record = try store.exclusive { () throws -> NoteRecord in
            let local = store.loadLibrary().notes[change.resourceID]
            if let local, !incoming.isEmpty, local.commitID == incoming, FileManager.default.fileExists(atPath: store.noteURL(change.resourceID).path) {
                // This very version is here already, perhaps changed here since: only files of it
                // may be missing. Taking the note again would undo what was changed.
                store.update { $0.failedDownloads?[change.resourceID] = nil }
                return local
            }
            if let local, local.pending != nil { try LocalEdits(store: store).keepCopy(of: change.resourceID) }
            let record = try store.ingest(serverID: change.serverID, commitID: incoming, deviceName: change.deviceName, xml: note.xml, strokes: note.strokes)
            store.update { library in
                library.notes[record.id] = record
                library.failedDownloads?[record.id] = nil
            }
            return record
        }
        var added = 0, missing = false
        for (hash, address) in document.downloadURLs where !store.hasFile(record.id, hash) {
            // The page's cached picture in Samsung's own format is of no use here.
            if let name = document.files.first(where: { $0.id == hash })?.name, name.lowercased().hasSuffix(".spi") { continue }
            do {
                let data = try await call { try await $0.downloadFile(signedURL: address) }
                store.writeFile(record.id, hash, data)
                added += data.count
            } catch {
                missing = true
            }
        }
        let extra = added, incomplete = missing
        store.exclusive {
            if extra > 0 { store.clearThumbnails(in: store.directory(record.id)) }
            store.update { library in
                // Only the size is added: the record may have been changed here since.
                library.notes[record.id]?.bytes += extra
                if incomplete {
                    var list = library.failedDownloads ?? [:]
                    list[record.id] = Library.FailedDownload(serverID: change.serverID, attempts: (list[record.id]?.attempts ?? 0) + 1)
                    library.failedDownloads = list
                }
            }
        }
        if incomplete { throw HTTPError(status: 0, what: "File download", detail: "a picture of a note could not be downloaded") }
    }

    // MARK: To the service

    private func pushNodes() async throws {
        let library = store.loadLibrary()
        var nodes: [TreeNode] = (library.dirtyNodes ?? []).compactMap { library.nodes[$0] }
        guard !nodes.isEmpty else { return }
        do {
            try await call { try await $0.patchFolder(nodes) }
        } catch let error as HTTPError where error.status == 409 {
            // Refused as older than what the service has: the nodes are stamped anew, here and
            // in the library, and sent once more.
            let stamp = Int64(Date().timeIntervalSince1970 * 1000)
            let ids = Set(nodes.map(\.id))
            store.update { library in
                for id in ids where library.dirtyNodes?.contains(id) == true {
                    let before = library.nodes[id]?.syncModifiedTime ?? 0
                    library.nodes[id]?.syncModifiedTime = max(before, stamp)
                }
            }
            let fresh = store.loadLibrary()
            nodes = ids.compactMap { fresh.nodes[$0] }
            guard !nodes.isEmpty else { return }
            try await call { try await $0.patchFolder(nodes) }
        }
        store.update { library in
            for node in nodes {
                if library.nodes[node.id]?.syncModifiedTime == node.syncModifiedTime { library.dirtyNodes?.remove(node.id) }
                if node.kind == .note { library.notes[node.id]?.nodeSent = true }
                // A deleted node that has been sent and has no note behind it has done its work.
                if node.state == .deleted, library.notes[node.id] == nil, library.pendingDeletes?[node.id] == nil, library.nodes[node.id]?.syncModifiedTime == node.syncModifiedTime { library.nodes[node.id] = nil }
            }
        }
    }

    /// What the strokes of a refused upload were like, for the log: points, size and options, none of the drawing.
    static func strokeShapes(_ strokes: [(id: String, time: String, data: Data)]) -> String {
        strokes.map { stroke in
            guard let ink = try? StrokeDecoder.decode(stroke.data) else { return "\(stroke.id.prefix(8)): unreadable" }
            return "\(stroke.id.prefix(8)) \(ink.points.count) points \(Int(ink.bounds.width))x\(Int(ink.bounds.height)) \(stroke.data.count) bytes" + (ink.style.colorType == 2 ? " tape" : "")
        }.joined(separator: "; ")
    }

    private func strokes(for file: NoteFile, noteID: String) -> [(id: String, time: String, data: Data)] {
        let data = store.strokeData(noteID)
        guard !data.isEmpty, let document = try? XMLTree.parse(file.data()) else { return [] }
        var out: [(id: String, time: String, data: Data)] = []
        for object in document.descendants("object") where object["type"] == "stroke" {
            if let id = object["id"], let time = object["modifiedTime"], let bytes = data[LocalStore.safeName(id)] { out.append((id, time, bytes)) }
        }
        return out
    }

    /// What goes out for one note, read in one piece with the note's record.
    private struct Outgoing {
        var record: NoteRecord
        var create: String
        var tree: String
        var file: NoteFile
        var strokes: [(id: String, time: String, data: Data)]
    }

    private func outgoing(_ noteID: String) -> Outgoing? {
        store.exclusive {
            guard let record = store.loadLibrary().notes[noteID], record.pending != nil, let file = try? store.noteFile(noteID) else { return nil }
            return Outgoing(record: record, create: file.uploadDocument(pages: true, body: true), tree: file.treeDocument(), file: file, strokes: strokes(for: file, noteID: noteID))
        }
    }

    /// Sends the files of a note that the service does not hold yet. `only` narrows it to the
    /// files the service asked for.
    private func pushFiles(_ out: Outgoing, only: Set<String>? = nil) async throws {
        var files: [(hash: String, size: Int)] = []
        let ours = Set(out.record.unsentFiles ?? [])
        for hash in out.file.fileIDs where only == nil || only!.contains(hash) {
            let url = store.mediaURL(out.record.id, hash)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > 0 {
                files.append((hash, size))
            } else if ours.contains(hash) {
                // A file added on this Mac and not sent yet has to be there: a note that names it must not go without it.
                throw HTTPError(status: 0, what: "File upload", detail: "a picture of this note is missing on this Mac")
            }
        }
        guard !files.isEmpty else { return }
        let asked = files
        let answer = try await call { try await $0.createUploadURLs(asked) }
        for file in asked {
            if let address = answer.created[file.hash] {
                let data = try Data(contentsOf: store.mediaURL(out.record.id, file.hash))
                try await call { try await $0.uploadFile(signedURL: address, data: data) }
            } else if !answer.held.contains(file.hash), ours.contains(file.hash) {
                throw HTTPError(status: 0, what: "File upload", detail: "the service gave no place for a picture")
            }
        }
    }

    private func pushNotes(progress: (@Sendable (Progress) -> Void)?) async throws {
        let waiting = store.loadLibrary().notes.values.filter { $0.pending != nil }.map(\.id)
        var done = 0
        var firstError: Error?
        for noteID in waiting {
            progress?(Progress(message: "Uploading notes…", done: done, total: waiting.count))
            done += 1
            // Record and files are read together, now: not from a list made before other uploads.
            guard let out = outgoing(noteID) else { continue }
            let record = out.record
            do {
                if record.pending == .create || record.serverID.isEmpty {
                    try await pushFiles(out)
                    let created = try await call { try await $0.createNote(document: out.create, strokes: out.strokes) }
                    settle(record, serverID: created.serverID, commitID: created.commitID, sentStrokes: out.strokes.map(\.id))
                } else {
                    let compared = try await call { try await $0.compareForUpsync(serverID: record.serverID, tree: out.tree) }
                    // The service has a version this Mac has not seen: the next round downloads it
                    // and keeps what was written here as a copy.
                    if let theirs = compared.commitID, !record.commitID.isEmpty, theirs != record.commitID { continue }
                    // Ink changed: the pages go along, and the strokes the service asks for, or, when
                    // its answer names none, the ones drawn here since the last upload.
                    var parts: [(id: String, time: String, data: Data)] = []
                    if record.pagesChanged == true {
                        let asked = out.strokes.filter { compared.wanted.contains($0.id) }
                        parts = asked.isEmpty ? out.strokes.filter { (record.unsentStrokes ?? []).contains($0.id) } : asked
                    }
                    let sending = parts
                    try await pushFiles(out, only: compared.wanted)
                    // Pages go when they changed here, and when the service says it lacks one.
                    let pages = record.pagesChanged == true || !compared.wanted.isDisjoint(with: out.file.pageAndLayerIDs)
                    let document = out.file.uploadDocument(pages: pages, body: compared.wantsBody, files: compared.wanted, floating: compared.wanted)
                    var commit: String
                    var sent = sending
                    do {
                        commit = try await call { try await $0.updateNote(serverID: record.serverID, document: document, strokes: sending) }
                    } catch let error as HTTPError where error.status == 400 {
                        // What kind of thing was refused, for the log: the shape of what was sent, none of its content.
                        HTTPClient.log?("update refused; sent: \(SyncEngine.shape(of: document)), strokes \(sending.count), asked for \(compared.wanted.count) parts, body \(compared.wantsBody), pages \(pages)")
                        // The service found strokes named in the pages without their records (2026-10-14: it then
                        // named every stroke of the page, those it had been sent before too). Once more, with the
                        // record of every stroke the pages name.
                        guard pages, error.detail.contains("strokeResource"), out.strokes.count > sending.count else { throw error }
                        sent = out.strokes
                        do {
                            commit = try await call { try await $0.updateNote(serverID: record.serverID, document: document, strokes: out.strokes) }
                            HTTPClient.log?("update accepted with every stroke of the note (\(out.strokes.count))")
                        } catch let again as HTTPError where again.status == 400 {
                            HTTPClient.log?("update refused again with every stroke of the note (\(out.strokes.count)): \(SyncEngine.strokeShapes(out.strokes))")
                            throw again
                        }
                    }
                    settle(record, serverID: record.serverID, commitID: commit.isEmpty ? record.commitID : commit, sentStrokes: sent.map(\.id))
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// Records an upload. The note counts as sent only if nothing was changed here since what
    /// went out was read; otherwise it stays waiting, without the strokes that did go.
    private func settle(_ sent: NoteRecord, serverID: String, commitID: String, sentStrokes: [String]) {
        store.update { library in
            guard var record = library.notes[sent.id] else { return }
            record.serverID = serverID
            record.commitID = commitID
            if record.revision == sent.revision {
                record.pending = nil
                record.unsentStrokes = nil
                record.pagesChanged = nil
                record.unsentFiles = nil
            } else {
                record.pending = .update
                record.unsentStrokes?.removeAll { sentStrokes.contains($0) }
            }
            library.notes[sent.id] = record
        }
    }

    private func pushDeletes() async throws {
        let library = store.loadLibrary()
        for (noteID, serverID) in library.pendingDeletes ?? [:] {
            let stamp = library.nodes[noteID]?.syncModifiedTime ?? Int64(Date().timeIntervalSince1970 * 1000)
            try await call { try await $0.deleteNote(serverID: serverID, syncModifiedTime: stamp) }
            store.update { $0.pendingDeletes?[noteID] = nil }
        }
    }
}
