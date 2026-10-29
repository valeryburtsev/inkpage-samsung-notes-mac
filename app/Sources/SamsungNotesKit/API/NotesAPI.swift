import Foundation

/// The notes sync service (`/samsungnotes/v1`), as the Windows client speaks it.
public struct NotesAPI: Sendable {
    public enum Feature: String, Sendable { case user = "BU", autosave = "BA", background = "BB" }

    let base: String
    let token: String
    let deviceName: String
    let feature: String
    let http: HTTPClient

    public init(base: String, token: String, deviceName: String, feature: Feature = .user, http: HTTPClient = .shared) {
        self.base = base
        self.token = token
        self.deviceName = deviceName
        self.feature = "\(feature.rawValue)-\(NotesAPI.randomLetters(10))"
        self.http = http
    }

    static func randomLetters(_ count: Int) -> String {
        String((0..<count).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
    }

    func headers(transaction: String, extra: [String: String] = [:]) -> [String: String] {
        var headers = [
            "x-sc-network": "WIFI", "x-sn-app-ver": CloudIdentity.appVersion, "x-sn-xml-ver": "2",
            "x-sn-model-name": Data(deviceName.utf8).base64EncodedString(), "x-sn-feature-id": feature,
            "User-Agent": "Windows.SamsungNotes-4.0;Microsoft Windows NT 10.0.26200.0;PcSamsungNotes=\(CloudIdentity.appVersion);sdk=4000;",
            "x-sn-sdk-ver": "5500", "Authorization": "Bearer \(token)",
            "x-sn-transaction-id": "\(transaction)-\(NotesAPI.randomLetters(10))",
        ]
        for (name, value) in extra { headers[name] = value }
        return headers
    }

    func url(_ path: String, query: [(String, String)] = []) -> URL {
        var components = URLComponents(string: base + "/samsungnotes/v1" + path)!
        if !query.isEmpty {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            components.percentEncodedQuery = query.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        }
        return components.url!
    }

    func check(_ response: HTTPResponse, _ what: String) throws {
        guard (200..<300).contains(response.status) else { throw HTTPError(status: response.status, what: what, detail: response.text) }
    }

    func xmlBody(_ xml: String) -> (Data, [String: String]) {
        let raw = Data(xml.utf8)
        if let packed = Gzip.compress(raw) { return (packed, ["Content-Type": "application/xml;Charset=utf-8", "Content-Encoding": "gzip"]) }
        return (raw, ["Content-Type": "application/xml;Charset=utf-8"])
    }

    /// The folder tree's changes since `cursor`: folders and the notes' places in them.
    public func folderChanges(cursor: String?) async throws -> (nodes: [TreeNode], cursor: String?) {
        let response = try await http.request("GET", url("/folder/changes", query: [("lastChangePoint", cursor ?? ChangePoint.initial(kind: "FOLDER"))]), headers: headers(transaction: "FD"))
        try check(response, "Folder list")
        let root = try XMLTree.parse(response.body)
        let nodes = root.descendant("nodeList")?.all("node").compactMap(TreeNode.init) ?? []
        return (nodes, root.value("lastChangePoint"))
    }

    /// One page of the notes change feed.
    public func noteChanges(cursor: String?) async throws -> (changes: [NoteChange], cursor: String?, hasNext: Bool) {
        let response = try await http.request("GET", url("/notes/changes", query: [("lastChangePoint", cursor ?? ChangePoint.initial(kind: "NOTE"))]), headers: headers(transaction: "ND"))
        try check(response, "Note changes")
        let root = try XMLTree.parse(response.body)
        return (root.all("changes").compactMap(NoteChange.init), root.value("lastChangePoint"), root.value("hasNext") == "true")
    }

    /// A note's whole document: its XML and one binary part per stroke.
    public func download(serverID: String) async throws -> (xml: Data, strokes: [String: Data]) {
        let (body, contentHeaders) = xmlBody(#"<noteTree ver="0" />"#)
        var extra = contentHeaders
        extra["Content-Type"] = "application/xml"
        extra["Accept"] = "multipart/form-data"
        let response = try await http.request("POST", url("/notes/\(serverID)/compareForDownsync"), headers: headers(transaction: "NC", extra: extra), body: body)
        try check(response, "Note download")
        let parts = Multipart.parse(response.body)
        guard let xml = parts.first(where: { $0.name == "noteResource" })?.body else {
            throw HTTPError(status: response.status, what: "Note download", detail: "no note in the answer")
        }
        var strokes: [String: Data] = [:]
        for part in parts where part.name == "strokeResource" {
            // The file name is "<object id>_<modified time>".
            if let name = part.filename, let id = name.split(separator: "_").first { strokes[String(id)] = part.body }
        }
        return (xml, strokes)
    }

    /// A file of a note, by the signed address the note's document gave for it. The service
    /// answers with a redirect to its file host, which must not see our token.
    public func downloadFile(signedURL: String) async throws -> Data {
        guard let url = URL(string: signedURL), url.scheme == "https", url.user == nil, let host = url.host?.lowercased(), host.hasSuffix(".samsungcloud.com") else {
            throw HTTPError(status: 0, what: "File download", detail: "unexpected address")
        }
        var response = try await http.request("GET", url, headers: headers(transaction: "NC"))
        var hops = 0
        while (300..<400).contains(response.status), hops < 4, let location = response.header("Location"), let next = URL(string: location),
              next.scheme == "https", next.user == nil, let nextHost = next.host?.lowercased(), nextHost.hasSuffix(".samsungcloud.com") {
            response = try await http.request("GET", next, headers: ["User-Agent": headers(transaction: "NC")["User-Agent"]!])
            hops += 1
        }
        try check(response, "File download")
        return response.body
    }

    /// The verifier of the password of locked notes, from the account's settings; nil for none.
    public func passcode() async throws -> Passcode? {
        let response = try await http.request("GET", url("/settings"), headers: headers(transaction: "SD"))
        try check(response, "Settings")
        return Passcode(settings: try XMLTree.parse(response.body))
    }

    /// Sets the verifier for the whole account.
    public func setPasscode(_ passcode: Passcode) async throws {
        let response = try await http.request("POST", url("/settings"), headers: headers(transaction: "SU", extra: ["Content-Type": "application/xml;Charset=utf-8"]),
                                              body: Data(passcode.settingsXML.utf8))
        try check(response, "Settings")
    }

    // MARK: Writing

    /// Sends changed tree nodes: new notes and folders, renames, moves, trashing and deleting.
    public func patchFolder(_ nodes: [TreeNode], now: Date = Date()) async throws {
        guard !nodes.isEmpty else { return }
        // The list as a whole is stamped with the moment it is sent: the service refuses (409)
        // a list stamped older than the one it has, and any other device may have changed that
        // since a node here was last touched.
        let stamp = max(nodes.map(\.syncModifiedTime).max() ?? 0, Int64(now.timeIntervalSince1970 * 1000))
        let xml = "<FolderResource><syncModifiedTime>\(stamp)</syncModifiedTime><nodeList>" + nodes.map { $0.uploadXML(deviceName: deviceName, now: now) }.joined() + "</nodeList></FolderResource>"
        let (body, contentHeaders) = xmlBody(xml)
        let response = try await http.request("PATCH", url("/folder"), headers: headers(transaction: "FU", extra: contentHeaders), body: body)
        try check(response, "Folder update")
    }

    func noteBody(document: String, strokes: [(id: String, time: String, data: Data)]) -> (Data, [String: String]) {
        let boundary = NotesAPI.randomLetters(10)
        var parts = [MultipartPart(name: "noteResource", filename: nil, contentType: "application/xml; charset=utf-8", body: Data(document.utf8))]
        for stroke in strokes { parts.append(MultipartPart(name: "strokeResource", filename: "\(stroke.id)_\(stroke.time)", contentType: nil, body: stroke.data)) }
        let raw = Multipart.build(parts, boundary: boundary)
        var headers = ["Content-Type": "multipart/form-data;boundary=\(boundary)"]
        if let packed = Gzip.compress(raw) {
            headers["Content-Encoding"] = "gzip"
            return (packed, headers)
        }
        return (raw, headers)
    }

    static func result(_ response: HTTPResponse) -> (resourceID: String?, commitID: String?) {
        guard let root = try? XMLTree.parse(response.body) else { return (nil, nil) }
        return (root.value("resourceId"), root.value("commitId"))
    }

    /// Creates a note in the service. Returns the id the service gives it and its first commit.
    public func createNote(document: String, strokes: [(id: String, time: String, data: Data)] = []) async throws -> (serverID: String, commitID: String) {
        let (body, contentHeaders) = noteBody(document: document, strokes: strokes)
        let response = try await http.request("POST", url("/notes"), headers: headers(transaction: "NU", extra: contentHeaders), body: body)
        try check(response, "Note upload")
        let result = NotesAPI.result(response)
        guard let serverID = result.resourceID, !serverID.isEmpty else { throw HTTPError(status: response.status, what: "Note upload", detail: "no id in the answer") }
        return (serverID, result.commitID ?? "")
    }

    /// Asks the service what it lacks of a note. Returns the commit the service has now.
    public func compareForUpsync(serverID: String, tree: String) async throws -> (commitID: String?, wantsBody: Bool, wanted: Set<String>) {
        let (body, contentHeaders) = xmlBody(tree)
        let response = try await http.request("POST", url("/notes/\(serverID)/compareForUpsync"), headers: headers(transaction: "NU", extra: contentHeaders), body: body)
        try check(response, "Note comparison")
        let root = try XMLTree.parse(response.body)
        // Everything the answer names by id is something the service lacks: objects, files, pages.
        var wanted: Set<String> = []
        func collect(_ node: XMLNode) {
            if let id = node["id"] { wanted.insert(id) }
            node.children.forEach(collect)
        }
        collect(root)
        return (root.value("commitId"), root.child("bodyText") != nil, wanted)
    }

    public func updateNote(serverID: String, document: String, strokes: [(id: String, time: String, data: Data)] = []) async throws -> String {
        let (body, contentHeaders) = noteBody(document: document, strokes: strokes)
        let response = try await http.request("POST", url("/notes/\(serverID)/update"), headers: headers(transaction: "NU", extra: contentHeaders), body: body)
        try check(response, "Note update")
        return NotesAPI.result(response).commitID ?? ""
    }

    // MARK: Files

    /// The second value the service wants with a file's hash: the hash with the hash of the
    /// access token laid over it.
    public static func validationKey(fileHash: String, token: String) -> String? {
        guard let hash = AccountCrypto.data(hex: fileHash), hash.count == 32 else { return nil }
        let mask = NoteHash.digest(Data(token.utf8))
        return NoteHash.hex(Data(zip(hash, mask).map { $0 ^ $1 }))
    }

    /// Asks where to put files. Returns an address for each file the service does not hold yet
    /// and the hashes of those it has already, which need no upload.
    public func createUploadURLs(_ files: [(hash: String, size: Int)]) async throws -> (created: [String: String], held: Set<String>) {
        guard !files.isEmpty else { return ([:], []) }
        var xml = "<request><fileInfoList>"
        for file in files {
            guard let key = NotesAPI.validationKey(fileHash: file.hash, token: token) else { continue }
            xml += "<fileInfo><hash>\(file.hash.escapedXML)</hash><contentType>application/octet-stream</contentType><size>\(file.size)</size><validationKey>\(key)</validationKey></fileInfo>"
        }
        xml += "</fileInfoList></request>"
        let address = URL(string: base + "/samsungnotes/v2/binaries/createUploadURLs")!
        let response = try await http.request("POST", address, headers: headers(transaction: "NU", extra: ["Content-Type": "application/xml;Charset=utf-8"]), body: Data(xml.utf8))
        try check(response, "File upload")
        let root = try XMLTree.parse(response.body)
        var out: [String: String] = [:]
        for entry in root.child("created")?.descendants("file") ?? [] {
            if let hash = entry.value("hash"), let url = entry.value("url") { out[hash] = url }
        }
        if let failed = root.child("failed"), let first = failed.descendants("hash").first?.text ?? failed.descendants("file").first?.value("hash") {
            throw HTTPError(status: response.status, what: "File upload", detail: "the service refused a file (\(first.prefix(12))…): \(failed.descendants("rmsg").first?.text ?? failed.descendants("message").first?.text ?? "no reason given")")
        }
        return (out, Set(root.child("duplicated")?.descendants("hash").map(\.text) ?? []))
    }

    public static func contentType(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        return "application/octet-stream"
    }

    /// Puts a file at the address `createUploadURLs` gave for it, as the Windows client does:
    /// the whole file in one request. Only Samsung Cloud's own file hosts are written to.
    public func uploadFile(signedURL: String, data: Data) async throws {
        guard let url = URL(string: signedURL), url.scheme == "https", url.user == nil, let host = url.host?.lowercased(), host.hasSuffix(".samsungcloud.com") else {
            throw HTTPError(status: 0, what: "File upload", detail: "unexpected address")
        }
        let extra = ["Content-Type": NotesAPI.contentType(data), "Range": "bytes=0-\(max(data.count - 1, 0))"]
        let response = try await http.request("PUT", url, headers: headers(transaction: "NU", extra: extra), body: data)
        try check(response, "File upload")
    }

    public func deleteNote(serverID: String, syncModifiedTime: Int64) async throws {
        let response = try await http.request("DELETE", url("/notes/\(serverID)", query: [("syncModifiedTime", String(syncModifiedTime))]),
                                              headers: headers(transaction: "NU", extra: ["Content-Type": "application/xml;Charset=utf-8"]))
        // Already gone is as good as deleted.
        if response.status != 404 { try check(response, "Note deletion") }
    }

    /// Bytes this account's notes use in Samsung Cloud.
    public func usage() async -> Int? {
        guard let response = try? await http.request("GET", URL(string: base + "/quota/v3/usage")!, headers: ["Authorization": "Bearer \(token)"]),
              response.status == 200, let list = response.json?["usage_info"] as? [[String: Any]] else { return nil }
        return list.first { $0["cid"] as? String == "aWluBInwWH" }.flatMap { ($0["size"] as? NSNumber)?.intValue }
    }
}
