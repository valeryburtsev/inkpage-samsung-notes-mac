import Foundation

/// A folder or a note's place in the folder tree, as the service's folder feed lists it.
public struct TreeNode: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case folder, note }
    public enum State: String, Codable, Sendable { case normal, trashed, deleted }
    public var id: String
    public var kind: Kind
    public var state: State
    public var parentID: String
    public var name: String
    public var color: Int32
    public var order: Int
    public var syncModifiedTime: Int64
    public var createdTime: Int64
    public var lastModifiedTime: Int64
    public var trashedTime: Int64
    public var restorePath: String?

    public static let rootID = "root"

    public init(id: String, kind: Kind, parentID: String = TreeNode.rootID, name: String, color: Int32 = 0, order: Int = 999_999, now: Date = Date()) {
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        self.id = id
        self.kind = kind
        state = .normal
        self.parentID = parentID
        self.name = name
        self.color = color
        self.order = order
        syncModifiedTime = millis
        createdTime = kind == .folder ? millis : 0
        lastModifiedTime = millis
        trashedTime = 0
        restorePath = nil
    }

    /// The node as the folder service takes it in a change.
    func uploadXML(deviceName: String, now: Date) -> String {
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        let shownName = name.isEmpty ? " " : name
        var xml = "<node id=\"\(id.escapedXML)\" type=\"\(kind.rawValue)\"><parentFolderNodeId>\(parentID.escapedXML)</parentFolderNodeId><syncModifiedTime>\(syncModifiedTime)</syncModifiedTime>"
        xml += "<createdTime>\(createdTime)</createdTime><lastModifiedTime>\(lastModifiedTime)</lastModifiedTime><name>\(Data(shownName.utf8).base64EncodedString())</name><state>\(state.rawValue)</state>"
        if let restorePath, state != .normal { xml += "<restorePath>\(Data(restorePath.utf8).base64EncodedString())</restorePath>" }
        let device = "{\"model\":\"\(deviceName.replacingOccurrences(of: "\"", with: ""))\",\"ver\":\"\(CloudIdentity.appVersion)\"}"
        xml += "<trashedTime>\(trashedTime)</trashedTime><isSyncWithMS>0</isSyncWithMS><color>\(color)</color><order>\(order)</order><requestTime>\(millis)</requestTime><requestDevice>\(device.escapedXML)</requestDevice></node>"
        return xml
    }

    init?(_ node: XMLNode) {
        guard let id = node["id"], let kind = Kind(rawValue: node["type"] ?? "") else { return nil }
        self.id = id
        self.kind = kind
        state = State(rawValue: node.value("state") ?? "normal") ?? .normal
        parentID = node.value("parentFolderNodeId") ?? TreeNode.rootID
        name = node.value("name")?.decodedBase64 ?? ""
        color = node.value("color").flatMap { Int32($0) } ?? 0
        order = node.value("order").flatMap { Int($0) } ?? 999_999
        syncModifiedTime = node.value("syncModifiedTime").flatMap { Int64($0) } ?? 0
        createdTime = node.value("createdTime").flatMap { Int64($0) } ?? 0
        lastModifiedTime = node.value("lastModifiedTime").flatMap { Int64($0) } ?? 0
        trashedTime = node.value("trashedTime").flatMap { Int64($0) } ?? 0
        restorePath = node.value("restorePath")?.decodedBase64
    }
}

/// One entry of the notes change feed.
public struct NoteChange: Sendable {
    public var serverID: String
    public var resourceID: String
    public var commitID: String
    public var syncModifiedTime: Int64
    public var serverModifiedTime: Int64
    public var isDeleted: Bool
    public var isLocked: Bool
    public var isEncrypted: Bool
    public var deviceName: String

    /// A change made up here, to fetch a note again whose download failed.
    init(serverID: String, resourceID: String) {
        self.serverID = serverID
        self.resourceID = resourceID
        commitID = ""
        syncModifiedTime = 0
        serverModifiedTime = 0
        isDeleted = false
        isLocked = false
        isEncrypted = false
        deviceName = ""
    }

    init?(_ node: XMLNode) {
        guard let server = node.value("serverId"), let resource = node.value("resourceId") else { return nil }
        serverID = server
        resourceID = resource
        commitID = node.value("commitId") ?? ""
        syncModifiedTime = node.value("syncModifiedTime").flatMap { Int64($0) } ?? 0
        serverModifiedTime = node.value("serverModifiedTime").flatMap { Int64($0) } ?? 0
        isDeleted = node.value("isDeleted") == "true"
        isLocked = node.value("isLocked") == "true"
        isEncrypted = node.value("isEncrypted") == "true"
        deviceName = node.value("modelName")?.decodedBase64 ?? ""
    }
}

/// What the library remembers about a downloaded note without opening its document.
public struct NoteRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String                 // the note's UUID, shared by all devices
    public var serverID: String
    public var commitID: String
    public var title: String
    public var preview: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var isLocked: Bool
    public var isFavorite: Bool
    public var hasInk: Bool
    public var hasText: Bool
    public var coverFile: String?
    public var deviceName: String
    public var bytes: Int
    /// What this Mac still has to send to the service for this note.
    public var pending: Pending?
    /// Strokes drawn here that the service does not have yet.
    public var unsentStrokes: [String]?
    /// True when pages changed here (ink added or erased) since the last upload.
    public var pagesChanged: Bool?
    /// Counts the changes made here: an upload or a download that started before the latest
    /// one must not be taken for having covered it.
    public var revision: Int?
    /// True once the service has been told of this note's place in the folder tree.
    public var nodeSent: Bool?
    /// The whole typed text, for searching (the preview is only its beginning).
    public var fullText: String?
    /// Text recognised in the note's handwriting on this Mac, for searching. Never sent anywhere.
    public var inkText: String?
    /// Files added here that the service does not have yet: content hashes.
    public var unsentFiles: [String]?

    public enum Pending: String, Codable, Sendable { case create, update }
}

/// Everything the app keeps between runs, apart from the notes' own files.
public struct Library: Codable, Sendable {
    public var nodes: [String: TreeNode] = [:]
    public var notes: [String: NoteRecord] = [:]
    public var folderCursor: String?
    public var noteCursor: String?
    public var lastSync: Date?
    public var cloudBytes: Int?
    /// Tree nodes changed here and not yet sent.
    public var dirtyNodes: Set<String>?
    /// Notes deleted for good here whose deletion is not yet sent: note id to server id.
    public var pendingDeletes: [String: String]?
    /// Notes whose download failed, to be tried again: note id to where to get it.
    public var failedDownloads: [String: FailedDownload]?
    /// For a sync folder (iCloud Drive): what of each note was last seen to be the same here
    /// and there, and this Mac's name among the devices that write to the folder.
    public var folderLinks: [String: FolderLink]?
    public var folderDevice: String?
    /// Which folder the links are about ("icloud", "google:<account>"); nil in older libraries means iCloud.
    public var folderHome: String?
    /// Notes the user deleted for good here that the sync folder still has: only these are
    /// deleted there. A note that is merely not on this Mac any more is never taken for deleted.
    public var folderDeletes: Set<String>?
    public init() {}

    /// A note as it stood when this Mac and the sync folder last agreed on it.
    public struct FolderLink: Codable, Sendable, Equatable {
        /// The file in the folder that holds that version.
        public var version: String
        /// What the note's files on this Mac were then (see `LocalStore.fingerprint`).
        public var fingerprint: String
        /// Whether that file is encrypted.
        public var sealed: Bool
    }

    public struct FailedDownload: Codable, Sendable {
        public var serverID: String
        public var attempts: Int
    }

    /// How many things wait to be sent: notes, places in the tree, deletions.
    public var pendingCount: Int {
        notes.values.filter { $0.pending != nil }.count + (pendingDeletes ?? [:]).count
            + (dirtyNodes ?? []).filter { id in notes[id]?.pending == nil }.count
    }

    public func state(of noteID: String) -> TreeNode.State { nodes[noteID]?.state ?? .normal }

    /// What signing out does to the notes on this Mac. Notes the service never got stay as they
    /// are; notes with changes it has not got yet are kept as copies; the others are removed from
    /// this Mac (they stay in the cloud).
    public var signOutSummary: (staysHere: Int, copied: Int, goes: Int) {
        var stays = 0, copied = 0, goes = 0
        for record in notes.values {
            if record.serverID.isEmpty { stays += 1 } else if record.pending != nil { copied += 1 } else { goes += 1 }
        }
        return (stays, copied, goes)
    }

    /// True when the service holds a copy of this note.
    public func isInCloud(_ noteID: String) -> Bool { notes[noteID].map { !$0.serverID.isEmpty } ?? false }

    /// The folders from the top down to this one.
    public func path(to folder: String) -> [TreeNode] {
        var out: [TreeNode] = []
        var current = nodes[folder]
        var guardCount = 0
        while let node = current, node.kind == .folder, guardCount < 64 {
            out.insert(node, at: 0)
            current = nodes[node.parentID]
            guardCount += 1
        }
        return out
    }

    public var hasPendingUploads: Bool {
        !(dirtyNodes ?? []).isEmpty || !(pendingDeletes ?? [:]).isEmpty || notes.values.contains { $0.pending != nil }
    }

    public func folders(in parent: String) -> [TreeNode] {
        nodes.values.filter { $0.kind == .folder && $0.state == .normal && $0.parentID == parent }
            // Samsung's built-in folders ("math:///", "screenOffMemo:///") show only once they hold a note.
            .filter { folder in !folder.id.contains(":") || nodes.values.contains { $0.kind == .note && $0.state == .normal && $0.parentID == folder.id } }
            .sorted { ($0.order, $0.name.lowercased()) < ($1.order, $1.name.lowercased()) }
    }

    /// Ids of a folder and every folder below it.
    public func subtree(of folder: String) -> Set<String> {
        var out: Set<String> = [folder]
        var frontier = [folder]
        while let next = frontier.popLast() {
            for child in nodes.values where child.kind == .folder && child.parentID == next && !out.contains(child.id) {
                out.insert(child.id); frontier.append(child.id)
            }
        }
        return out
    }
}

/// The cursor of a change feed: base64 of a small JSON object the service hands back each time.
public enum ChangePoint {
    public static func initial(kind: String) -> String {
        let json = #"{"version":0,"encryptedGuid":"","requestTimeStamp":0,"modifiedTime":0,"appVersion":"0","sdkVersion":"0","purpose":"INITIAL","type":"\#(kind)"}"#
        return Data(json.utf8).base64EncodedString()
    }
}

/// Reads tree nodes out of recorded folder-feed answers (development only).
public enum CaptureFolders {
    public static func nodes(from answers: [Data]) -> [String: TreeNode] {
        var out: [String: TreeNode] = [:]
        for data in answers {
            guard let root = try? XMLTree.parse(data) else { continue }
            for node in root.descendant("nodeList")?.all("node").compactMap(TreeNode.init) ?? [] { out[node.id] = node }
        }
        return out
    }
}
