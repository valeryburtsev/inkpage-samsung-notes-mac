import CoreGraphics
import CryptoKit
import Foundation

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension XMLNode {
    /// The element as XML text. Attribute order is not kept; the service does not depend on it.
    public func serialized() -> String {
        var out = "<\(name)"
        for key in attributes.keys.sorted() { out += " \(key)=\"\(attributes[key]!.escapedXML)\"" }
        if children.isEmpty && text.isEmpty { return out + " />" }
        out += ">"
        if children.isEmpty { out += text.escapedXML } else { for child in children { out += child.serialized() } }
        return out + "</\(name)>"
    }

    func copy() -> XMLNode {
        let node = XMLNode(name: name, attributes: attributes)
        node.text = text
        node.children = children.map { $0.copy() }
        return node
    }

    @discardableResult
    func ensureChild(_ name: String) -> XMLNode {
        if let existing = child(name) { return existing }
        let node = XMLNode(name: name, attributes: [:])
        children.append(node)
        return node
    }
}

/// The identity hashes of the note tree: they cover an element's id and time, not its content.
public enum NoteHash {
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Objects, the body text and the title: SHA-256 of id followed by the time as printed.
    public static func object(id: String, time: String) -> String { hex(digest(Data((id + time).utf8))) }

    /// Layers and pages: SHA-256 of their children's raw hashes, then of their own id and time.
    public static func container(id: String, time: String, children: [String]) -> String {
        var data = Data()
        for child in children { data.append(AccountCrypto.data(hex: child) ?? Data()) }
        data.append(digest(Data((id + time).utf8)))
        return hex(digest(data))
    }

    /// Checks every hash in a `noteTree` element.
    public static func verify(tree: XMLNode) -> Bool {
        var ok = true
        for page in tree.child("pageList")?.all("page") ?? [] {
            var layerHashes: [String] = []
            for layer in page.child("layerList")?.all("layer") ?? [] {
                let objects = layer.child("objectList")?.all("object") ?? []
                for object in objects { ok = ok && object["h"] == NoteHash.object(id: object["id"] ?? "", time: object["t"] ?? "") }
                let hash = container(id: layer["id"] ?? "", time: layer["t"] ?? "", children: objects.map { $0["h"] ?? "" })
                ok = ok && layer["h"] == hash
                layerHashes.append(hash)
            }
            ok = ok && page["h"] == container(id: page["id"] ?? "", time: page["t"] ?? "", children: layerHashes)
        }
        if let body = tree.child("bodyText") { ok = ok && body["h"] == NoteHash.object(id: body["id"] ?? "", time: body["t"] ?? "") }
        return ok
    }
}

/// A stored note document that can be changed and turned into the documents the service takes.
public struct NoteFile {
    public let root: XMLNode
    let note: XMLNode
    /// The size in pixels of a picture file of the note, by the file's hash, where the files
    /// are at hand: a cropped picture's frames are worked out from it exactly.
    public var pixelSize: ((String) -> CGSize?)?

    public enum Failure: Error { case noNote }

    public init(data: Data) throws {
        root = try XMLTree.parse(data)
        guard let found = root.name.lowercased() == "noteresource" ? root : (root.child("noteResource") ?? root.descendant("NoteResource")) else { throw Failure.noNote }
        note = found
    }

    public func data() -> Data { Data(root.serialized().utf8) }

    /// True when title and text are each in one style this client can write back unchanged.
    public var textIsEditable: Bool {
        TextStyle.read(encoded: titleObject?.value("text") ?? "").editable && TextStyle.read(encoded: bodyObject?.value("text") ?? "").editable
    }

    public var id: String { note["id"] ?? "" }
    var attributes: XMLNode { note.ensureChild("attributes") }
    var tree: XMLNode { note.ensureChild("noteTree") }
    var titleObject: XMLNode? { attributes.child("title")?.child("object") }
    var bodyObject: XMLNode? { note.all("bodyText").compactMap { $0.child("object") }.first }

    static func micros(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970 * 1_000_000)) }
    static func millis(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970 * 1000)) }

    /// Marks the document as changed now.
    func touch(_ now: Date, content: Bool) {
        note.attributes["syncModifiedTime"] = NoteFile.millis(now)
        attributes.attributes["displayModifiedTime"] = NoteFile.millis(now)
        if content {
            attributes.attributes["modifiedTime"] = NoteFile.micros(now)
            attributes.attributes["fileRevision"] = String((attributes.int("fileRevision") ?? 0) + 1)
        }
    }

    static func setText(_ object: XMLNode, encoded: String, spans: [String]) {
        object.children.removeAll { $0.name == "spanOrderDataList" || $0.name == "text" }
        guard !encoded.isEmpty else { return }
        let list = XMLNode(name: "spanOrderDataList", attributes: [:])
        list.children = spans.map { XMLNode(name: "spanOrderData", attributes: ["val": Data($0.utf8).base64EncodedString()]) }
        let text = XMLNode(name: "text", attributes: [:])
        text.text = encoded
        object.children.append(contentsOf: [list, text])
    }

    public func setTitle(_ title: String, now: Date = Date()) {
        guard let object = titleObject else { return }
        let time = NoteFile.micros(now)
        object.attributes["modifiedTime"] = time
        object.attributes["hash"] = NoteHash.object(id: object["id"] ?? "", time: time)
        let style = TextStyle.read(encoded: object.value("text") ?? "").style ?? .newTitle
        let encoded = style.title(title)
        NoteFile.setText(object, encoded: encoded.text, spans: encoded.spans)
        touch(now, content: true)
    }

    public func setBody(_ body: String, now: Date = Date()) {
        guard let object = bodyObject else { return }
        let time = NoteFile.micros(now)
        let hash = NoteHash.object(id: object["id"] ?? "", time: time)
        object.attributes["modifiedTime"] = time
        object.attributes["hash"] = hash
        let style = TextStyle.read(encoded: object.value("text") ?? "").style ?? .newBody
        let encoded = style.body(body)
        NoteFile.setText(object, encoded: encoded.text, spans: encoded.spans)
        if let skeleton = tree.child("bodyText") {
            skeleton.attributes["t"] = time
            skeleton.attributes["h"] = hash
        }
        touch(now, content: true)
    }

    public func setState(_ state: TreeNode.State, now: Date = Date()) {
        attributes.attributes["state"] = state.rawValue
        touch(now, content: false)
    }

    public func setFavorite(_ favorite: Bool, now: Date = Date()) {
        attributes.attributes["isFavorite"] = favorite ? "True" : "False"
        touch(now, content: false)
    }

    // MARK: Text as stored

    static func noteText(of object: XMLNode?, body: Bool) -> NoteText {
        guard let object, let encoded = object.value("text"), !encoded.isEmpty else { return NoteText(hasSection: body) }
        let list = object.child("spanOrderDataList")?.all("spanOrderData").compactMap { $0["val"]?.decodedBase64 } ?? []
        var text = NoteText(encoded: encoded, spanList: list)
        if text.isEmpty { text.hasSection = body }
        return text
    }

    /// The note's text exactly as stored, attributes and all.
    public var bodyText: NoteText { NoteFile.noteText(of: bodyObject, body: true) }
    public var titleText: NoteText { NoteFile.noteText(of: titleObject, body: false) }

    /// Stores a new text for the body, with whatever attributes it carries.
    public func setBodyText(_ text: NoteText, now: Date = Date()) {
        guard let object = bodyObject else { return }
        let time = NoteFile.micros(now)
        let hash = NoteHash.object(id: object["id"] ?? "", time: time)
        object.attributes["modifiedTime"] = time
        object.attributes["hash"] = hash
        var body = text
        body.hasSection = true
        let encoded = body.encoded()
        NoteFile.setText(object, encoded: encoded.text, spans: encoded.spanList)
        if let skeleton = tree.child("bodyText") {
            skeleton.attributes["t"] = time
            skeleton.attributes["h"] = hash
        }
        touch(now, content: true)
    }

    public func setTitleText(_ text: NoteText, now: Date = Date()) {
        guard let object = titleObject else { return }
        let time = NoteFile.micros(now)
        object.attributes["modifiedTime"] = time
        object.attributes["hash"] = NoteHash.object(id: object["id"] ?? "", time: time)
        var title = text
        title.hasSection = false
        title.string = title.string.replacingOccurrences(of: "\n", with: " ")
        let encoded = title.encoded()
        NoteFile.setText(object, encoded: encoded.text, spans: encoded.spanList)
        touch(now, content: true)
    }

    // MARK: Ink

    public static let fountainPen = "com.samsung.android.sdk.pen.pen.preload.FountainPen"
    static let fountainPenSetting = "18;0;100;"

    public var pageCount: Int { note.all("pageList").last?.all("page").count ?? 0 }

    public func pageSize(_ index: Int) -> (width: Int, height: Int) {
        let page = note.all("pageList").last?.all("page")[safe: index]
        return (page?.int("width") ?? 848, page?.int("height") ?? 1200)
    }

    /// The place of a string in the note's string table, added when it is not there yet.
    func stringID(_ text: String) -> Int {
        let list = attributes.ensureChild("stringIdList")
        let encoded = Data(text.utf8).base64EncodedString()
        if let found = list.all("stringId").first(where: { $0["text"] == encoded }), let id = found.int("id") { return id }
        let id = (list.all("stringId").compactMap { $0.int("id") }.max() ?? -1) + 1
        list.children.append(XMLNode(name: "stringId", attributes: ["id": String(id), "text": encoded]))
        return id
    }

    /// The ids strokes of a pen carry: the pen's name and its setting.
    public func penIDs(_ pen: Pen = .fountain) -> (name: Int, setting: Int) {
        let name = stringID(pen.name)
        return (name, stringID(pen.setting))
    }

    /// The layers of a page, in the full page list and in the tree, that strokes go on.
    func layers(page index: Int) -> (full: XMLNode, tree: XMLNode, fullPage: XMLNode, treePage: XMLNode)? {
        guard let fullPage = note.all("pageList").last?.all("page")[safe: index],
              let treePage = tree.child("pageList")?.all("page").first(where: { $0["id"] == fullPage["id"] }),
              let full = fullPage.child("layerList")?.all("layer").first,
              let treeLayer = treePage.child("layerList")?.all("layer").first(where: { $0["id"] == full["id"] }) else { return nil }
        return (full, treeLayer, fullPage, treePage)
    }

    /// Gives a changed page and its layer a new time and the hashes that follow from it.
    func rehash(page index: Int, now: Date) {
        guard let found = layers(page: index) else { return }
        let stamp = Int64(now.timeIntervalSince1970 * 1_000_000)
        let layerTime = String(stamp), pageTime = String(stamp + 30)
        let objects = found.tree.child("objectList")?.all("object").map { $0["h"] ?? "" } ?? []
        let layerHash = NoteHash.container(id: found.tree["id"] ?? "", time: layerTime, children: objects)
        found.tree.attributes["t"] = layerTime; found.tree.attributes["h"] = layerHash
        found.full.attributes["modifiedTime"] = layerTime; found.full.attributes["hash"] = layerHash
        let layerHashes = found.treePage.child("layerList")?.all("layer").map { $0["h"] ?? "" } ?? []
        let pageHash = NoteHash.container(id: found.treePage["id"] ?? "", time: pageTime, children: layerHashes)
        found.treePage.attributes["t"] = pageTime; found.treePage.attributes["h"] = pageHash
        found.fullPage.attributes["modifiedTime"] = pageTime; found.fullPage.attributes["hash"] = pageHash
        touch(now, content: true)
    }

    /// Enters strokes on a page. Each is given by its id and its modified time as the record has it.
    public func addStrokes(_ strokes: [(id: String, modifiedMicros: Int64, bounds: CGRect)], page index: Int, argb: UInt32, penSize: Double, pen: Pen = .fountain, now: Date = Date()) {
        guard !strokes.isEmpty, let found = layers(page: index) else { return }
        let fullList = found.full.ensureChild("objectList"), treeList = found.tree.ensureChild("objectList")
        var drawn = found.fullPage.child("drawnRect").map(NoteDocument.rect) ?? .null
        if drawn.isEmpty && drawn.origin == .zero { drawn = .null }
        for stroke in strokes {
            let time = String(stroke.modifiedMicros)
            let hash = NoteHash.object(id: stroke.id, time: time)
            fullList.children.append(XMLNode(name: "object", attributes: ["type": "stroke", "id": stroke.id, "hash": hash, "modifiedTime": time]))
            treeList.children.append(XMLNode(name: "object", attributes: ["id": stroke.id, "t": time, "h": hash]))
            drawn = drawn.union(stroke.bounds.insetBy(dx: -(penSize + 1), dy: -(penSize + 1)))
        }
        if !drawn.isNull {
            let node = found.fullPage.child("drawnRect") ?? {
                let created = XMLNode(name: "drawnRect", attributes: [:])
                found.fullPage.children.insert(created, at: 0)
                return created
            }()
            node.attributes = ["l": String(Float(drawn.minX)), "t": String(Float(drawn.minY)), "r": String(Float(drawn.maxX)), "b": String(Float(drawn.maxY))]
        }
        _ = penIDs(pen)
        let used = pen
        let pen = attributes.ensureChild("penInfo")
        if pen.attributes.isEmpty {
            pen.attributes = ["isCurvable": "True", "isEraserEnabled": "False", "sizeLevel": "30", "particleDensity": "1", "particleSize": "0", "isFixedWidth": "False",
                              "hsv0": "0", "hsv1": "0", "hsv2": "0", "colorUIInfo": "0", "isFixedOpacity": "False", "isAutoSizeEnabled": "False", "fitRatio": "1"]
        }
        pen.attributes["name"] = Data(used.name.utf8).base64EncodedString()
        pen.attributes["size"] = String(Float(penSize))
        pen.attributes["color"] = String(Int32(bitPattern: argb))
        rehash(page: index, now: now)
    }

    /// Takes objects off their pages. Returns the ids that were there.
    @discardableResult
    public func removeObjects(_ ids: Set<String>, now: Date = Date()) -> Set<String> {
        var removed: Set<String> = []
        for index in 0..<pageCount {
            guard let found = layers(page: index) else { continue }
            var changed = false
            for list in [found.full.child("objectList"), found.tree.child("objectList")].compactMap({ $0 }) {
                let before = list.children.count
                for child in list.children where ids.contains(child["id"] ?? "") { removed.insert(child["id"] ?? "") }
                list.children.removeAll { ids.contains($0["id"] ?? "") }
                changed = changed || list.children.count != before
            }
            if changed { rehash(page: index, now: now) }
        }
        return removed
    }

    /// The same note under a new id and title, for keeping what was written here beside another version.
    public func copy(newID: String, title: String, now: Date = Date()) throws -> NoteFile {
        let file = try NoteFile(data: data())
        file.note.attributes["id"] = newID
        if TextStyle.read(encoded: file.titleObject?.value("text") ?? "").editable { file.setTitle(title, now: now) } else { file.touch(now, content: true) }
        file.attributes.attributes["state"] = "normal"
        file.attributes.attributes["fileRevision"] = "1"
        return file
    }

    /// The ids of the pages and their layers.
    public var pageAndLayerIDs: Set<String> {
        var ids: Set<String> = []
        for page in note.all("pageList").last?.all("page") ?? [] {
            if let id = page["id"] { ids.insert(id) }
            for layer in page.child("layerList")?.all("layer") ?? [] { if let id = layer["id"] { ids.insert(id) } }
        }
        return ids
    }

    /// The tree of ids, times and hashes the service compares against its own.
    public func treeDocument() -> String {
        let copy = tree.copy()
        copy.attributes = ["ver": "4000"]
        return copy.serialized()
    }

    /// The document for an upload: always the tree and the attributes; the pages and the body
    /// text when asked for.
    /// `files` and `floating` name the file entries and floating objects to send; nil sends all.
    public func uploadDocument(pages: Bool, body: Bool, files: Set<String>? = nil, floating: Set<String>? = nil) -> String {
        // A locked note names whose it is. The service hands a locked note down without the name
        // on the note itself (it is among the note's attributes); the Windows client fills it in
        // when it sends the note. (An update of a locked note sent without it was refused with
        // "Request payload invalid" on 2026-10-13, and accepted once it was sent with it.)
        var owner = note["ownerId"] ?? ""
        if owner.isEmpty, note.bool("isLocked") { owner = attributes["ownerId"] ?? "" }
        let out = XMLNode(name: "NoteResource", attributes: [
            "id": id, "syncModifiedTime": note["syncModifiedTime"] ?? "0", "createdTime": note["createdTime"] ?? "0",
            "isLocked": note.bool("isLocked") ? "True" : "False", "isEncrypted": note.bool("isEncrypted") ? "True" : "False",
            "ownerId": owner, "xmlVer": "2",
        ])
        let treeCopy = tree.copy()
        treeCopy.attributes = ["ver": "4000"]
        out.children.append(treeCopy)
        func chosen(_ name: String, _ element: String, _ ids: Set<String>?) -> XMLNode? {
            guard let list = note.child(name) else { return nil }
            let copy = XMLNode(name: name, attributes: [:])
            // An entry the service itself delivered is the service's own; only complete ones go out.
            copy.children = list.all(element).filter { (ids == nil || ids!.contains($0["id"] ?? "")) && (element != "contentFile" || $0["name"] != nil) }.map { $0.copy() }
            return copy.children.isEmpty ? nil : copy
        }
        if let list = chosen("contentFileList", "contentFile", files) { out.children.append(list) }
        out.children.append(attributes.copy())
        if pages, let list = note.all("pageList").last { out.children.append(list.copy()) }
        if let list = chosen("floatingObjectList", "object", floating) { out.children.append(list) }
        if body, let holder = note.all("bodyText").first(where: { $0.child("object") != nil }) { out.children.append(holder.copy()) }
        return out.serialized()
    }

    /// How a new note's pages are laid out, as the Windows client's settings offer it.
    public struct Layout: Equatable, Sendable {
        /// Pages twice as high as they are wide, in place of the proportions of a sheet of paper.
        public var long = false
        /// One page that grows as it is written on, in place of separate pages.
        public var endless = false
        public init(long: Bool = false, endless: Bool = false) { self.long = long; self.endless = endless }
    }

    /// True for a note of one page that grows as it is written on.
    public var isEndless: Bool { attributes["pageMode"] == "1" }

    /// Makes the one page of an endless note higher when what is on it reaches to `bottom` (in
    /// page units from the page's top), as the Windows client does: the page is always a whole
    /// number of its first heights high, with about one of them to spare under what it holds.
    /// True when it grew.
    @discardableResult
    public func growEndlessPage(toHold bottom: Double, now: Date = Date()) -> Bool {
        guard isEndless, bottom.isFinite, let page = note.all("pageList").last?.all("page").first else { return false }
        let step = Double(attributes.int("pageDefaultHeight") ?? 0), height = Double(page.int("height") ?? 0)
        guard step > 1, height > 0 else { return false }
        if height > step, bottom <= height - step { return false }
        if height <= step, bottom <= 0 { return false }
        let grown = min(max(height + step, step * ((bottom / step).rounded(.up) + 1)), step * 400)
        guard grown > height else { return false }
        page.attributes["height"] = String(Int(grown))
        attributes.attributes["height"] = String(Int(grown))
        restamp(page: 0, now: now)
        touch(now, content: true)
        return true
    }

    /// A new, empty-paged text note, laid out as the Windows client creates them.
    public static func newTextNote(title: String, body: String, layout: Layout = Layout(), now: Date = Date()) -> NoteFile {
        func uuid() -> String { UUID().uuidString.lowercased() }
        // A page 848 wide: a sheet of paper's proportions, or twice as high as wide. An endless
        // note has one page, of a sheet's proportions; a note of pages has two, the second to spare.
        let pageHeight = layout.endless ? 1200 : (layout.long ? 1696 : 1200)
        let pageCount = layout.endless ? 1 : 2
        let noteHeight = pageCount * pageHeight + (pageCount - 1) * 8
        let noteID = uuid()
        let micros = Int64(now.timeIntervalSince1970 * 1_000_000)
        let millis = NoteFile.millis(now)
        var pagesTree = "", pagesFull = ""
        for index in 0..<pageCount {
            let pageID = uuid(), layerID = uuid()
            let layerTime = String(micros - 60_000 + Int64(index) * 100), pageTime = String(micros - 59_000 + Int64(index) * 100)
            let layerHash = NoteHash.container(id: layerID, time: layerTime, children: [])
            let pageHash = NoteHash.container(id: pageID, time: pageTime, children: [layerHash])
            pagesTree += #"<page id="\#(pageID)" t="\#(pageTime)" h="\#(pageHash)"><layerList><layer id="\#(layerID)" t="\#(layerTime)" h="\#(layerHash)" /></layerList></page>"#
            pagesFull += #"<page id="\#(pageID)" hash="\#(pageHash)" isTextOnly="False" orientation="0" width="848" height="\#(pageHeight)" offsetX="0" offsetY="0" formatVersion="4000" bgImageMode="2" bgColor="-197380" bgWidth="848" minFormatVersion="4000" editableFormatVersion="4000" currentLayerIndex="0" createdTime="0" modifiedTime="\#(pageTime)"><layerList><layer id="\#(layerID)" hash="\#(layerHash)" flagEventForwardable="True" visible="True" lockState="False" layerNumber="0" createdTime="0" modifiedTime="\#(layerTime)" thumbnail="-1" /></layerList></page>"#
        }
        let titleID = uuid(), bodyID = uuid()
        let time = String(micros)
        let box = #"formatVersion="4000" rotatable="True" selectable="True" movable="True" flippable="True" visible="True" isReplayable="True" clippable="True" isTemplateObject="False" timeStamp="0" resizable="0" haveBeenToAtt="True" lockState="False" createdTime="0" modifiedTime="\#(time)" removable="True" isHorizontalFlipped="False" isVerticalFlipped="False" isHintTextVisible="False" isTextReadOnly="False" isTextEditable="True" isTransparency="False" shapeType="4" originalDegree="0""#
        let inner = #"<rect l="0" t="0" r="0" b="0" /><lineColorEffect colorType="2" gradientRotatable="False" solidColor="-16777216" gradientType="0" angle="0"><radialGradientPosition x="0" y="0" /></lineColorEffect><lineStyleEffect width="0" compoundType="0" dashType="0" capType="0" joinType="0" beginArrowType="0" beginArrowSize="0" endArrowType="0" endArrowSize="0" /><originalRect l="0" t="0" r="0" b="0" />"#
        let xml = """
        <NoteResource id="\(noteID)" syncModifiedTime="\(millis)" createdTime="\(time)" isLocked="False" isEncrypted="False" ownerId="" xmlVer="2">\
        <noteTree ver="4000"><pageList>\(pagesTree)</pageList><bodyText id="\(bodyID)" t="\(time)" h="\(NoteHash.object(id: bodyID, time: time))" /></noteTree>\
        <attributes isBgColorInverted="True" tapeVisibility="True" formatVersion="4000" fileRevision="1" modifiedTime="\(time)" editTime="0" width="848" height="\(noteHeight)" pageHorizontalPadding="0" pageVerticalPadding="8" pageDefaultWidth="848" pageDefaultHeight="\(pageHeight)" minFormatVersion="4000" editableFormatVersion="4000" lastEditedPageIndex="0" lastEditedPageImageId="-1" lastEditedPageTime="0" bodyTextFontSizeDelta="0" orientation="0" pageMode="0" documentType="0" ownerId="" lastRecognizedDataModifiedTime="0" fixedFont="" fixedTextDirection="2" fixedBackgroundTheme="2" isFavorite="False" state="normal" bookmark="[]" mappedUuid="" mappedAt="0" isConverted="False" displayCreatedTime="\(millis)" displayModifiedTime="\(millis)" msSyncAccountId="" msSyncDocumentId="" msLastSyncTime="0">\
        <title><object type="textBox" id="\(titleID)" hash="\(NoteHash.object(id: titleID, time: time))" \(box) leftMargin="11.25" topMargin="0" rightMargin="11.25" bottomMargin="0" textGravity="0" ellipsisType="2">\(inner)</object></title></attributes>\
        <pageList>\(pagesFull)</pageList>\
        <bodyText id="\(bodyID)"><object type="textBox" id="\(bodyID)" hash="\(NoteHash.object(id: bodyID, time: time))" \(box) leftMargin="16" topMargin="10" rightMargin="16" bottomMargin="10" textGravity="0" ellipsisType="2">\(inner)</object></bodyText>\
        </NoteResource>
        """
        let file = try! NoteFile(data: Data(xml.utf8))
        if !title.isEmpty { file.setTitle(title, now: now) }
        if !body.isEmpty { file.setBody(body, now: now) }
        if layout.endless { file.attributes.attributes["pageMode"] = "1" }
        file.attributes.attributes["fileRevision"] = "1"
        return file
    }
}

/// The style of a text that is in one style throughout: the attributes its encoding opens with,
/// in their order. Text typed on this Mac is written back in the style the note already had, so
/// the encoding stays byte for byte what the Windows client would write.
public struct TextStyle: Equatable, Sendable {
    public struct Token: Equatable, Sendable {
        public var key: String
        public var value: String
    }
    public var tokens: [Token]

    /// What the Windows client gives the text of a new note.
    public static let newBody = TextStyle(tokens: [
        Token(key: "span/foregroundColor", value: "1,-14342875"), Token(key: "span/backgroundColor", value: "1,0"), Token(key: "span/fontSize", value: "1,12"),
        Token(key: "paragraph/alignment", value: "0"), Token(key: "paragraph/parsingState", value: "False"), Token(key: "sectionData/sectionData", value: "0"),
    ])
    public static let newTitle = TextStyle(tokens: [Token(key: "span/foregroundColor", value: "1,-14342875"), Token(key: "paragraph/parsingState", value: "False")])

    /// The numbers the span list gives the attributes it repeats.
    static let spanTypes = ["span/foregroundColor": 1, "span/fontSize": 3, "span/backgroundColor": 17]

    public static func tokens(_ instruction: Substring) -> [(key: String, value: String?)] {
        var out: [(String, String?)] = []
        var rest = instruction
        while let open = rest.firstIndex(of: "'") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "'") else { break }
            let key = String(rest[afterOpen..<close])
            rest = rest[rest.index(after: close)...]
            if rest.hasPrefix("='") {
                let start = rest.index(rest.startIndex, offsetBy: 2)
                guard let end = rest[start...].firstIndex(of: "'") else { break }
                out.append((key, String(rest[start..<end])))
                rest = rest[rest.index(after: end)...]
            } else {
                out.append((key, nil))
            }
        }
        return out
    }

    /// The style of an encoded text. `style` is nil for an empty text; `editable` is false when
    /// the text has more than one style, holds pictures, or uses attributes this client cannot write.
    public static func read(encoded: String) -> (style: TextStyle?, editable: Bool) {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, true) }
        guard let data = Data(base64Encoded: trimmed), let stream = String(data: data, encoding: .utf8) else { return (nil, false) }
        var instructions: [[(key: String, value: String?)]] = []
        var rest = Substring(stream)
        while let start = rest.range(of: "<?a"), let end = rest.range(of: "?>", range: start.upperBound..<rest.endIndex) {
            instructions.append(tokens(rest[start.upperBound..<end.lowerBound]))
            rest = rest[end.upperBound...]
        }
        guard let first = instructions.first else { return (nil, false) }
        let opening = first.compactMap { token in token.value.map { Token(key: token.key, value: $0) } }
        var editable = opening.count == first.count
        // Only text in the plain attributes is written here: anything else (bold, bullets, links,
        // pictures) would be lost or garbled by an edit.
        let plain: Set<String> = ["span/foregroundColor", "span/backgroundColor", "span/fontSize", "paragraph/alignment", "paragraph/parsingState", "sectionData/sectionData"]
        for token in opening { editable = editable && plain.contains(token.key) }
        for later in instructions.dropFirst() {
            for token in later where token.value != nil {
                let known = token.key == "paragraph/parsingState" || token.key == "sectionData/sectionData"
                editable = editable && known
            }
        }
        return (TextStyle(tokens: opening), editable)
    }

    static func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    func spans(length: Int) -> [String] {
        tokens.compactMap { token in TextStyle.spanTypes[token.key].map { "\($0),0,\(length),\(token.value)" } }
    }

    /// A title: one paragraph.
    public func title(_ text: String) -> (text: String, spans: [String]) {
        guard !text.isEmpty else { return ("", []) }
        let opening = tokens.map { "'\($0.key)'='\($0.value)'" }.joined(separator: " ")
        let closing = tokens.map { "'\($0.key)'" }.joined(separator: " ")
        return (TextStyle.b64("<?a \(opening)?>\(TextStyle.b64(text))<?a \(closing)?>"), spans(length: text.utf16.count))
    }

    /// A note's text: a paragraph per line, each later one starting with its line break.
    public func body(_ text: String) -> (text: String, spans: [String]) {
        guard !text.isEmpty else { return ("", []) }
        let length = text.utf16.count
        let lines = text.components(separatedBy: "\n")
        let opening = tokens.map { "'\($0.key)'='\($0.key == "sectionData/sectionData" ? String(length) : $0.value)'" }.joined(separator: " ")
        var stream = "<?a \(opening)?>" + TextStyle.b64(lines[0])
        for (index, line) in lines.dropFirst().enumerated() {
            stream += index == 0 ? "<?a 'paragraph/alignment' 'paragraph/parsingState' 'paragraph/parsingState'='False'?>" : "<?a 'paragraph/parsingState' 'paragraph/parsingState'='False'?>"
            stream += TextStyle.b64("\n" + line)
        }
        // The alignment was closed after the first paragraph when there are more.
        let closing = tokens.filter { lines.count == 1 || $0.key != "paragraph/alignment" }.map { "'\($0.key)'" }.joined(separator: " ")
        stream += "<?a \(closing)?><?a 'sectionData/sectionData'='0' 'sectionData/sectionData'?>"
        return (TextStyle.b64(stream), spans(length: length))
    }
}
