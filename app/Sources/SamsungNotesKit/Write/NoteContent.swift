import CoreGraphics
import CryptoKit
import Foundation

/// Pictures, files and pages of an editable note.
extension NoteFile {
    /// How a number that the Windows client keeps as a 32-bit float is printed in its XML.
    static func float(_ value: Double) -> String { String(format: "%.9g", Double(Float(value))) }
    /// The same number where the client prints it widened to 64 bits.
    static func wide(_ value: Double) -> String { String(format: "%.15g", Double(Float(value))) }

    public static func sha256(_ data: Data) -> String { NoteHash.hex(NoteHash.digest(data)) }

    private func list(_ name: String, in parent: XMLNode, before: [String]) -> XMLNode {
        if let existing = parent.child(name) { return existing }
        let node = XMLNode(name: name, attributes: [:])
        let index = parent.children.firstIndex { before.contains($0.name) } ?? parent.children.count
        parent.children.insert(node, at: index)
        return node
    }

    var fileList: XMLNode { list("contentFileList", in: note, before: ["attributes", "pageList", "floatingObjectList", "bodyText"]) }
    var treeFileList: XMLNode { list("contentFileList", in: tree, before: ["floatingObjectList", "bodyText"]) }
    var floatingList: XMLNode { list("floatingObjectList", in: note, before: ["bodyText"]) }
    var treeFloatingList: XMLNode { list("floatingObjectList", in: tree, before: ["bodyText"]) }
    private func dropIfEmpty(_ name: String, in parent: XMLNode) { parent.children.removeAll { $0.name == name && $0.children.isEmpty } }

    /// The content hashes of the files the note refers to.
    public var fileIDs: [String] { (tree.child("contentFileList")?.all("contentFile") ?? []).compactMap { $0["id"] } }
    /// The ids of the objects that lie over the pages rather than on one of their layers.
    public var floatingIDs: [String] { (tree.child("floatingObjectList")?.all("object") ?? []).compactMap { $0["id"] } }

    /// Enters a file in the note's list of files. A file that is already there gains a reference.
    public func addFile(hash: String, name: String, now: Date = Date()) {
        let time = NoteFile.micros(now)
        if let existing = fileList.all("contentFile").first(where: { $0["id"] == hash }) {
            recount(existing, (existing.int("refCount") ?? 1) + 1, now: now)
            return
        }
        // Files downloaded with a note are listed in its tree only: the full entry is the service's to keep.
        if treeFileList.all("contentFile").contains(where: { $0["id"] == hash }) { return }
        let bind = (fileList.all("contentFile").compactMap { $0.int("bindNumber") }.max() ?? -1) + 1
        let digest = NoteHash.contentFile(id: hash, bindNumber: bind, name: "\(bind)@\(name)", refCount: 1, time: time)
        let entry = XMLNode(name: "contentFile", attributes: [
            "id": hash, "bindNumber": String(bind), "name": Data("\(bind)@\(name)".utf8).base64EncodedString(), "refCount": "1",
            "createdTime": "0", "modifiedTime": time, "hash": digest, "isFileAttached": "True",
        ])
        let inner = XMLNode(name: "fileHash", attributes: [:])
        inner.text = hash
        entry.children = [inner]
        fileList.children.append(entry)
        treeFileList.children.append(XMLNode(name: "contentFile", attributes: ["id": hash, "t": time, "h": digest]))
        treeFileList.children.sort { ($0["id"] ?? "") < ($1["id"] ?? "") }
    }

    /// Gives a file's entry a new count of references, and with it a new time and hash.
    private func recount(_ entry: XMLNode, _ count: Int, now: Date) {
        let time = NoteFile.micros(now)
        entry.attributes["refCount"] = String(count)
        entry.attributes["modifiedTime"] = time
        let digest = NoteHash.contentFile(id: entry["id"] ?? "", bindNumber: entry.int("bindNumber") ?? 0, name: entry["name"]?.decodedBase64 ?? "", refCount: count, time: time)
        entry.attributes["hash"] = digest
        if let listed = treeFileList.all("contentFile").first(where: { $0["id"] == entry["id"] }) {
            listed.attributes["t"] = time
            listed.attributes["h"] = digest
        }
    }

    /// Takes a reference from a file; with the last one its entry goes.
    func releaseFile(_ hash: String) {
        guard let entry = note.child("contentFileList")?.all("contentFile").first(where: { $0["id"] == hash }) else {
            // Known by the tree only: nothing else in the note may still show it.
            if !usesFile(hash) { tree.child("contentFileList")?.children.removeAll { $0["id"] == hash } }
            dropIfEmpty("contentFileList", in: tree)
            return
        }
        let count = (entry.int("refCount") ?? 1) - 1
        if count > 0 { recount(entry, count, now: Date()); return }
        if usesFile(hash) { return }
        note.child("contentFileList")?.children.removeAll { $0["id"] == hash }
        tree.child("contentFileList")?.children.removeAll { $0["id"] == hash }
        dropIfEmpty("contentFileList", in: note)
        dropIfEmpty("contentFileList", in: tree)
    }

    private func usesFile(_ hash: String) -> Bool {
        note.descendants("object").contains { $0["attachFile"] == hash || $0["thumbnailFile"] == hash || $0["thumbnailHash"] == hash || $0["thumbnail"] == hash || $0["originalImageId"] == hash || $0.child("fillEffect")?["imageId"] == hash }
            || note.descendants("voiceData").contains { $0["attachFile"] == hash }
            || note.descendants("pdfData").contains { $0["hash"] == hash }
            || note.descendants("customObject").contains { $0.descendants("pair").contains { $0["value"] == hash } }
            || (note.all("pageList").last?.all("page") ?? []).contains { page in page.int("bgImageId").map { boundFiles[$0] == hash } ?? false }
    }

    /// Where a picture goes.
    public enum Placement: Sendable {
        /// In the text, as a paragraph of its own at the end: what the Windows client does with a pasted picture.
        case inText
        /// Free on a page, at a rectangle in the page's own units.
        case onPage(Int, CGRect)
    }

    /// The width of the text column and the scale from text units to page units.
    public var textColumn: (left: Double, top: Double, width: Double, scale: Double) {
        let width = Double(attributes.int("width") ?? pageSize(0).width)
        let scale = width / 360
        let left = (bodyObject?.double("leftMargin") ?? 16) * scale, right = (bodyObject?.double("rightMargin") ?? 16) * scale
        return (left, (bodyObject?.double("topMargin") ?? 10) * scale, max(width - left - right, 16), scale)
    }

    /// The size a picture of this many pixels is given when it is set in the text.
    public func fittedSize(_ pixels: CGSize, fillWidth: Bool = false) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: 100, height: 100) }
        let column = textColumn
        let page = pageSize(0)
        if fillWidth {
            let scale = min(column.width / pixels.width, (Double(page.height) - 2 * column.top) / pixels.height)
            return CGSize(width: pixels.width * scale, height: pixels.height * scale)
        }
        let tallest = Double(page.width) * 495 / 848
        let scale = min(column.width / pixels.width, tallest / pixels.height, 1)
        return CGSize(width: pixels.width * scale, height: pixels.height * scale)
    }

    /// Adds a picture whose file is `fileHash`. `top` is where the text column has got to, in
    /// the note's own units from the top of the first page, for a picture set in the text.
    /// Returns the new object's id.
    @discardableResult
    public func addImage(fileHash: String, fileExtension: String, size: CGSize, placement: Placement = .inText, top: Double? = nil, textOffset: Int? = nil, objectID: String? = nil, now: Date = Date()) -> String {
        let id = objectID ?? UUID().uuidString.lowercased()
        let stamp = Int64(now.timeIntervalSince1970 * 1_000_000)
        let time = String(stamp)
        addFile(hash: fileHash, name: "image_\(UUID().uuidString.lowercased()).\(fileExtension)", now: now.addingTimeInterval(-0.01))
        let page = pageSize(0)
        var rect: CGRect
        var pageIndex = 0
        var layout = "2"
        switch placement {
        case .inText:
            let column = textColumn
            var y = top ?? column.top
            if !y.isFinite { y = 0 }
            let stride = max(Double(page.height) + (attributes.double("pageVerticalPadding") ?? 0), 1)
            pageIndex = min(max(Int(min(max(y / stride, 0), 100_000)), 0), max(pageCount - 1, 0))
            y -= Double(pageIndex) * stride
            rect = CGRect(x: column.left, y: y, width: size.width, height: size.height)
        case .onPage(let index, let wanted):
            pageIndex = min(max(index, 0), max(pageCount - 1, 0))
            rect = wanted
            layout = "3"
        }
        rect = CGRect(x: Double(Float(rect.minX)), y: Double(Float(rect.minY)), width: Double(Float(rect.maxX)) - Double(Float(rect.minX)), height: Double(Float(rect.maxY)) - Double(Float(rect.minY)))
        let hash = NoteHash.object(id: id, time: time)
        let object = XMLNode(name: "object", attributes: [
            "type": "image", "id": id, "hash": hash, "formatVersion": "4000", "rotatable": "True", "selectable": "True", "movable": "True", "flippable": "True",
            "visible": "True", "isReplayable": "True", "clippable": "True", "isTemplateObject": "False", "timeStamp": "0", "resizable": "0", "haveBeenToAtt": "True",
            "lockState": "False", "createdTime": "0", "modifiedTime": time, "appendTime": String(stamp - 10_000), "ownerPageWidth": String(page.width), "ownerPageHeight": "0",
            "layoutType": layout, "removable": "True", "pageIndex": String(pageIndex), "isHorizontalFlipped": "False", "isVerticalFlipped": "False",
            "isHintTextVisible": "False", "isTextReadOnly": "False", "isTextEditable": "False", "isTransparency": "False", "shapeType": "4", "originalDegree": "0", "ellipsisType": "2",
        ])
        NoteFile.shape(object, rect: rect, imageID: fileHash, pageWidth: page.width)
        floatingList.children.append(object)
        treeFloatingList.children.append(XMLNode(name: "object", attributes: ["id": id, "t": time, "h": hash]))
        if case .inText = placement {
            var text = bodyText
            if let textOffset { text.insertObject(id: id, at: textOffset) } else { text.appendObject(id: id) }
            setBodyText(text, now: now)
        }
        attributes.attributes["lastEditedPageIndex"] = String(pageIndex)
        touch(now, content: true)
        return id
    }

    /// The geometry of a picture object: its rectangle, the points lines attach to, its outline and what fills it.
    static func shape(_ object: XMLNode, rect: CGRect, imageID: String?, pageWidth: Int) {
        func node(_ name: String, _ attributes: [String: String], _ children: [XMLNode] = []) -> XMLNode {
            let node = XMLNode(name: name, attributes: attributes)
            node.children = children
            return node
        }
        func corners(_ name: String) -> XMLNode { node(name, ["l": float(rect.minX), "t": float(rect.minY), "r": float(rect.maxX), "b": float(rect.maxY)]) }
        let fill = imageID ?? object.child("fillEffect")?["imageId"] ?? ""
        let nine = object.child("fillEffect")?["ninePatchWidth"] ?? String(pageWidth)
        object.children.removeAll { ["rect", "connectionPointList", "lineColorEffect", "lineStyleEffect", "originalRect", "path", "fillEffect"].contains($0.name) }
        object.children.append(contentsOf: [
            corners("rect"),
            node("connectionPointList", [:], [
                node("point", ["x": wide(rect.midX), "y": wide(rect.minY)]), node("point", ["x": wide(rect.maxX), "y": wide(rect.midY)]),
                node("point", ["x": wide(rect.midX), "y": wide(rect.maxY)]), node("point", ["x": wide(rect.minX), "y": wide(rect.midY)]),
            ]),
            node("lineColorEffect", ["colorType": "2", "gradientRotatable": "False", "solidColor": "-16777216", "gradientType": "0", "angle": "0"], [node("radialGradientPosition", ["x": "0", "y": "0"])]),
            node("lineStyleEffect", ["width": "0", "compoundType": "0", "dashType": "0", "capType": "0", "joinType": "0", "beginArrowType": "0", "beginArrowSize": "0", "endArrowType": "0", "endArrowSize": "0"]),
            corners("originalRect"),
            node("path", [:], [node("segmentList", [:], [
                node("segment", ["type": "1", "x": float(rect.minX), "y": float(rect.minY)]), node("segment", ["type": "2", "x": float(rect.maxX), "y": float(rect.minY)]),
                node("segment", ["type": "2", "x": float(rect.maxX), "y": float(rect.maxY)]), node("segment", ["type": "2", "x": float(rect.minX), "y": float(rect.maxY)]),
                node("segment", ["type": "6"]),
            ])]),
            node("fillEffect", ["type": "image", "imageType": "0", "imageId": fill, "tilingScaleX": "100", "tilingScaleY": "100", "transparency": "0", "rotatable": "False", "ninePatchWidth": nine], [
                node("stretchOffset", ["l": "0", "t": "0", "r": "0", "b": "0"]), node("tilingOffset", ["x": "0", "y": "0"]), node("ninePatchRect", ["l": "0", "t": "0", "r": "0", "b": "0"]),
            ]),
        ])
    }

    func restampFloating(_ id: String, now: Date) -> XMLNode? { restamp(floating: id, now: now) }

    private func restamp(floating id: String, now: Date) -> XMLNode? {
        guard let object = note.child("floatingObjectList")?.all("object").first(where: { $0["id"] == id }) else { return nil }
        let time = NoteFile.micros(now)
        let hash = NoteHash.object(id: id, time: time)
        object.attributes["modifiedTime"] = time
        object.attributes["hash"] = hash
        if let entry = tree.child("floatingObjectList")?.all("object").first(where: { $0["id"] == id }) {
            entry.attributes["t"] = time
            entry.attributes["h"] = hash
        }
        return object
    }

    /// Moves or resizes a picture or another floating object. Only its coordinates change: its
    /// rectangle, the points and the outline that follow the rectangle. Everything else about it
    /// (how it is filled, its line, what another device set) stays as it is.
    @discardableResult
    public func setFloatingRect(_ id: String, _ rect: CGRect, page: Int? = nil, now: Date = Date()) -> Bool {
        guard rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite, let object = restamp(floating: id, now: now) else { return false }
        if object["type"] == "tableNew" {
            // A table keeps its size and the places of all its cells in its record: moved, the
            // record is made anew. Its outline stays where the table was first made.
            guard var table = self.table(id) else { return false }
            table.move(to: rect.origin)
            if let page { table.pageIndex = page }
            table.modified = Int64(object["modifiedTime"] ?? "") ?? table.modified
            object.attributes["pageIndex"] = String(table.pageIndex)
            NoteFile.shapeTable(object, table)
            touch(now, content: true)
            return true
        }
        if let page { object.attributes["pageIndex"] = String(page) }
        let old = object.child("rect").map(NoteDocument.rect) ?? .zero
        func set(_ node: XMLNode) { node.attributes = ["l": NoteFile.float(rect.minX), "t": NoteFile.float(rect.minY), "r": NoteFile.float(rect.maxX), "b": NoteFile.float(rect.maxY)] }
        if let node = object.child("rect") { set(node) } else {
            let node = XMLNode(name: "rect", attributes: [:])
            set(node)
            object.children.insert(node, at: 0)
        }
        // The rectangle before any rotation follows when it was the same rectangle.
        if let original = object.child("originalRect"), NoteDocument.rect(original).equalTo(old) { set(original) }
        // Points given in the page's units move with the rectangle.
        func moved(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            let sx = old.width > 0 ? rect.width / old.width : 1, sy = old.height > 0 ? rect.height / old.height : 1
            return (rect.minX + (x - old.minX) * sx, rect.minY + (y - old.minY) * sy)
        }
        if old.width > 0, old.height > 0 {
            for point in object.child("connectionPointList")?.all("point") ?? [] {
                guard let x = point.double("x"), let y = point.double("y") else { continue }
                let to = moved(x, y)
                point.attributes["x"] = NoteFile.wide(to.x); point.attributes["y"] = NoteFile.wide(to.y)
            }
            for segment in object.child("path")?.child("segmentList")?.all("segment") ?? [] {
                guard let x = segment.double("x"), let y = segment.double("y") else { continue }
                let to = moved(x, y)
                segment.attributes["x"] = NoteFile.float(to.x); segment.attributes["y"] = NoteFile.float(to.y)
            }
            // The frame the whole of a cropped picture would have moves and grows with the part shown.
            if let whole = object.child("imageOriginalRect") {
                let cut = object.child("cropRect").map(NoteDocument.rect) ?? .zero
                if cut.width > 0, cut.height > 0, let pixels = object.child("fillEffect")?["imageId"].flatMap({ pixelSize?($0) }), pixels.width >= 1, pixels.height >= 1 {
                    // From the part's pixels, which never change: rounding does not add up over many moves.
                    let size = CGSize(width: rect.width * pixels.width / cut.width, height: rect.height * pixels.height / cut.height)
                    let frame = CGRect(x: rect.minX - cut.minX / pixels.width * size.width, y: rect.minY - cut.minY / pixels.height * size.height, width: size.width, height: size.height)
                    whole.attributes = NoteFile.outward("imageOriginalRect", frame).attributes
                } else {
                    // Without the file: scaled with the part shown, to the nearest whole unit.
                    let was = NoteDocument.rect(whole)
                    let corner = moved(was.minX, was.minY), far = moved(was.maxX, was.maxY)
                    whole.attributes = ["l": String(Int(corner.x.rounded())), "t": String(Int(corner.y.rounded())), "r": String(Int(far.x.rounded())), "b": String(Int(far.y.rounded()))]
                }
            }
        }
        touch(now, content: true)
        return true
    }

    /// Turns a picture or another floating object about its middle, by degrees clockwise. The
    /// Windows client's object writer names the attribute `rotationDegree`; an object that is
    /// not turned has none.
    @discardableResult
    public func setFloatingRotation(_ id: String, _ degrees: Double, now: Date = Date()) -> Bool {
        guard degrees.isFinite, let object = restamp(floating: id, now: now) else { return false }
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle <= -180 { angle += 360 }
        if abs(angle) < 0.01 { object.attributes["rotationDegree"] = nil } else { object.attributes["rotationDegree"] = NoteFile.float(angle) }
        touch(now, content: true)
        return true
    }

    /// Sets a picture into the text, at a place in it, or frees it from the text to lie on a
    /// page. `rect` and `page` say where it lies afterwards; a picture set in the text is then
    /// put where the text makes room for it.
    @discardableResult
    public func setFloatingAnchor(_ id: String, inText: Bool, rect: CGRect? = nil, page: Int? = nil, textOffset: Int? = nil, now: Date = Date()) -> Bool {
        // A note without a text has nowhere to set a picture in.
        guard let object = note.child("floatingObjectList")?.all("object").first(where: { $0["id"] == id }), (object["layoutType"] == "2") != inText, !inText || bodyObject != nil else { return false }
        object.attributes["layoutType"] = inText ? "2" : "3"
        var text = bodyText
        if inText {
            if !text.objectIDs.contains(id) {
                if let textOffset { text.insertObject(id: id, at: textOffset) } else { text.appendObject(id: id) }
                setBodyText(text, now: now)
            }
        } else if text.removeObjects([id]) {
            setBodyText(text, now: now)
        }
        if let rect, setFloatingRect(id, rect, page: page, now: now) { return true }
        _ = restamp(floating: id, now: now)
        touch(now, content: true)
        return true
    }

    /// Takes pictures and other floating objects out of the note, with their places in the text
    /// and the files nothing else shows. Returns the ids that were there.
    @discardableResult
    public func removeFloating(_ ids: Set<String>, now: Date = Date()) -> Set<String> {
        var removed: Set<String> = []
        var files: [String] = []
        for object in note.child("floatingObjectList")?.all("object") ?? [] where ids.contains(object["id"] ?? "") {
            removed.insert(object["id"] ?? "")
            files.append(contentsOf: [object["attachFile"], object["thumbnailFile"], object["originalImageId"], object.child("fillEffect")?["imageId"]].compactMap { $0 })
        }
        for entry in tree.child("floatingObjectList")?.all("object") ?? [] where ids.contains(entry["id"] ?? "") { removed.insert(entry["id"] ?? "") }
        guard !removed.isEmpty else { return [] }
        note.child("floatingObjectList")?.children.removeAll { removed.contains($0["id"] ?? "") }
        tree.child("floatingObjectList")?.children.removeAll { removed.contains($0["id"] ?? "") }
        dropIfEmpty("floatingObjectList", in: note)
        dropIfEmpty("floatingObjectList", in: tree)
        for hash in files { releaseFile(hash) }
        var text = bodyText
        if text.removeObjects(removed) { setBodyText(text, now: now) }
        touch(now, content: true)
        return removed
    }

    /// How full the note is by the count Samsung's clients keep: a stroke counts one, anything
    /// else four. Past 100,000 they start packing strokes into groups, which this client does
    /// not write, so it stops a little short of that.
    public var objectWeight: Int {
        let objects = (note.all("pageList").last?.descendants("object") ?? []) + (note.child("floatingObjectList")?.all("object") ?? [])
        return objects.reduce(0) { $0 + ($1["type"] == "stroke" ? 1 : 4) }
    }
    public static let objectWeightLimit = 95_000

    // MARK: Pages

    private var fullPages: XMLNode? { note.all("pageList").last }

    private func resize(now: Date) {
        let pages = fullPages?.all("page") ?? []
        let gap = attributes.int("pageVerticalPadding") ?? 0
        let height = pages.reduce(0) { $0 + ($1.int("height") ?? 1200) } + max(pages.count - 1, 0) * gap
        attributes.attributes["height"] = String(height)
        touch(now, content: true)
    }

    /// Adds an empty page like the one before it. Returns its place.
    @discardableResult
    public func addPage(after index: Int? = nil, now: Date = Date()) -> Int? {
        // An endless note has its one page, which grows; it is not given a second.
        if isEndless { return nil }
        guard let full = fullPages, let treePages = tree.child("pageList") else { return nil }
        let pages = full.all("page")
        let at = min(max((index ?? pages.count - 1) + 1, 0), pages.count)
        // Like the page before it; a page put before the first, like the first.
        let model = pages[safe: at - 1] ?? pages.first
        let pageID = UUID().uuidString.lowercased(), layerID = UUID().uuidString.lowercased()
        let stamp = Int64(now.timeIntervalSince1970 * 1_000_000)
        let layerTime = String(stamp), pageTime = String(stamp + 30)
        let layerHash = NoteHash.container(id: layerID, time: layerTime, children: [])
        let pageHash = NoteHash.container(id: pageID, time: pageTime, children: [layerHash])
        var attributes = model?.attributes ?? [
            "isTextOnly": "False", "orientation": "0", "width": "848", "height": "1200", "offsetX": "0", "offsetY": "0", "formatVersion": "4000", "bgImageMode": "2",
            "bgColor": "-197380", "bgWidth": "848", "minFormatVersion": "4000", "editableFormatVersion": "4000", "createdTime": "0",
        ]
        attributes["id"] = pageID
        attributes["hash"] = pageHash
        attributes["modifiedTime"] = pageTime
        attributes["currentLayerIndex"] = "0"
        // The page of a PDF that lay under the page before stays that page's alone, and so does
        // that page's shape: the new page is one of the note's own.
        if attributes["templateType"] == "16" { attributes["templateType"] = nil }
        if model?.child("pdfDataList") != nil, let height = self.attributes.int("pageDefaultHeight") { attributes["height"] = String(height) }
        let page = XMLNode(name: "page", attributes: attributes)
        // A page's paper travels with it (its colour, its ruling, the picture under it); what is
        // drawn or stuck on it, and a PDF page under it, does not.
        let own = ["layerList", "drawnRect", "canvasCacheDataMap", "pdfDataList", "customObjectList", "strokeRecognitionList"]
        page.children = (model?.children ?? []).filter { !own.contains($0.name) && !$0.name.lowercased().contains("cache") }.map { $0.copy() }
        // The picture under it is now shown by one page more.
        if let shared = attributes["bgImageId"].flatMap({ Int($0) }).flatMap({ boundFiles[$0] }) { addFile(hash: shared, name: "template.png", now: now.addingTimeInterval(-0.01)) }
        let layers = XMLNode(name: "layerList", attributes: [:])
        layers.children = [XMLNode(name: "layer", attributes: ["id": layerID, "hash": layerHash, "flagEventForwardable": "True", "visible": "True", "lockState": "False", "layerNumber": "0",
                                                               "createdTime": "0", "modifiedTime": layerTime, "thumbnail": "-1"])]
        page.children.append(layers)
        let fullAt = at < pages.count ? (full.children.firstIndex { $0 === pages[at] } ?? full.children.count) : full.children.count
        full.children.insert(page, at: fullAt)
        let entry = XMLNode(name: "page", attributes: ["id": pageID, "t": pageTime, "h": pageHash])
        let entryLayers = XMLNode(name: "layerList", attributes: [:])
        entryLayers.children = [XMLNode(name: "layer", attributes: ["id": layerID, "t": layerTime, "h": layerHash])]
        entry.children = [entryLayers]
        let treeEntries = treePages.all("page")
        let treeAt = at < treeEntries.count ? (treePages.children.firstIndex { $0 === treeEntries[at] } ?? treePages.children.count) : treePages.children.count
        treePages.children.insert(entry, at: treeAt)
        for object in note.child("floatingObjectList")?.all("object") ?? [] where object["layoutType"] != "2" {
            // A picture whose page number changes is a changed object: it has to be sent again.
            if let place = object.int("pageIndex"), place >= at, let moved = restamp(floating: object["id"] ?? "", now: now) { moved.attributes["pageIndex"] = String(place + 1) }
        }
        resize(now: now)
        return at
    }

    /// Removes a page with what is drawn on it. The last page of a note stays. Returns the
    /// ids of the objects that went with it.
    @discardableResult
    public func removePage(_ index: Int, now: Date = Date()) -> Set<String>? {
        guard let full = fullPages, let treePages = tree.child("pageList") else { return nil }
        let pages = full.all("page")
        guard pages.count > 1, let page = pages[safe: index] else { return nil }
        var gone = Set(page.descendants("object").compactMap { $0["id"] })
        let paper = page.int("bgImageId").flatMap { boundFiles[$0] }
        let stuck = page.descendants("customObject").flatMap { $0.child("attachedFileList")?.all("pair") ?? [] }.compactMap { $0["value"] }
        let documents = page.descendants("pdfData").compactMap { $0["hash"] }
        full.children.removeAll { $0 === page }
        if let paper { releaseFile(paper) }
        // The PDF a page showed is the note's for as long as one of its pages shows it.
        for file in documents { releaseFile(file) }
        for file in stuck { releaseFile(file) }
        treePages.children.removeAll { $0["id"] == page["id"] }
        var floating: Set<String> = []
        for object in note.child("floatingObjectList")?.all("object") ?? [] where object["layoutType"] != "2" {
            guard let place = object.int("pageIndex") else { continue }
            if place == index { floating.insert(object["id"] ?? "") } else if place > index, let moved = restamp(floating: object["id"] ?? "", now: now) { moved.attributes["pageIndex"] = String(place - 1) }
        }
        gone.formUnion(removeFloating(floating, now: now))
        resize(now: now)
        return gone
    }

    /// Puts a page in another place among the pages.
    @discardableResult
    public func movePage(_ index: Int, to target: Int, now: Date = Date()) -> Bool {
        guard let full = fullPages, let treePages = tree.child("pageList") else { return false }
        let pages = full.all("page")
        guard pages.indices.contains(index), pages.indices.contains(target), index != target else { return false }
        func reorder(_ list: XMLNode, _ entries: [XMLNode]) {
            var order = entries
            order.insert(order.remove(at: index), at: target)
            var next = order.makeIterator()
            list.children = list.children.map { $0.name == "page" ? next.next()! : $0 }
        }
        reorder(full, pages)
        let ids = pages.map { $0["id"] ?? "" }
        let entries = treePages.all("page").sorted { (ids.firstIndex(of: $0["id"] ?? "") ?? 0) < (ids.firstIndex(of: $1["id"] ?? "") ?? 0) }
        if entries.count == pages.count { reorder(treePages, entries) }
        for object in note.child("floatingObjectList")?.all("object") ?? [] where object["layoutType"] != "2" {
            guard let place = object.int("pageIndex") else { continue }
            var order = Array(pages.indices)
            order.insert(order.remove(at: index), at: target)
            if let new = order.firstIndex(of: place), new != place, let moved = restamp(floating: object["id"] ?? "", now: now) { moved.attributes["pageIndex"] = String(new) }
        }
        touch(now, content: true)
        return true
    }

    // MARK: Pages of a PDF

    /// The size a page of a PDF is given as a page of the note: as wide as the note's pages,
    /// and as high as keeps the PDF page's shape (the Windows client drops the fraction).
    public func pdfPageSize(_ size: CGSize) -> (width: Int, height: Int) {
        let width = attributes.int("pageDefaultWidth") ?? attributes.int("width") ?? 848
        let shape = size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite ? Double(size.height / size.width) : 1.414
        return (width, Int(min(max(shape, 0.1), 10) * Double(width)))
    }

    /// Makes pages of the pages of a PDF, as Samsung's clients import one: each a page of the
    /// PDF's shape that names the document (a file of the note, `hash`) and its page in it,
    /// which is shown under whatever is written on the page. `sizes` are the PDF's pages as
    /// they are shown, the first of them `firstPage` in the document (from 0); `place` is
    /// where among the note's pages they go (at the end without it). Returns their places.
    @discardableResult
    public func addPDFPages(hash: String, fileName: String, sizes: [CGSize], firstPage: Int = 0, at place: Int? = nil, now: Date = Date()) -> Range<Int>? {
        // An endless note has one page, which is not a page of anything.
        guard !isEndless, !sizes.isEmpty, let full = fullPages, let treePages = tree.child("pageList") else { return nil }
        let pages = full.all("page")
        let at = min(max(place ?? pages.count, 0), pages.count)
        let stamp = Int64(now.timeIntervalSince1970 * 1_000_000)
        var basis = [
            "isTextOnly": "False", "orientation": "0", "offsetX": "0", "offsetY": "0", "formatVersion": "4000", "bgImageMode": "2",
            "minFormatVersion": "4000", "editableFormatVersion": "4000", "createdTime": "0",
        ]
        // What a page says of the format it is written in is as the note's other pages say it.
        for key in ["formatVersion", "minFormatVersion", "editableFormatVersion", "orientation"] { if let value = pages.first?[key] { basis[key] = value } }
        var made: [XMLNode] = [], entries: [XMLNode] = []
        for (index, size) in sizes.enumerated() {
            let (width, height) = pdfPageSize(size)
            let pageID = UUID().uuidString.lowercased(), layerID = UUID().uuidString.lowercased()
            let layerTime = String(stamp + Int64(index) * 100), pageTime = String(stamp + Int64(index) * 100 + 30)
            let layerHash = NoteHash.container(id: layerID, time: layerTime, children: [])
            let pageHash = NoteHash.container(id: pageID, time: pageTime, children: [layerHash])
            var attributes = basis
            attributes["id"] = pageID
            attributes["hash"] = pageHash
            attributes["width"] = String(width)
            attributes["height"] = String(height)
            attributes["bgWidth"] = String(width)
            attributes["bgColor"] = "-197380"
            attributes["currentLayerIndex"] = "0"
            attributes["modifiedTime"] = pageTime
            let page = XMLNode(name: "page", attributes: attributes)
            let data = XMLNode(name: "pdfData", attributes: ["pageIndex": String(firstPage + index), "hash": hash])
            // The whole of the page, in whole numbers: the form every client reads.
            data.children = [XMLNode(name: "pdfRect", attributes: ["l": "0", "t": "0", "r": String(width), "b": String(height)])]
            let list = XMLNode(name: "pdfDataList", attributes: [:])
            list.children = [data]
            let layers = XMLNode(name: "layerList", attributes: [:])
            layers.children = [XMLNode(name: "layer", attributes: ["id": layerID, "hash": layerHash, "flagEventForwardable": "True", "visible": "True", "lockState": "False", "layerNumber": "0",
                                                                   "createdTime": "0", "modifiedTime": layerTime, "thumbnail": "-1"])]
            page.children = [list, layers]
            made.append(page)
            let entry = XMLNode(name: "page", attributes: ["id": pageID, "t": pageTime, "h": pageHash])
            let entryLayers = XMLNode(name: "layerList", attributes: [:])
            entryLayers.children = [XMLNode(name: "layer", attributes: ["id": layerID, "t": layerTime, "h": layerHash])]
            entry.children = [entryLayers]
            entries.append(entry)
            // The document is held once for every page that shows it.
            addFile(hash: hash, name: fileName, now: now.addingTimeInterval(-0.01))
        }
        let fullAt = at < pages.count ? (full.children.firstIndex { $0 === pages[at] } ?? full.children.count) : full.children.count
        full.children.insert(contentsOf: made, at: fullAt)
        let treeEntries = treePages.all("page")
        let treeAt = at < treeEntries.count ? (treePages.children.firstIndex { $0 === treeEntries[at] } ?? treePages.children.count) : treePages.children.count
        treePages.children.insert(contentsOf: entries, at: treeAt)
        for object in note.child("floatingObjectList")?.all("object") ?? [] where object["layoutType"] != "2" {
            if let place = object.int("pageIndex"), place >= at, let moved = restamp(floating: object["id"] ?? "", now: now) { moved.attributes["pageIndex"] = String(place + sizes.count) }
        }
        resize(now: now)
        return at..<(at + sizes.count)
    }

    /// The colour of a page's paper, as 0xAARRGGBB.
    public func setPageColor(_ index: Int, _ argb: UInt32, now: Date = Date()) { setPaper(.color(argb), page: index, now: now) }
}

extension NoteHash {
    /// The hash of a file's entry, as the Windows client makes it: SHA-256 of the file's hash,
    /// its number, its name with the number in front, its count of references, its time and
    /// "True", written one after the other. (The phone ends with "true"; entries it wrote are
    /// passed on as they came, never made again.)
    public static func contentFile(id: String, bindNumber: Int, name: String, refCount: Int, time: String) -> String {
        hex(digest(Data("\(id)\(bindNumber)\(name)\(refCount)\(time)True".utf8)))
    }
}

extension NoteText {
    /// Takes the placeholders of these objects out of the text. True when something went.
    public mutating func removeObjects(_ ids: Set<String>) -> Bool {
        var changed = false
        for span in spans.filter({ $0.key == NoteText.objectKey }).sorted(by: { $0.start > $1.start }) {
            guard let id = span.value.split(separator: ",").first.map(String.init), ids.contains(id) else { continue }
            // The picture's paragraph goes with it when it stood alone.
            var from = span.start, to = span.end
            let units = Array(string.utf16)
            if from > 0, units[from - 1] == 0x0A, to == units.count || units[to] == 0x0A { from -= 1 }
            else if from == 0, to < units.count, units[to] == 0x0A { to += 1 }
            replace(from..<to, with: "")
            changed = true
        }
        return changed
    }

    /// Replaces a stretch of the text (UTF-16 offsets). What is typed takes the attributes of
    /// the character before it; paragraphs follow the line breaks.
    public mutating func replace(_ range: Range<Int>, with new: String) {
        let units = Array(string.utf16)
        let lower = min(max(range.lowerBound, 0), units.count), upper = min(max(range.upperBound, lower), units.count)
        let added = Array(new.utf16)
        let delta = added.count - (upper - lower)
        // Paragraphs: the line breaks in what goes take their paragraphs with them, those in
        // what comes start new ones like the paragraph they are typed in.
        var attributes = paragraphs
        let count = units.filter { $0 == 0x0A }.count + 1
        while attributes.count < count { attributes.append(attributes.isEmpty ? NoteText.firstParagraph : NoteText.laterParagraph) }
        let before = units[..<lower].filter { $0 == 0x0A }.count
        let inside = units[lower..<upper].filter { $0 == 0x0A }.count
        let coming = added.filter { $0 == 0x0A }.count
        if !units.isEmpty || !paragraphs.isEmpty {
            attributes.removeSubrange((before + 1)..<(before + 1 + inside))
            // A new line in a checklist starts unticked.
            let fresh = attributes[before].map { $0.key == NoteText.bullet && $0.value.hasPrefix("2,") ? Attribute($0.key, "2,False") : $0 }
            // Only the first paragraph says it is aligned to the left; any other alignment carries on.
            let later = fresh.filter { $0.key != "paragraph/alignment" || $0.value != "0" }
            attributes.insert(contentsOf: Array(repeating: later.isEmpty ? NoteText.laterParagraph : later, count: coming), at: before + 1)
            paragraphs = attributes
        } else {
            paragraphs = (0...coming).map { $0 == 0 ? NoteText.firstParagraph : NoteText.laterParagraph }
        }
        var out: [Span] = []
        // Text typed between two runs of one kind goes to the one before it.
        let continued = Set(spans.filter { $0.end == lower && $0.growsAtEnd && $0.start < $0.end && upper == lower && !added.isEmpty }.map(\.key))
        for var span in spans {
            let object = span.key == NoteText.objectKey
            if span.end <= lower {
                // Text typed right after a run continues it, when the run is one that grows at its end.
                if span.end == lower, continued.contains(span.key), span.growsAtEnd, span.start < span.end { span.end += added.count }
            } else if span.start >= upper {
                // Text typed right before a run joins it only when the run grows at its start and no run before it took the text.
                if span.start == lower, upper == lower, span.growsAtStart, !added.isEmpty, !continued.contains(span.key) { span.end += delta } else { span.start += delta; span.end += delta }
            } else if span.start <= lower && !object {
                // Covers the first character replaced: what is typed there is in this run's style.
                span.end = span.end >= upper ? span.end + delta : lower + added.count
            } else if span.end > upper {
                // Starts inside what was replaced and goes on after it: it begins after the new text now.
                span.start = lower + added.count
                span.end += delta
            } else if object, span.start < lower {
                span.end = lower
            } else {
                // Lay wholly inside what was replaced.
                continue
            }
            if span.end > span.start { out.append(span) }
        }
        // Spans of one kind that now cover the same stretch are one span.
        var merged: [Span] = []
        for span in out {
            if let twin = merged.firstIndex(where: { $0.key == span.key && $0.start == span.start && $0.end == span.end && $0.key != NoteText.objectKey }) { merged[twin] = span } else { merged.append(span) }
        }
        spans = merged
        tidySpans()
        zeroLength = []
        string = String(decoding: units[..<lower] + added + units[upper...], as: UTF16.self)
        if string.isEmpty { spans = []; paragraphs = [] }
    }
}
