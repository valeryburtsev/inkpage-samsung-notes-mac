import CoreGraphics
import Foundation

/// Sticky notes of an editable note. Each is a "custom object" of the page it is stuck on:
/// the small square it shows as, the colour of its paper, and the file that holds what it
/// says (a note document of its own, see `StickyDocument`).
extension NoteFile {
    /// The format a note with a sticky note says it is in, and its page with it.
    static let stickyFormat = 5303

    private static func encoded(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    /// A rectangle as the clients write it into a sticky note's data: every number with a point.
    static func stickyRect(_ rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.maxX, rect.maxY].map { value -> String in
            let text = float(value)
            return text.contains(".") || text.contains("e") ? text : text + ".0"
        }.joined(separator: ",")
    }

    private var stickyPages: [XMLNode] { note.all("pageList").last?.all("page") ?? [] }

    /// The page a sticky note is on, and its entry there.
    func stickyNode(_ id: String) -> (page: Int, node: XMLNode)? {
        for (index, page) in stickyPages.enumerated() {
            if let node = page.child("customObjectList")?.all("customObject").first(where: { $0["id"] == id }) { return (index, node) }
        }
        return nil
    }

    private static func pair(_ node: XMLNode, _ list: String, _ key: String) -> XMLNode? {
        node.child(list)?.all("pair").first { $0["key"]?.decodedBase64 == key }
    }

    /// The file a sticky note keeps what it says in.
    public func stickyFile(_ id: String) -> String? { stickyNode(id).flatMap { NoteFile.pair($0.node, "attachedFileList", "co_attach_file")?["value"] } }

    /// A page that changed beside its layers: a new time, and the hash that follows from it.
    func restamp(page index: Int, now: Date) {
        guard let page = stickyPages[safe: index] else { return }
        let time = NoteFile.micros(now)
        page.attributes["modifiedTime"] = time
        if let listed = tree.child("pageList")?.all("page").first(where: { $0["id"] == page["id"] }) {
            let hash = NoteHash.container(id: page["id"] ?? "", time: time, children: listed.child("layerList")?.all("layer").map { $0["h"] ?? "" } ?? [])
            listed.attributes["t"] = time
            listed.attributes["h"] = hash
            page.attributes["hash"] = hash
        }
    }

    private func shape(_ node: XMLNode, rect: CGRect?, paper: UInt32?, fileHash: String?) {
        func list(_ name: String) -> XMLNode {
            if let found = node.child(name) { return found }
            let made = XMLNode(name: name, attributes: [:])
            node.children.insert(made, at: name == "attachedFileList" ? 0 : min(node.children.count, node.child("attachedFileList") == nil ? 0 : 1))
            return made
        }
        func set(_ name: String, _ key: String, _ value: String) {
            if let found = NoteFile.pair(node, name, key) { found.attributes["value"] = value; return }
            list(name).children.append(XMLNode(name: "pair", attributes: ["key": NoteFile.encoded(key), "value": value]))
        }
        if let fileHash { set("attachedFileList", "co_attach_file", fileHash) }
        if let rect {
            set("customDataList", "skn_collapse_rect", NoteFile.encoded(NoteFile.stickyRect(rect)))
            node.children.removeAll { $0.name == "rect" }
            node.children.append(XMLNode(name: "rect", attributes: ["l": NoteFile.float(rect.minX), "t": NoteFile.float(rect.minY), "r": NoteFile.float(rect.maxX), "b": NoteFile.float(rect.maxY)]))
        }
        if let paper { set("customDataList", "skn_bg_color", NoteFile.encoded(String(Int32(bitPattern: paper)))) }
    }

    /// Sticks a sticky note on a page: `rect` is the small square it shows as, `fileHash` and
    /// `fileName` its own document among the note's files. Written as the Windows client does.
    @discardableResult
    public func addSticky(id: String, fileHash: String, fileName: String, rect: CGRect, paper: UInt32, page index: Int, now: Date = Date()) -> Bool {
        guard let page = stickyPages[safe: index], stickyNode(id) == nil else { return false }
        addFile(hash: fileHash, name: fileName, now: now)
        let node = XMLNode(name: "customObject", attributes: ["id": id, "type": "1"])
        shape(node, rect: rect, paper: paper, fileHash: fileHash)
        let list: XMLNode
        if let found = page.child("customObjectList") {
            list = found
        } else {
            list = XMLNode(name: "customObjectList", attributes: [:])
            page.children.insert(list, at: page.children.firstIndex { $0.name == "layerList" } ?? page.children.count)
        }
        list.children.append(node)
        for name in ["formatVersion", "minFormatVersion"] where (page.int(name) ?? 0) < NoteFile.stickyFormat { page.attributes[name] = String(NoteFile.stickyFormat) }
        raiseFormat(to: NoteFile.stickyFormat, body: false)
        restamp(page: index, now: now)
        touch(now, content: true)
        return true
    }

    /// Changes a sticky note: the file with what it says, its paper, where its square lies,
    /// the page it is on. What is not given stays.
    @discardableResult
    public func setSticky(_ id: String, fileHash: String? = nil, fileName: String? = nil, paper: UInt32? = nil, rect: CGRect? = nil, page target: Int? = nil, now: Date = Date()) -> Bool {
        guard let found = stickyNode(id) else { return false }
        if let rect, !(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite) { return false }
        let old = NoteFile.pair(found.node, "attachedFileList", "co_attach_file")?["value"]
        if let fileHash, let fileName, fileHash != old {
            addFile(hash: fileHash, name: fileName, now: now)
            shape(found.node, rect: nil, paper: nil, fileHash: fileHash)
            if let old { releaseFile(old) }
        }
        shape(found.node, rect: rect, paper: paper, fileHash: nil)
        if let target, target != found.page, let page = stickyPages[safe: target], let from = stickyPages[safe: found.page] {
            from.child("customObjectList")?.children.removeAll { $0 === found.node }
            from.children.removeAll { $0.name == "customObjectList" && $0.children.isEmpty }
            let list: XMLNode
            if let present = page.child("customObjectList") {
                list = present
            } else {
                list = XMLNode(name: "customObjectList", attributes: [:])
                page.children.insert(list, at: page.children.firstIndex { $0.name == "layerList" } ?? page.children.count)
            }
            list.children.append(found.node)
            for name in ["formatVersion", "minFormatVersion"] where (page.int(name) ?? 0) < NoteFile.stickyFormat { page.attributes[name] = String(NoteFile.stickyFormat) }
            restamp(page: found.page, now: now)
            restamp(page: target, now: now)
        } else {
            restamp(page: found.page, now: now)
        }
        touch(now, content: true)
        return true
    }

    /// Takes a sticky note off its page, and its file out of the note.
    @discardableResult
    public func removeSticky(_ id: String, now: Date = Date()) -> Bool {
        guard let found = stickyNode(id), let page = stickyPages[safe: found.page] else { return false }
        let files = found.node.child("attachedFileList")?.all("pair").compactMap { $0["value"] } ?? []
        page.child("customObjectList")?.children.removeAll { $0 === found.node }
        page.children.removeAll { $0.name == "customObjectList" && $0.children.isEmpty }
        for file in files { releaseFile(file) }
        restamp(page: found.page, now: now)
        touch(now, content: true)
        return true
    }
}

extension LocalEdits {
    /// The size of a sticky note's square on a page of this width.
    public static func stickySide(pageWidth: Double) -> Double { StickyDocument.side * pageWidth / 360 }

    /// What a sticky note of a note says, read from its file; and whether this client can
    /// write that file again as it is, which is its leave to change it.
    public func sticky(_ noteID: String, id: String) -> (document: StickyDocument, exact: Bool)? {
        guard let file = try? store.noteFile(noteID), let hash = file.stickyFile(id) else { return nil }
        return LocalStore.sticky(at: store.mediaURL(noteID, hash))
    }

    /// Sticks a new sticky note on a page, its square's top left corner at `origin` (in the
    /// page's units). Returns its id.
    @discardableResult
    public func addSticky(_ noteID: String, page: Int, origin: CGPoint, text: String = "", paper: UInt32 = StickyDocument.papers[0], id: String? = nil, now: Date = Date()) throws -> String? {
        let document = StickyDocument(text: text, paper: paper, now: now)
        let data = document.archive, hash = NoteFile.sha256(data)
        return try change(noteID, now: now, pagesChanged: true, addedFiles: [hash]) { file -> String? in
            let size = file.pageSize(page)
            let side = LocalEdits.stickySide(pageWidth: Double(size.width))
            let made = id ?? UUID().uuidString.lowercased()
            let place = CGRect(x: min(max(origin.x, 0), Double(size.width) - side), y: min(max(origin.y, 0), Double(size.height) - side), width: side, height: side)
            store.writeFile(noteID, hash, data)
            return file.addSticky(id: made, fileHash: hash, fileName: document.fileName, rect: place, paper: paper, page: page, now: now) ? made : nil
        }
    }

    /// Puts a sticky note of Samsung's own kind where a picture lies (a sticky note that an
    /// earlier build of this app kept as a picture), saying this; the picture goes. Returns its id.
    @discardableResult
    public func replaceWithSticky(_ noteID: String, picture: String, text: String, paper: UInt32, id: String? = nil, now: Date = Date()) throws -> String? {
        let document = StickyDocument(text: text, paper: paper, now: now)
        let data = document.archive, hash = NoteFile.sha256(data)
        return try change(noteID, now: now, pagesChanged: true, addedFiles: [hash]) { file -> String? in
            guard let object = file.note.child("floatingObjectList")?.all("object").first(where: { $0["id"] == picture }) else { return nil }
            let page = min(max(object.int("pageIndex") ?? 0, 0), max(file.pageCount - 1, 0))
            let size = file.pageSize(page)
            let side = LocalEdits.stickySide(pageWidth: Double(size.width))
            let corner = object.child("rect").map { CGPoint(x: $0.double("l") ?? 0, y: $0.double("t") ?? 0) } ?? .zero
            let place = CGRect(x: min(max(corner.x, 0), Double(size.width) - side), y: min(max(corner.y, 0), Double(size.height) - side), width: side, height: side)
            _ = file.removeFloating([picture], now: now)
            let made = id ?? UUID().uuidString.lowercased()
            store.writeFile(noteID, hash, data)
            guard file.addSticky(id: made, fileHash: hash, fileName: document.fileName, rect: place, paper: paper, page: page, now: now) else { return nil }
            // Its place in the text, had it one, goes with the picture.
            _ = try settleText(file, now: now)
            return made
        }
    }

    /// Gives a sticky note other words or other paper. Only one whose file this client can
    /// write as it found it is changed. True when it was.
    @discardableResult
    public func setSticky(_ noteID: String, id: String, text: String? = nil, paper: UInt32? = nil, now: Date = Date()) throws -> Bool {
        try store.exclusive {
            let file = try store.noteFile(noteID)
            guard let old = file.stickyFile(id), let found = LocalStore.sticky(at: store.mediaURL(noteID, old)), found.exact else { return false }
            if (text ?? found.document.text) == found.document.text, (paper ?? found.document.paper) == found.document.paper { return false }
            let document = found.document.with(text: text, paper: paper, now: now)
            let data = document.archive, hash = NoteFile.sha256(data)
            return try change(noteID, now: now, pagesChanged: true, addedFiles: [hash]) { file -> Bool? in
                store.writeFile(noteID, hash, data)
                return file.setSticky(id, fileHash: hash, fileName: document.fileName, paper: document.paper, now: now) ? true : nil
            } ?? false
        }
    }

    /// Moves a sticky note's square, to another page when one is named.
    public func moveSticky(_ noteID: String, id: String, to rect: CGRect, page: Int? = nil, now: Date = Date()) throws {
        _ = try change(noteID, now: now, pagesChanged: true) { file -> Bool? in file.setSticky(id, rect: rect, page: page, now: now) ? true : nil }
    }

    public func removeSticky(_ noteID: String, id: String, now: Date = Date()) throws {
        _ = try change(noteID, now: now, pagesChanged: true) { file -> Bool? in file.removeSticky(id, now: now) ? true : nil }
    }
}

extension LocalStore {
    /// A sticky note's document read from its file, and whether it would be written the same.
    static func sticky(at url: URL) -> (document: StickyDocument, exact: Bool)? {
        guard let data = try? Data(contentsOf: url), let document = StickyDocument(archive: data) else { return nil }
        return (document, document.isExact(data))
    }
}
