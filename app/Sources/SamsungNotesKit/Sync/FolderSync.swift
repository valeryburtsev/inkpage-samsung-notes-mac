import CryptoKit
import Foundation

/// Sync with a folder that some other service keeps the same on every device: iCloud Drive,
/// or this Mac's copy of what a cloud holds (see `CloudMirror`).
///
/// The folder holds, under `notes/<note id>/`, each note as a file that is never changed once
/// written (`<number>-<device>.snote`: the note's document and strokes, zipped) and, beside
/// it, the note's attached files under their content hashes; and under `tree/` one small file
/// per folder and per note's place among the folders. A Mac that changes a note writes a new
/// file that names the file it replaces, and then removes that one. So nothing is ever written
/// over by two Macs at once, and a note changed on two Macs shows as what it is: two files
/// that both replace the same one, or a file that replaces something other than what this Mac
/// last saw while the note changed here too. Such a note is left as it is on both sides until
/// the user says which to keep.
///
/// Locked notes are written encrypted when the folder has a vault (see `Vault`): the note,
/// its attached files and its title.
public final class FolderSync: @unchecked Sendable {
    /// A note that changed here and in the folder since the two last agreed.
    public struct Conflict: Identifiable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var modifiedHere: Date?
        public var modifiedThere: Date
        public var deviceThere: String
    }

    public enum Resolution: Sendable { case keepMine, keepTheirs, keepBoth }

    public struct Outcome: Sendable, Equatable {
        public var uploaded = 0
        public var downloaded = 0
        public var removed = 0
        public var conflicts: [Conflict] = []
        /// Encrypted notes in the folder that this Mac has no key for yet.
        public var sealedWithoutKey = 0
        /// Files the folder's service has not brought to this Mac yet.
        public var notHereYet = 0
        /// The notes that were replaced here, added or taken away.
        public var arrived: [String] = []
    }

    public enum Failure: Error { case noFolder, damaged(String) }

    /// What a version file says of itself before its content.
    struct Header: Codable {
        var format = 1
        var id: String
        var parents: [String]
        var device: String
        var deviceName: String
        var modified: Int64
        /// Not there for a sealed note: its title is part of what is sealed.
        var title: String?
        var locked: Bool
        var sealed: Bool
        var fingerprint: String
        var media: [String]
    }

    /// A folder's or a note's place in the tree, as its file in the folder has it.
    struct Place: Codable {
        var node: TreeNode
        /// The name of a locked note, encrypted, when the folder has a vault.
        var sealedName: String?
        var device: String
    }

    struct Version {
        var name: String
        var url: URL
        var header: Header
    }

    static let magic = Data("SNOTE1\n".utf8)

    let store: LocalStore
    let folder: URL
    let deviceName: String
    /// The key for locked notes, when this Mac holds it; and whether new versions are to be sealed.
    public var vault: Vault?
    public var seals = false
    private let files = FileManager.default

    public init(store: LocalStore, folder: URL, deviceName: String = Host.current().localizedName ?? "Mac", vault: Vault? = nil, seals: Bool = false) {
        self.store = store
        self.folder = folder
        self.deviceName = deviceName
        self.vault = vault
        self.seals = seals && vault != nil
    }

    private var notesFolder: URL { folder.appendingPathComponent("notes") }
    private var treeFolder: URL { folder.appendingPathComponent("tree") }
    private var vaultURL: URL { folder.appendingPathComponent("vault.json") }

    // MARK: The vault's file

    /// The locked key that lies in the folder, when encrypting was ever switched on for it.
    public func lockedVault() -> Vault.Locked? {
        (try? Data(contentsOf: vaultURL)).flatMap { try? JSONDecoder().decode(Vault.Locked.self, from: $0) }
    }

    public func writeLockedVault(_ locked: Vault.Locked) throws {
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(locked).write(to: vaultURL, options: .atomic)
    }

    // MARK: Reading the folder

    private func device() -> String {
        if let known = store.loadLibrary().folderDevice { return known }
        let made = String(UUID().uuidString.lowercased().prefix(8))
        store.update { $0.folderDevice = made }
        return made
    }

    private static func header(at url: URL) throws -> (Header, Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: magic.count + 4) ?? Data()
        guard head.count == magic.count + 4, head.prefix(magic.count) == magic else { throw Failure.damaged(url.lastPathComponent) }
        let length = head.suffix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard length > 0, length < 1_000_000, let json = try handle.read(upToCount: length), json.count == length else { throw Failure.damaged(url.lastPathComponent) }
        return (try JSONDecoder().decode(Header.self, from: json), magic.count + 4 + length)
    }

    /// Every note's versions in the folder, and the notes that have a version the service has
    /// listed but not brought here: those wait, for what they are is not known yet.
    private func scan(_ outcome: inout Outcome) -> (versions: [String: [Version]], waiting: Set<String>) {
        var out: [String: [Version]] = [:]
        var waiting = Set<String>()
        for id in (try? files.contentsOfDirectory(atPath: notesFolder.path)) ?? [] where !id.hasPrefix(".") {
            let home = notesFolder.appendingPathComponent(id)
            for name in (try? files.contentsOfDirectory(atPath: home.path)) ?? [] {
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    // A file iCloud has only announced: it is asked for, and waited for.
                    let real = String(name.dropFirst().dropLast(7))
                    try? files.startDownloadingUbiquitousItem(at: home.appendingPathComponent(real))
                    if real.hasSuffix(".snote") { waiting.insert(id) } else { outcome.notHereYet += 1 }
                    continue
                }
                guard name.hasSuffix(".snote") else { continue }
                let url = home.appendingPathComponent(name)
                do {
                    let (header, _) = try FolderSync.header(at: url)
                    guard header.id == id else { continue }
                    out[id, default: []].append(Version(name: name, url: url, header: header))
                } catch let error where error is Failure || error is DecodingError {
                    // Not a version, or one still being written: a fresh one is waited for, an old one passed over.
                    let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if Date().timeIntervalSince(written) < 600 { waiting.insert(id) }
                } catch {
                    // Listed and not readable: the service keeps it in the cloud and cannot bring it now.
                    waiting.insert(id)
                }
            }
        }
        return (out, waiting)
    }

    /// The versions that no other version in the folder replaces, newest first.
    private static func heads(_ versions: [Version]) -> [Version] {
        let replaced = Set(versions.flatMap(\.header.parents))
        return versions.filter { !replaced.contains($0.name) }.sorted { ($0.header.modified, $0.name) > ($1.header.modified, $1.name) }
    }

    // MARK: The tree

    private static func placeName(_ id: String) -> String { Data(SHA256.hash(data: Data(id.utf8))).prefix(16).map { String(format: "%02x", $0) }.joined() + ".json" }

    private func writePlace(_ node: TreeNode, locked: Bool, device: String) {
        var place = Place(node: node, sealedName: nil, device: device)
        if locked, seals, let vault, node.kind == .note, let sealed = try? vault.seal(Data(node.name.utf8), as: "name:" + node.id) {
            place.node.name = ""
            place.sealedName = sealed.base64EncodedString()
        }
        guard let data = try? JSONEncoder().encode(place) else { return }
        try? data.write(to: treeFolder.appendingPathComponent(FolderSync.placeName(node.id)), options: .atomic)
    }

    /// Brings the folders, and the notes' places among them, to the same state here and there:
    /// of two that differ, the one changed last holds.
    private func mergeTree(device: String) {
        var there: [String: Place] = [:]
        var extra: [URL] = []
        for name in (try? files.contentsOfDirectory(atPath: treeFolder.path)) ?? [] where name.hasSuffix(".json") {
            let url = treeFolder.appendingPathComponent(name)
            guard let place = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder().decode(Place.self, from: $0) }) else { continue }
            // A copy the service made of a file written on two Macs at once: the newer holds, the copy goes.
            if name != FolderSync.placeName(place.node.id) { extra.append(url) }
            if let known = there[place.node.id], known.node.syncModifiedTime >= place.node.syncModifiedTime { continue }
            there[place.node.id] = place
        }
        for url in extra { try? files.removeItem(at: url) }
        let library = store.loadLibrary()
        var taken: [TreeNode] = []
        for (id, place) in there {
            var node = place.node
            if let sealed = place.sealedName.flatMap({ Data(base64Encoded: $0) }) {
                // Without the key the name stays what this Mac has for it, or empty.
                node.name = vault.flatMap { try? $0.open(sealed, as: "name:" + id) }.map { String(decoding: $0, as: UTF8.self) } ?? library.nodes[id]?.name ?? ""
            }
            if let mine = library.nodes[id] {
                if node.syncModifiedTime > mine.syncModifiedTime { taken.append(node) }
            } else if node.state != .deleted {
                taken.append(node)
            }
        }
        if !taken.isEmpty { store.update { library in for node in taken { library.nodes[node.id] = node } } }
        let now = store.loadLibrary()
        for node in now.nodes.values {
            let known = there[node.id]?.node.syncModifiedTime
            guard known == nil || node.syncModifiedTime > known! else { continue }
            // A place is written for a folder, and for a note that is here or is known to the folder.
            if node.kind == .note, now.notes[node.id] == nil, now.folderLinks?[node.id] == nil, known == nil { continue }
            writePlace(node, locked: now.notes[node.id]?.isLocked ?? false, device: device)
        }
    }

    // MARK: Writing and reading a note

    private func mediaName(_ hash: String, sealed: Bool) -> String { LocalStore.safeName(hash) + (sealed ? ".x" : "") }

    /// Writes the note as it is here into the folder as a new version, in the place of `parents`.
    private func upload(_ noteID: String, record: NoteRecord, fingerprint: String, parents: [Version], all: [Version], device: String) throws -> Library.FolderLink {
        let home = notesFolder.appendingPathComponent(noteID)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        let sealed = record.isLocked && seals && vault != nil
        let local = store.directory(noteID)
        let parts = store.partNames(noteID)
        var entries = [Zip.Entry(name: "note.xml", data: try Data(contentsOf: store.noteURL(noteID)))]
        for name in parts.strokes {
            entries.append(Zip.Entry(name: "strokes/\(name).bin", data: try Data(contentsOf: local.appendingPathComponent("strokes").appendingPathComponent(name + ".bin"))))
        }
        // Attached files lie beside the versions, each written once: a note with a large
        // picture does not send the picture again whenever its text changes.
        for name in parts.media {
            let target = home.appendingPathComponent(mediaName(name, sealed: sealed))
            guard !files.fileExists(atPath: target.path) else { continue }
            var data = try Data(contentsOf: local.appendingPathComponent("media").appendingPathComponent(name))
            if sealed, let vault { data = try vault.seal(data, as: "media:\(noteID):\(name)") }
            try data.write(to: target, options: .atomic)
        }
        let number = (all.compactMap { Int($0.name.prefix { $0.isNumber }) }.max() ?? 0) + 1
        let name = String(format: "%06d-%@.snote", number, device)
        let header = Header(id: noteID, parents: parents.map(\.name), device: device, deviceName: deviceName, modified: Int64(record.modifiedAt.timeIntervalSince1970 * 1000),
                            title: sealed ? nil : record.title, locked: record.isLocked, sealed: sealed, fingerprint: fingerprint, media: parts.media)
        var payload = Zip.write(entries)
        if sealed, let vault { payload = try vault.seal(payload, as: "note:\(noteID):\(name)") }
        let json = try JSONEncoder().encode(header)
        var out = FolderSync.magic
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((json.count >> shift) & 0xFF)) }
        out.append(json)
        out.append(payload)
        try out.write(to: home.appendingPathComponent(name), options: .atomic)
        // What it replaces goes, and attached files the note no longer has (in either form).
        for parent in parents { try? files.removeItem(at: parent.url) }
        let kept = Set(parts.media.map { mediaName($0, sealed: sealed) })
        for found in (try? files.contentsOfDirectory(atPath: home.path)) ?? [] where !found.hasSuffix(".snote") && !found.hasPrefix(".") && !kept.contains(found) {
            try? files.removeItem(at: home.appendingPathComponent(found))
        }
        return Library.FolderLink(version: name, fingerprint: fingerprint, sealed: sealed)
    }

    private enum Fetch: Error { case noKey, notHereYet }

    /// Takes a version from the folder in the place of the note here (or as a new note).
    private func download(_ version: Version) throws -> Library.FolderLink {
        let header = version.header
        let home = version.url.deletingLastPathComponent()
        if header.sealed, vault == nil { throw Fetch.noKey }
        let whole = try Data(contentsOf: version.url)
        guard let (_, start) = try? FolderSync.header(at: version.url) else { throw Failure.damaged(version.name) }
        var payload = whole.subdata(in: start..<whole.count)
        if header.sealed, let vault { payload = try vault.open(payload, as: "note:\(header.id):\(version.name)") }
        let entries = try Zip.read(payload, limit: 512 * 1024 * 1024)
        guard let xml = entries.first(where: { $0.name == "note.xml" })?.data else { throw Failure.damaged(version.name) }
        var strokes: [String: Data] = [:]
        for entry in entries where entry.name.hasPrefix("strokes/") && entry.name.hasSuffix(".bin") { strokes[String(entry.name.dropFirst(8).dropLast(4))] = entry.data }
        var media: [String: Data] = [:]
        for hash in header.media {
            let url = home.appendingPathComponent(mediaName(hash, sealed: header.sealed))
            guard files.fileExists(atPath: url.path) else {
                // Announced by the service and not here yet: the note waits for all of itself.
                try? files.startDownloadingUbiquitousItem(at: url)
                throw Fetch.notHereYet
            }
            var data = try Data(contentsOf: url)
            if header.sealed, let vault { data = try vault.open(data, as: "media:\(header.id):\(hash)") }
            media[hash] = data
        }
        try store.exclusive {
            let before = store.loadLibrary().notes[header.id]
            var record = try store.replace(xml: xml, strokes: strokes, media: media, deviceName: header.deviceName)
            // How it stands with Samsung's service is kept: there it now waits to be sent.
            record.serverID = before?.serverID ?? ""
            record.commitID = before?.commitID ?? ""
            record.pending = record.serverID.isEmpty ? .create : .update
            record.pagesChanged = true
            record.nodeSent = before?.nodeSent
            record.revision = (before?.revision ?? 0) + 1
            record.inkText = nil
            let kept = record
            store.update { library in
                library.notes[kept.id] = kept
                if library.nodes[kept.id] == nil { library.nodes[kept.id] = TreeNode(id: kept.id, kind: .note, name: kept.title, now: kept.modifiedAt) }
            }
        }
        return Library.FolderLink(version: version.name, fingerprint: store.fingerprint(header.id) ?? header.fingerprint, sealed: header.sealed)
    }

    // MARK: One round

    /// Brings this Mac and the folder to the same state, as far as that can be done without
    /// asking: notes changed on one side go to the other; notes changed on both are reported
    /// and left alone unless `resolve` says what to do with them.
    public func sync(resolve: [String: Resolution] = [:]) throws -> Outcome {
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: folder.deletingLastPathComponent().path, isDirectory: &isFolder), isFolder.boolValue else { throw Failure.noFolder }
        try files.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        try files.createDirectory(at: treeFolder, withIntermediateDirectories: true)
        let device = device()
        var outcome = Outcome()
        mergeTree(device: device)
        let (remote, waiting) = scan(&outcome)
        let library = store.loadLibrary()
        let links = library.folderLinks ?? [:]
        var changedNodes: [TreeNode] = []

        for id in Set(library.notes.keys).union(remote.keys).union(links.keys).sorted() {
            // A note with a version that cannot be read yet is left as it is on both sides: taken
            // for absent, it would be written anew and then stand against itself.
            if waiting.contains(id) { outcome.notHereYet += 1; continue }
            let record = library.notes[id]
            let versions = remote[id] ?? []
            var heads = FolderSync.heads(versions)
            if heads.count > 1, let first = heads.first, heads.allSatisfy({ $0.header.fingerprint == first.header.fingerprint && $0.header.sealed == first.header.sealed }) {
                // The same note written twice (by two Macs, or by one that could not see its own): one is enough.
                for other in heads.dropFirst() { try? files.removeItem(at: other.url) }
                heads = [first]
            }
            let link = links[id]
            let node = store.loadLibrary().nodes[id]
            func keep(_ made: Library.FolderLink?) { store.update { library in var all = library.folderLinks ?? [:]; all[id] = made; library.folderLinks = all } }
            do {
                guard let record else {
                    guard let newest = heads.first else { keep(nil); continue }
                    if let link, heads.count == 1, newest.name == link.version, library.folderDeletes?.contains(id) == true {
                        // Deleted for good here since it was last seen there: it goes there too.
                        try? files.removeItem(at: notesFolder.appendingPathComponent(id))
                        var gone = node ?? TreeNode(id: id, kind: .note, name: "")
                        gone.state = .deleted
                        gone.syncModifiedTime = max(gone.syncModifiedTime, Int64(Date().timeIntervalSince1970 * 1000))
                        changedNodes.append(gone)
                        keep(nil)
                        outcome.removed += 1
                    } else if node?.state == .deleted, link == nil || versions.allSatisfy({ $0.header.modified <= (node?.syncModifiedTime ?? 0) }) {
                        // Deleted on another Mac, and what lies there is what was deleted: it is cleared away.
                        try? files.removeItem(at: notesFolder.appendingPathComponent(id))
                        keep(nil)
                    } else {
                        keep(try download(newest))
                        outcome.downloaded += 1; outcome.arrived.append(id)
                        if node?.state == .deleted { var back = node!; back.state = .normal; back.syncModifiedTime = Int64(Date().timeIntervalSince1970 * 1000); changedNodes.append(back) }
                    }
                    continue
                }
                guard let fingerprint = store.fingerprint(id) else { continue }
                let wantsSealed = record.isLocked && seals && vault != nil
                let changedHere = link == nil || link!.fingerprint != fingerprint || link!.sealed != wantsSealed
                guard let newest = heads.first else {
                    if link != nil, !changedHere, node?.state == .deleted {
                        // Deleted on another Mac and not touched here since: it goes here too.
                        store.exclusive {
                            store.update { $0.notes[id] = nil }
                            store.remove(id)
                        }
                        keep(nil)
                        outcome.removed += 1
                        outcome.arrived.append(id)
                    } else {
                        // Not there (yet, or any more) and wanted here: it is written there.
                        if node?.state == .deleted, var back = node { back.state = .normal; back.syncModifiedTime = Int64(Date().timeIntervalSince1970 * 1000); changedNodes.append(back) }
                        keep(try upload(id, record: record, fingerprint: fingerprint, parents: [], all: versions, device: device))
                        outcome.uploaded += 1
                    }
                    continue
                }
                let changedThere = link == nil || heads.count > 1 || newest.name != link!.version
                // The same on both sides, however it came about: only noted.
                if heads.count == 1, newest.header.fingerprint == fingerprint, newest.header.sealed == wantsSealed {
                    if changedHere || changedThere { keep(Library.FolderLink(version: newest.name, fingerprint: fingerprint, sealed: newest.header.sealed)) }
                    continue
                }
                switch (changedHere, changedThere) {
                case (false, false):
                    continue
                case (true, false):
                    keep(try upload(id, record: record, fingerprint: fingerprint, parents: heads, all: versions, device: device))
                    outcome.uploaded += 1
                case (false, true) where heads.count == 1:
                    keep(try download(newest))
                    outcome.downloaded += 1; outcome.arrived.append(id)
                default:
                    switch resolve[id] {
                    case .keepMine?:
                        keep(try upload(id, record: record, fingerprint: fingerprint, parents: heads, all: versions, device: device))
                        outcome.uploaded += 1
                    case .keepBoth?:
                        _ = try LocalEdits(store: store).keepCopy(of: id, suffix: " (this Mac's version)")
                        fallthrough
                    case .keepTheirs?:
                        keep(try download(newest))
                        for other in heads.dropFirst() { try? files.removeItem(at: other.url) }
                        outcome.downloaded += 1; outcome.arrived.append(id)
                    case nil:
                        outcome.conflicts.append(Conflict(id: id, title: record.title, modifiedHere: record.modifiedAt, modifiedThere: Date(timeIntervalSince1970: Double(newest.header.modified) / 1000), deviceThere: newest.header.deviceName))
                    }
                }
            } catch Fetch.noKey {
                outcome.sealedWithoutKey += 1
            } catch Fetch.notHereYet {
                outcome.notHereYet += 1
            }
        }
        if !changedNodes.isEmpty {
            store.update { library in for node in changedNodes { library.nodes[node.id] = node } }
        }
        // Places that changed in this round (a note that arrived, one that was deleted) are written.
        mergeTree(device: device)
        store.update { library in
            library.lastSync = Date()
            // What was deleted here has been told, or was changed there meanwhile and is back.
            library.folderDeletes = nil
        }
        return outcome
    }

    /// How many notes on this Mac the folder also holds, unchanged here since: what "remove the
    /// folder's notes from this Mac" would take away.
    public static func removable(in store: LocalStore) -> Int {
        let library = store.loadLibrary()
        return (library.folderLinks ?? [:]).filter { library.notes[$0.key] != nil && store.fingerprint($0.key) == $0.value.fingerprint }.count
    }

    /// Takes the notes the folder holds off this Mac (they stay in the folder), but for those
    /// changed here since they were last synced, which stay as notes of this Mac alone.
    public static func detach(from store: LocalStore) {
        store.exclusive {
            let library = store.loadLibrary()
            let going = (library.folderLinks ?? [:]).filter { library.notes[$0.key] != nil && store.fingerprint($0.key) == $0.value.fingerprint }.map(\.key)
            for id in going { store.remove(id) }
            store.update { library in
                for id in going {
                    library.notes[id] = nil
                    library.nodes[id] = nil
                    library.dirtyNodes?.remove(id)
                }
                library.folderLinks = nil
                library.folderDeletes = nil
            }
        }
    }

    /// Forgets what this Mac and the folder agreed on, when the folder is no longer synced with.
    public static func forget(in store: LocalStore) { store.update { $0.folderLinks = nil } }

    /// Says which folder is synced with from now on (`home` names it: a service, an account).
    /// What was agreed with another folder says nothing about this one, and is forgotten: a
    /// note that both hold and that differs is then asked about, not overwritten.
    public static func settle(in store: LocalStore, home: String) {
        // Libraries from before folders had names were synced with iCloud Drive.
        guard (store.loadLibrary().folderHome ?? "icloud") != home else { return }
        store.update { library in
            library.folderLinks = nil
            library.folderDeletes = nil
            library.folderHome = home
        }
    }
}
