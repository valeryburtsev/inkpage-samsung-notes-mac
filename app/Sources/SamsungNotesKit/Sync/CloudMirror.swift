import CloudKit
import CryptoKit
import Foundation

/// A file that arrived from the cloud: its name among the sync folder's files, and where its
/// content lies for the moment.
public struct CloudFile: Sendable {
    public var name: String
    public var url: URL
    /// True for a copy made only to be handed over: whoever takes it removes it.
    public var isTemporary = false
    public init(name: String, url: URL, isTemporary: Bool = false) { self.name = name; self.url = url; self.isTemporary = isTemporary }
}

/// What changed in the cloud since it was last asked.
public struct CloudChanges: Sendable {
    public var changed: [CloudFile] = []
    public var deleted: [String] = []
    /// The place in the cloud's history up to which this reaches: handed back next time.
    public var token: Data?
    /// True when the cloud could not say what changed since the token and lists everything
    /// anew: what is not among `changed` is gone.
    public var isEverything = false
    public init() {}
}

/// A cloud that keeps named files: the transport under `CloudMirror`. CloudKit is one,
/// Google Drive (`GoogleDriveFiles`) another; the tests have a third.
public protocol CloudFiles: Sendable {
    func changes(since token: Data?) async throws -> CloudChanges
    func save(_ files: [CloudFile]) async throws
    func delete(_ names: [String]) async throws
    /// The token to keep once a round's files are saved and deleted, for a cloud whose token
    /// would otherwise take this Mac's own files for news; nil keeps the one `changes` gave.
    func tokenAfterRound() async -> Data?
}

extension CloudFiles {
    public func tokenAfterRound() async -> Data? { nil }
}

/// Sync through a cloud that is not a folder on this Mac (CloudKit, Google Drive's own
/// interface): the same folder of files that `FolderSync` keeps in iCloud Drive, held in the
/// cloud one record or file for each. A copy of that folder
/// lies on this Mac; each round brings to the copy what changed in the cloud, lets
/// `FolderSync` bring the copy and the notes to the same state, and sends to the cloud what
/// that changed in the copy. Everything `FolderSync` does about versions, conflicts, deleted
/// notes and encryption holds here as it does there.
public final class CloudMirror: @unchecked Sendable {
    struct State: Codable {
        var token: Data?
        /// The files the cloud is known to have, each with a mark of its content as it lies in the copy.
        var known: [String: String] = [:]
    }

    let store: LocalStore
    let cloud: CloudFiles
    public let folder: URL
    private let stateURL: URL
    private let files = FileManager.default

    /// `folder` is where the copy of the cloud's files lies on this Mac.
    public init(store: LocalStore, cloud: CloudFiles, folder: URL) {
        self.store = store
        self.cloud = cloud
        self.folder = folder
        stateURL = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "-state.json")
    }

    private func loadState() -> State { (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State() }
    private func save(_ state: State) { try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic) }

    /// A mark of a file as it lies in the copy: its length and when it was written. (Files
    /// here are written once and then left alone, but for the small ones of the tree.)
    private func mark(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize else { return nil }
        return "\(size):\(Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000))"
    }

    /// Every file of the copy, by its name from the copy's top.
    private func present() -> [String: URL] {
        var out: [String: URL] = [:]
        let base = folder.standardizedFileURL.path
        guard let walk = files.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, !url.lastPathComponent.hasPrefix(".") else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            out[String(path.dropFirst(base.count + 1))] = url
        }
        return out
    }

    private func safe(_ name: String) -> URL? {
        // A name from the cloud stays inside the copy.
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, name.utf8.count < 512, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return parts.reduce(folder) { $0.appendingPathComponent(String($1)) }
    }

    /// The folder's own vault file, read and written as `FolderSync` does it.
    public func folderSync() -> FolderSync { FolderSync(store: store, folder: folder) }

    /// One round. `prepare` is given the `FolderSync` that will run, to hand it the vault's key.
    public func sync(resolve: [String: FolderSync.Resolution] = [:], prepare: (FolderSync) -> Void = { _ in }) async throws -> FolderSync.Outcome {
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        var state = loadState()
        // From the cloud into the copy.
        let changes = try await cloud.changes(since: state.token)
        if changes.isEverything {
            let listed = Set(changes.changed.map(\.name))
            for (name, url) in present() where !listed.contains(name) && state.known[name] != nil { try? files.removeItem(at: url) }
            state.known = state.known.filter { listed.contains($0.key) }
        }
        for file in changes.changed {
            guard let target = safe(file.name) else { continue }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: file.url)
            if file.isTemporary { try? files.removeItem(at: file.url) }
            try data.write(to: target, options: .atomic)
            state.known[file.name] = mark(target)
        }
        for name in changes.deleted {
            if let target = safe(name) { try? files.removeItem(at: target) }
            state.known[name] = nil
        }
        state.token = changes.token
        save(state)

        // The copy and the notes.
        let sync = folderSync()
        prepare(sync)
        let outcome = try sync.sync(resolve: resolve)

        // From the copy into the cloud: what is new or changed there, and what is gone.
        let now = present()
        var sending: [CloudFile] = []
        var marks: [String: String] = [:]
        for (name, url) in now {
            guard let mark = mark(url) else { continue }
            if state.known[name] != mark { sending.append(CloudFile(name: name, url: url)); marks[name] = mark }
        }
        let gone = state.known.keys.filter { now[$0] == nil }
        if !sending.isEmpty {
            try await cloud.save(sending)
            for (name, mark) in marks { state.known[name] = mark }
            save(state)
        }
        if !gone.isEmpty {
            try await cloud.delete(gone)
            for name in gone { state.known[name] = nil }
            save(state)
        }
        if !sending.isEmpty || !gone.isEmpty, let token = await cloud.tokenAfterRound() {
            state.token = token
            save(state)
        }
        return outcome
    }

    /// True once a round has taken what the cloud holds: until then the copy says nothing about the cloud.
    public var hasSynced: Bool { loadState().token != nil }

    /// Forgets the copy, so that the next round begins by taking everything from the cloud.
    public func reset() {
        try? files.removeItem(at: folder)
        try? files.removeItem(at: stateURL)
    }
}

/// A folder on this Mac as the cloud: what the checks put in the place of a real one.
public struct DirectoryCloud: CloudFiles {
    let folder: URL
    public init(folder: URL) { self.folder = folder }

    private func listed() -> [String: String] {
        var out: [String: String] = [:]
        let base = folder.standardizedFileURL.path
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return out }
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            out[String(path.dropFirst(base.count + 1))] = "\(values.fileSize ?? 0):\(Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000))"
        }
        return out
    }

    public func changes(since token: Data?) async throws -> CloudChanges {
        let before = token.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        let now = listed()
        var out = CloudChanges()
        out.isEverything = before == nil
        out.changed = now.filter { before?[$0.key] != $0.value }.map { CloudFile(name: $0.key, url: folder.appendingPathComponent($0.key)) }
        out.deleted = (before ?? [:]).keys.filter { now[$0] == nil }
        out.token = try JSONEncoder().encode(now)
        return out
    }

    public func save(_ files: [CloudFile]) async throws {
        for file in files {
            let target = folder.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: file.url).write(to: target, options: .atomic)
        }
    }

    public func delete(_ names: [String]) async throws {
        for name in names { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    public func tokenAfterRound() async -> Data? { try? JSONEncoder().encode(listed()) }
}

/// CloudKit as the cloud: the user's private database of the app's iCloud container, a zone
/// of its own, and in it one record for every file, with the file as the record's asset.
///
/// Needs the app to be signed with the iCloud capability for the container; without it the
/// system ends the app at the first use of the container, so `isEntitled` is asked first.
public struct CloudKitFiles: CloudFiles {
    public static let recordType = "File"

    let containerID: String
    let zoneID: CKRecordZone.ID

    public init(containerID: String, zone: String = "Notes") {
        self.containerID = containerID
        zoneID = CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
    }

    private var database: CKDatabase { CKContainer(identifier: containerID).privateCloudDatabase }

    /// True when this app was signed with the entitlement for CloudKit.
    public static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil), let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else { return false }
        return (value as? [String])?.contains { $0.hasPrefix("CloudKit") } ?? false
    }

    /// Whether the Mac is signed in to iCloud, said in words when it is not.
    public func unavailable() async -> String? {
        switch try? await CKContainer(identifier: containerID).accountStatus() {
        case .available?: return nil
        case .noAccount?: return "This Mac is not signed in to iCloud."
        case .restricted?: return "iCloud is restricted on this Mac."
        case .temporarilyUnavailable?: return "iCloud is not available at the moment."
        default: return "iCloud's state could not be read."
        }
    }

    private func ensureZone() async throws { _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []) }

    private static func archive(_ token: CKServerChangeToken) -> Data? { try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) }
    private static func token(_ data: Data?) -> CKServerChangeToken? { data.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) } }

    public func changes(since data: Data?) async throws -> CloudChanges {
        var out = CloudChanges()
        var token = CloudKitFiles.token(data)
        out.isEverything = token == nil
        while true {
            do {
                let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (id, result) in page.modificationResultsByID {
                    guard case .success(let change) = result, let asset = change.record["data"] as? CKAsset, let url = asset.fileURL else { continue }
                    // The system keeps a downloaded asset only as long as it pleases: it is copied at once.
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("snotes-cloud-" + UUID().uuidString)
                    try FileManager.default.copyItem(at: url, to: copy)
                    out.changed.append(CloudFile(name: id.recordName, url: copy, isTemporary: true))
                }
                out.deleted.append(contentsOf: page.deletions.map(\.recordID.recordName))
                token = page.changeToken
                if !page.moreComing { break }
            } catch let error as CKError where error.code == .changeTokenExpired {
                // The place in the history is too old to be continued from: everything is listed anew.
                out = CloudChanges()
                out.isEverything = true
                token = nil
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                // Nothing there yet: the zone is made, and it is empty.
                try await ensureZone()
                out = CloudChanges()
                out.isEverything = true
                return out
            }
        }
        if out.isEverything { out.deleted = [] }
        out.token = token.flatMap(CloudKitFiles.archive)
        return out
    }

    public func save(_ files: [CloudFile]) async throws {
        // In batches: a request holds a few hundred records at most, and not too many bytes.
        var batch: [CKRecord] = []
        var bytes = 0
        func send() async throws {
            guard !batch.isEmpty else { return }
            let records = batch
            batch = []
            bytes = 0
            do {
                let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
                for (_, saved) in result.saveResults { if case .failure(let error) = saved { throw error } }
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                try await ensureZone()
                let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
                for (_, saved) in result.saveResults { if case .failure(let error) = saved { throw error } }
            }
        }
        for file in files {
            let record = CKRecord(recordType: CloudKitFiles.recordType, recordID: CKRecord.ID(recordName: file.name, zoneID: zoneID))
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            record["data"] = CKAsset(fileURL: file.url)
            record["size"] = size as NSNumber
            batch.append(record)
            bytes += size
            if batch.count >= 100 || bytes > 30_000_000 { try await send() }
        }
        try await send()
    }

    public func delete(_ names: [String]) async throws {
        for start in stride(from: 0, to: names.count, by: 200) {
            let ids = names[start..<min(start + 200, names.count)].map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            let result = try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
            for (_, deleted) in result.deleteResults {
                // One that is gone already is as wanted.
                if case .failure(let error) = deleted, (error as? CKError)?.code != .unknownItem { throw error }
            }
        }
    }

    /// Removes the zone with everything in it. For a zone made only to try the service.
    public func removeZone() async throws { _ = try await database.modifyRecordZones(saving: [], deleting: [zoneID]) }
}
