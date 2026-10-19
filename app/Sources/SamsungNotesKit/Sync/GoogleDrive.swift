import CryptoKit
import Foundation

/// The Drive of a Google account as a cloud that keeps named files, reached through Google's
/// own interface (Drive v3) with the account's permission (see `GoogleAccount`). The files lie
/// in the app's own hidden folder of the Drive (`appDataFolder`), which this app alone can
/// read, each under the name it has in the sync folder.
///
/// Drive has no names that are paths and allows two files of one name, so every round lists
/// the folder whole (a request for each thousand files) and compares it with what was listed
/// before: that list is the token.
public final class GoogleDriveFiles: CloudFiles, @unchecked Sendable {
    struct Listed: Codable, Equatable {
        var id: String
        /// The content's checksum as Drive computes it.
        var md5: String
    }

    public struct Refused: Error, CustomStringConvertible {
        public var status: Int
        public var what: String
        public var detail: String
        public var description: String { "\(what) failed with HTTP \(status): \(detail.prefix(300))" }
    }

    private let token: @Sendable (_ renew: Bool) async throws -> String
    private let http: HTTPClient
    private let scratch: URL
    private let lock = NSLock()
    /// What the Drive holds, as far as this object has seen and written it.
    private var index: [String: Listed]?

    private let endpoints: GoogleEndpoints
    /// Files up to this size go up in one request with their name; larger ones in two.
    var simpleLimit = 4 * 1024 * 1024
    /// The first pause, in milliseconds, before a request Google was too busy for is sent again; each further one is twice as long.
    var patience = 400

    /// `token` gives the access token; asked with `renew`, a fresh one (the last was refused).
    public init(token: @escaping @Sendable (_ renew: Bool) async throws -> String, http: HTTPClient = .shared, endpoints: GoogleEndpoints = .google, scratch: URL = FileManager.default.temporaryDirectory) {
        self.token = token
        self.endpoints = endpoints
        self.http = http
        self.scratch = scratch
    }

    private func set(_ listed: [String: Listed]) { lock.lock(); index = listed; lock.unlock() }
    /// Saving and deleting go by what the Drive holds: asked for when no round has listed it yet.
    private func ensureIndex() async throws { if known() == nil { set(try await list().files) } }
    private func known() -> [String: Listed]? { lock.lock(); defer { lock.unlock() }; return index }
    private func note(_ name: String, _ listed: Listed?) { lock.lock(); defer { lock.unlock() }; if index == nil { index = [:] }; index?[name] = listed }

    // MARK: Requests

    /// Sends a request with the account's token: once more with a fresh token when it is
    /// refused as stale, and again after a pause when Google asks for patience.
    private func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil, what: String) async throws -> HTTPResponse {
        var renewed = false
        var attempt = 0
        while true {
            var all = headers
            all["Authorization"] = "Bearer " + (try await token(renewed))
            var response = try await http.request(method, url, headers: all, body: body)
            if method == "GET", (301...308).contains(response.status), let place = response.header("Location").flatMap({ URL(string: $0, relativeTo: url) })?.absoluteURL,
               endpoints.takesToken(place) || (place.scheme == "https" && place.host?.hasSuffix(".googleusercontent.com") == true) {
                // A file's content may be handed out by another of Google's hosts. The token goes only to Google's interface itself.
                response = try await http.request("GET", place, headers: endpoints.takesToken(place) ? all : headers)
            }
            if response.status == 401, !renewed { renewed = true; continue }
            let limited = response.status == 429 || (response.status == 403 && response.text.contains("ateLimitExceeded"))
            if (limited || response.status >= 500), attempt < 4 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(patience * (1 << attempt)))
                continue
            }
            return response
        }
    }

    private func checked(_ response: HTTPResponse, _ what: String) throws -> HTTPResponse {
        guard (200..<300).contains(response.status) else { throw Refused(status: response.status, what: what, detail: response.text) }
        return response
    }

    private static func url(_ base: String, _ path: String, _ query: [(String, String)]) -> URL {
        var parts = URLComponents(string: base + path)!
        parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // A "+" in a query stands for a space to Google: it is written out.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    /// Everything in the app's folder of the Drive. Of several files with one name the one
    /// changed last holds; the others are returned to be cleared away.
    private func list() async throws -> (files: [String: Listed], extra: [String]) {
        struct Page: Decodable {
            struct File: Decodable { var id: String; var name: String; var md5Checksum: String?; var modifiedTime: String? }
            var nextPageToken: String?
            var files: [File]?
        }
        var best: [String: Page.File] = [:]
        var extra: [String] = []
        var next: String?
        repeat {
            var query = [("spaces", "appDataFolder"), ("pageSize", "1000"), ("fields", "nextPageToken,files(id,name,md5Checksum,modifiedTime)")]
            if let next { query.append(("pageToken", next)) }
            let response = try checked(try await send("GET", GoogleDriveFiles.url(endpoints.api, "/files", query), what: "Listing Google Drive"), "Listing Google Drive")
            let page = try JSONDecoder().decode(Page.self, from: response.body)
            for file in page.files ?? [] {
                if let held = best[file.name] {
                    // Times are written the same way throughout, so they compare as text.
                    let newer = (file.modifiedTime ?? "", file.id) > (held.modifiedTime ?? "", held.id)
                    extra.append(newer ? held.id : file.id)
                    if newer { best[file.name] = file }
                } else {
                    best[file.name] = file
                }
            }
            next = page.nextPageToken
        } while next != nil
        return (best.mapValues { Listed(id: $0.id, md5: $0.md5Checksum ?? "") }, extra)
    }

    /// Runs `work` on every item, a few at a time.
    private func each<Item: Sendable>(_ items: [Item], atOnce: Int = 6, _ work: @escaping @Sendable (Item) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var waiting = items.makeIterator()
            var running = 0
            while running < atOnce, let item = waiting.next() { group.addTask { try await work(item) }; running += 1 }
            while try await group.next() != nil {
                if let item = waiting.next() { group.addTask { try await work(item) } }
            }
        }
    }

    // MARK: CloudFiles

    public func changes(since data: Data?) async throws -> CloudChanges {
        let before = data.flatMap { try? JSONDecoder().decode([String: Listed].self, from: $0) }
        let (now, extra) = try await list()
        var out = CloudChanges()
        out.isEverything = before == nil
        let wanted = now.filter { before?[$0.key] != $0.value }.sorted { $0.key < $1.key }
        let fetched = Fetched()
        let scratch = scratch
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try await each(wanted.map { ($0.key, $0.value.id) }) { [self] name, id in
            let response = try await send("GET", GoogleDriveFiles.url(endpoints.api, "/files/" + id, [("alt", "media")]), what: "Downloading from Google Drive")
            // Gone since it was listed: the next round says so.
            if response.status == 404 { return }
            let copy = scratch.appendingPathComponent("snotes-google-" + UUID().uuidString)
            try checked(response, "Downloading from Google Drive").body.write(to: copy)
            fetched.add(CloudFile(name: name, url: copy, isTemporary: true))
        }
        out.changed = fetched.all
        if let before { out.deleted = before.keys.filter { now[$0] == nil } }
        // Only what did arrive is in the token: the rest is asked for again.
        let arrived = Set(out.changed.map(\.name))
        var kept = now
        for (name, _) in wanted where !arrived.contains(name) { kept[name] = before?[name] }
        set(kept)
        out.token = try JSONEncoder().encode(kept)
        // Copies of a name written on two Macs at once: the older go. One that is gone already is as wanted.
        for id in extra { _ = try? await send("DELETE", GoogleDriveFiles.url(endpoints.api, "/files/" + id, []), what: "Tidying Google Drive") }
        return out
    }

    public func save(_ files: [CloudFile]) async throws {
        try await ensureIndex()
        // Fewer at once than when reading: Google is strict about how fast a Drive is written to.
        try await each(files, atOnce: 3) { [self] file in
            let data = try Data(contentsOf: file.url)
            let existing = known()?[file.name]
            let made = try await put(file.name, data, over: existing?.id)
            note(file.name, made)
        }
    }

    /// Writes a file to the Drive, new or over the one with `id`, and says how it is listed now.
    private func put(_ name: String, _ data: Data, over id: String?) async throws -> Listed {
        struct Made: Decodable { var id: String; var md5Checksum: String? }
        var metadata: [String: Any] = ["name": name]
        if id == nil { metadata["parents"] = ["appDataFolder"] }
        let json = try JSONSerialization.data(withJSONObject: metadata)
        let path = "/files" + (id.map { "/" + $0 } ?? "")
        let method = id == nil ? "POST" : "PATCH"
        var response: HTTPResponse
        if data.count <= simpleLimit {
            let boundary = "snotes-" + UUID().uuidString
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
            body.append(json)
            body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            response = try await send(method, GoogleDriveFiles.url(endpoints.upload, path, [("uploadType", "multipart"), ("fields", "id,md5Checksum")]),
                                      headers: ["Content-Type": "multipart/related; boundary=\(boundary)"], body: body, what: "Uploading to Google Drive")
        } else {
            // A large file: Google first says where to send it, then takes it there.
            let begun = try checked(try await send(method, GoogleDriveFiles.url(endpoints.upload, path, [("uploadType", "resumable"), ("fields", "id,md5Checksum")]),
                                                   headers: ["Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Type": "application/octet-stream", "X-Upload-Content-Length": String(data.count)],
                                                   body: json, what: "Uploading to Google Drive"), "Uploading to Google Drive")
            guard let place = begun.header("Location").flatMap(URL.init(string:)), endpoints.takesToken(place) else {
                throw Refused(status: begun.status, what: "Uploading to Google Drive", detail: "no place to send the file to")
            }
            response = try await send("PUT", place, headers: ["Content-Type": "application/octet-stream"], body: data, what: "Uploading to Google Drive")
        }
        if response.status == 404, id != nil {
            // The file it was to replace is gone: it is written as a new one.
            return try await put(name, data, over: nil)
        }
        let made = try JSONDecoder().decode(Made.self, from: try checked(response, "Uploading to Google Drive").body)
        return Listed(id: made.id, md5: made.md5Checksum ?? Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    public func delete(_ names: [String]) async throws {
        try await ensureIndex()
        try await each(names, atOnce: 3) { [self] name in
            guard let id = known()?[name]?.id else { return }
            let response = try await send("DELETE", GoogleDriveFiles.url(endpoints.api, "/files/" + id, []), what: "Deleting from Google Drive")
            // One that is gone already is as wanted.
            if response.status != 404 { _ = try checked(response, "Deleting from Google Drive") }
            note(name, nil)
        }
    }

    /// The list as it stands after what this Mac wrote and removed, so that the next round
    /// does not take its own files for news.
    public func tokenAfterRound() async -> Data? { known().flatMap { try? JSONEncoder().encode($0) } }

    /// Removes everything this app keeps in the Drive. For an account used only to try the service.
    public func removeEverything() async throws {
        let (files, extra) = try await list()
        for id in files.values.map(\.id) + extra { _ = try await send("DELETE", GoogleDriveFiles.url(endpoints.api, "/files/" + id, []), what: "Deleting from Google Drive") }
        set([:])
    }

    /// The address of the account whose Drive this is.
    public func owner() async throws -> String? {
        struct About: Decodable { struct User: Decodable { var emailAddress: String? }; var user: User? }
        let response = try checked(try await send("GET", GoogleDriveFiles.url(endpoints.api, "/about", [("fields", "user(emailAddress)")]), what: "Asking Google Drive"), "Asking Google Drive")
        return try JSONDecoder().decode(About.self, from: response.body).user?.emailAddress
    }
}

/// What several downloads at once have brought, gathered.
private final class Fetched: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [CloudFile] = []
    func add(_ file: CloudFile) { lock.lock(); files.append(file); lock.unlock() }
    var all: [CloudFile] { lock.lock(); defer { lock.unlock() }; return files }
}
