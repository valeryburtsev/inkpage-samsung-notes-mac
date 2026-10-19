import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// A note opened for display: its document, its decoded strokes and where its files are.
public struct LoadedNote: @unchecked Sendable {
    public var document: NoteDocument
    public var strokes: [String: InkStroke]
    public var directory: URL

    public func fileURL(_ hash: String) -> URL? {
        let name = LocalStore.safeName(hash)
        guard !name.isEmpty else { return nil }
        let url = directory.appendingPathComponent("media").appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func image(_ hash: String?) -> CGImage? {
        guard let hash, let url = fileURL(hash), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2400]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The notes on this Mac: `library.json` and one folder per note holding the service's own
/// document, a file per stroke and the note's pictures.
public final class LocalStore: @unchecked Sendable {
    public let root: URL
    private let files = FileManager.default

    public init(root: URL) {
        self.root = root
        try? files.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
    }

    /// The app's name, as people see it.
    public static let appName = "Inkpage"
    /// The name the app had before (2026-10-14): its folder, settings and keychain items are found under it.
    public static let formerName = "SNotes"
    public static let formerBundleID = "com.snotes.app"

    public static var defaultRoot: URL { root(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!) }

    /// The app's folder in a folder of application support: the folder of the app under its
    /// former name is taken over, whole, the first time; one of the new name is never replaced.
    static func root(in base: URL) -> URL {
        let folder = base.appendingPathComponent(appName, isDirectory: true)
        let former = base.appendingPathComponent(formerName, isDirectory: true)
        let files = FileManager.default
        if !files.fileExists(atPath: folder.path), files.fileExists(atPath: former.path) { try? files.moveItem(at: former, to: folder) }
        return folder
    }

    private var libraryURL: URL { root.appendingPathComponent("library.json") }

    private let lock = NSLock()
    private var cached: Library?
    private let fileLock = NSRecursiveLock()

    /// Runs work that reads or rewrites a note's files together with the library, shut off from
    /// every other such piece of work. An edit in the app and a sync's download or upload of the
    /// same note thus never see each other half done.
    public func exclusive<T>(_ work: () throws -> T) rethrows -> T {
        fileLock.lock(); defer { fileLock.unlock() }
        return try work()
    }

    private func readLocked() -> Library {
        if let cached { return cached }
        let library = (try? Data(contentsOf: libraryURL)).flatMap { try? JSONDecoder().decode(Library.self, from: $0) } ?? Library()
        cached = library
        return library
    }

    /// The library as it is now.
    public func loadLibrary() -> Library {
        lock.lock(); defer { lock.unlock() }
        return readLocked()
    }

    /// Changes the library in one step, so the app and a running sync never undo each other.
    @discardableResult
    public func update<T>(_ change: (inout Library) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        var library = readLocked()
        let result = try change(&library)
        cached = library
        if let data = try? JSONEncoder().encode(library) { try? data.write(to: libraryURL, options: .atomic) }
        return result
    }

    public func save(_ library: Library) { update { $0 = library } }

    public func directory(_ noteID: String) -> URL {
        // Note ids come from the service: keep only what a UUID can contain.
        let safe = noteID.filter { $0.isHexDigit || $0 == "-" }
        return root.appendingPathComponent("notes").appendingPathComponent(safe.isEmpty ? "unknown" : safe, isDirectory: true)
    }

    static func safeName(_ name: String) -> String { String(name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(128)) }

    public func mediaURL(_ noteID: String, _ hash: String) -> URL {
        directory(noteID).appendingPathComponent("media").appendingPathComponent(LocalStore.safeName(hash))
    }

    public func hasFile(_ noteID: String, _ hash: String) -> Bool { files.fileExists(atPath: mediaURL(noteID, hash).path) }

    public func writeFile(_ noteID: String, _ hash: String, _ data: Data) {
        let url = mediaURL(noteID, hash)
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private var arrived: [String: Int] = [:]

    /// How many times a version of this note has arrived from the service since the app started.
    /// An editor remembers the number it read its text under; a different number later means
    /// another device's version has taken the note's place.
    public func arrivals(_ noteID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return arrived[noteID] ?? 0
    }

    /// Stores a downloaded note and returns what the library should remember of it.
    public func ingest(serverID: String, commitID: String, deviceName: String, xml: Data, strokes: [String: Data]) throws -> NoteRecord {
        let document = try NoteDocument(xml: xml)
        lock.lock(); arrived[document.id, default: 0] += 1; lock.unlock()
        let folder = directory(document.id)
        let strokeFolder = folder.appendingPathComponent("strokes")
        try? files.removeItem(at: strokeFolder)
        try files.createDirectory(at: strokeFolder, withIntermediateDirectories: true)
        try xml.write(to: folder.appendingPathComponent("note.xml"), options: .atomic)
        var bytes = xml.count
        for (id, data) in strokes {
            try data.write(to: strokeFolder.appendingPathComponent(LocalStore.safeName(id) + ".bin"))
            bytes += data.count
        }
        clearThumbnails(in: folder)
        let created = document.displayCreated ?? Date(timeIntervalSince1970: Double(document.createdMicros) / 1_000_000)
        return NoteRecord(id: document.id, serverID: serverID, commitID: commitID.isEmpty ? (document.commitID ?? "") : commitID,
                          title: document.title.plain.trimmingCharacters(in: .whitespacesAndNewlines),
                          preview: String(document.body.plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)),
                          createdAt: created, modifiedAt: document.displayModified ?? created, isLocked: document.isLocked,
                          isFavorite: document.isFavorite, hasInk: document.hasInk, hasText: !document.body.isEmpty,
                          coverFile: document.firstImage, deviceName: deviceName, bytes: bytes, pending: nil, unsentStrokes: nil, pagesChanged: nil, revision: nil, nodeSent: true, fullText: String(document.body.plain.prefix(40_000)), inkText: nil, unsentFiles: nil)
    }

    public func remove(_ noteID: String) { try? files.removeItem(at: directory(noteID)) }

    /// The names of a note's stroke files (without their ending) and of its attached files.
    func partNames(_ noteID: String) -> (strokes: [String], media: [String]) {
        let folder = directory(noteID)
        let strokes = ((try? files.contentsOfDirectory(atPath: folder.appendingPathComponent("strokes").path)) ?? []).filter { $0.hasSuffix(".bin") }.map { String($0.dropLast(4)) }.sorted()
        let media = ((try? files.contentsOfDirectory(atPath: folder.appendingPathComponent("media").path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return (strokes, media)
    }

    /// A mark of everything a note consists of on this Mac: it changes when anything about the
    /// note changes, and two Macs holding the same note come to the same mark. Nil without the note.
    public func fingerprint(_ noteID: String) -> String? {
        guard let xml = try? Data(contentsOf: noteURL(noteID)) else { return nil }
        var mark = SHA256()
        mark.update(data: xml)
        let parts = partNames(noteID)
        // The document names every stroke with its time, and an attached file is named by what
        // it holds: which of them are here says the rest, without reading them.
        for name in parts.strokes { mark.update(data: Data("|s:\(name)".utf8)) }
        for name in parts.media { mark.update(data: Data("|m:\(name)".utf8)) }
        return mark.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Puts a whole note in the place of the one with its id (or adds it): its document, its
    /// strokes and its attached files. For a version that arrived from a sync folder. Returns
    /// what the library should remember of it; the caller sets how it stands with the services.
    func replace(xml: Data, strokes: [String: Data], media: [String: Data], deviceName: String) throws -> NoteRecord {
        let record = try ingest(serverID: "", commitID: "", deviceName: deviceName, xml: xml, strokes: strokes)
        let folder = directory(record.id).appendingPathComponent("media")
        let wanted = Set(media.keys.map(LocalStore.safeName))
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where !wanted.contains(name) { try? files.removeItem(at: folder.appendingPathComponent(name)) }
        var bytes = record.bytes
        for (hash, data) in media {
            writeFile(record.id, hash, data)
            bytes += data.count
        }
        var out = record
        out.bytes = bytes
        return out
    }

    func noteURL(_ noteID: String) -> URL { directory(noteID).appendingPathComponent("note.xml") }

    func noteFile(_ noteID: String) throws -> NoteFile {
        var file = try NoteFile(data: try Data(contentsOf: noteURL(noteID)))
        file.pixelSize = { [self] hash in LocalStore.pixelSize(of: mediaURL(noteID, hash)) }
        return file
    }

    /// The size in pixels of a picture file, upright.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue, let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, width > 0, height > 0 else { return nil }
        let turned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    func write(_ file: NoteFile) throws {
        let folder = directory(file.id)
        try files.createDirectory(at: folder.appendingPathComponent("strokes"), withIntermediateDirectories: true)
        try file.data().write(to: folder.appendingPathComponent("note.xml"), options: .atomic)
        clearThumbnails(in: folder)
    }

    func strokeData(_ noteID: String) -> [String: Data] {
        let folder = directory(noteID).appendingPathComponent("strokes")
        var out: [String: Data] = [:]
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".bin") {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { out[String(name.dropLast(4))] = data }
        }
        return out
    }

    public func removeEverything() {
        lock.lock(); cached = nil; lock.unlock()
        try? files.removeItem(at: root.appendingPathComponent("notes"))
        try? files.removeItem(at: libraryURL)
        try? files.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
    }

    public func load(_ noteID: String) throws -> LoadedNote {
        let folder = directory(noteID)
        var document = try NoteDocument(xml: try Data(contentsOf: folder.appendingPathComponent("note.xml")))
        // A cropped picture names the part shown in pixels of its file: with the file at hand,
        // that is exact, where the frames on the page are rounded to whole units.
        for index in document.floating.indices {
            guard let cut = document.floating[index].cropPixels, let hash = document.floating[index].pictureFile, let size = LocalStore.pixelSize(of: mediaURL(noteID, hash)) else { continue }
            let width = size.width, height = size.height
            let part = CGRect(x: cut.minX / width, y: cut.minY / height, width: cut.width / width, height: cut.height / height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if !part.isNull, part.width > 0.001, part.height > 0.001 { document.floating[index].crop = part.width > 0.9995 && part.height > 0.9995 ? nil : part }
        }
        // What a sticky note says is in a file of its own.
        for page in document.pages.indices {
            for index in document.pages[page].objects.indices where document.pages[page].objects[index].kind == .sticky {
                guard let hash = document.pages[page].objects[index].attachFile, let found = LocalStore.sticky(at: mediaURL(noteID, hash)) else { continue }
                document.pages[page].objects[index].sticky = found.document
                document.pages[page].objects[index].stickyIsExact = found.exact
                if document.pages[page].objects[index].paper == nil { document.pages[page].objects[index].paper = found.document.paper }
            }
        }
        var strokes: [String: InkStroke] = [:]
        for object in document.allObjects where object.kind == .stroke {
            let url = folder.appendingPathComponent("strokes").appendingPathComponent(LocalStore.safeName(object.id) + ".bin")
            guard let data = try? Data(contentsOf: url), var stroke = try? StrokeDecoder.decode(data) else { continue }
            stroke.penName = stroke.penNameID.flatMap { document.penNames[$0] }
            stroke.setting = stroke.settingID.flatMap { document.penNames[$0] }
            strokes[object.id] = stroke
        }
        return LoadedNote(document: document, strokes: strokes, directory: folder)
    }

    /// Raised when the drawing of cards changes, so pictures made by an older build are not shown.
    public static let thumbnailVersion = 8

    public func thumbnailURL(_ noteID: String, dark: Bool) -> URL {
        directory(noteID).appendingPathComponent("thumb-v\(LocalStore.thumbnailVersion)\(dark ? "-dark" : "").png")
    }

    func clearThumbnails(in folder: URL) {
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("thumb") {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
