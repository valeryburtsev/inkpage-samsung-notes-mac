import CoreGraphics
import Foundation

/// One thing on a page: a stroke, an image, a painting, a text box, a shape.
public struct NoteObject: Sendable, Identifiable {
    public enum Kind: String, Sendable { case stroke, image, painting, textBox, shape, line, voice, sticky, table, other }
    public var id: String
    public var kind: Kind
    public var rawType: String
    public var rect: CGRect
    public var rotation: Double
    public var pageIndex: Int?
    /// Content hash of the picture an image shows.
    public var imageID: String?
    /// Content hashes of a painting's document and of its picture.
    public var attachFile: String?
    public var thumbnailFile: String?
    public var text: RichText?
    public var margins: (left: Double, top: Double, right: Double, bottom: Double) = (0, 0, 0, 0)
    /// A text box that grows downwards with what is written in it; false once it was given a size by hand.
    public var growsWithText = false
    /// "2" for a picture that sits in the text, "3" for one placed freely on a page.
    public var layoutType: String?
    /// True for an object that has a place in the note's text though its layout does not say
    /// so: a table lies freely by its layout and is yet set in the text by a place of its own.
    public var anchored = false
    /// Set in the text: the text makes room for it, and it lies where the text puts it.
    public var inText: Bool { layoutType == "2" || anchored }
    /// A table, read from its record; and whether this client can write that record again to
    /// the last byte, which is its leave to change the table.
    public var table: SamsungTable?
    public var tableIsExact = false

    /// The part of the picture's file that is shown, in fractions of the whole picture from its
    /// top left corner; nil when all of it is. The file itself is never cut: cropping again
    /// starts from the whole picture.
    public var crop: CGRect?
    /// The same part as the clients keep it: in pixels of the picture's file.
    public var cropPixels: CGRect?
    /// The file of the picture as it was before it was cut out along a loop: the file shown is
    /// then a copy of it that is clear outside the loop.
    public var originalImageID: String?
    /// A loop the picture is cut out along, in fractions of the shown part; nil for none. Only
    /// for showing a cut that is being stored: a note keeps a cut as a file of its own.
    public var outline: [CGPoint]?
    /// The colour of a sticky note's paper.
    public var paper: UInt32?
    /// What a sticky note says, read from its own file when the note is loaded from the store;
    /// and whether this client can write that file again as it is, which is its leave to change it.
    public var sticky: StickyDocument?
    public var stickyIsExact = false
    public var isCropped: Bool { crop != nil || outline != nil }
    /// The file of the picture this object shows: an image's own, a painting's picture of itself.
    public var pictureFile: String? { kind == .painting ? thumbnailFile ?? imageID : imageID ?? thumbnailFile }

    /// The picture as this object shows it: the cropped part of `image`, cut out along the loop.
    public func shown(_ image: CGImage) -> CGImage? {
        var out = image
        if let crop {
            let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let part = CGRect(x: crop.minX * whole.width, y: crop.minY * whole.height, width: crop.width * whole.width, height: crop.height * whole.height).integral.intersection(whole)
            guard part.width >= 1, part.height >= 1, let cut = image.cropping(to: part) else { return image }
            out = cut
        }
        guard let outline, outline.count > 2 else { return out }
        let width = out.width, height = out.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return out }
        // The loop's y points down, the bitmap's up.
        let path = CGMutablePath()
        path.addLines(between: outline.map { CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height)) })
        path.closeSubpath()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(out, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? out
    }

    /// The room a rectangle takes when it is turned by an angle in degrees: its bounding box.
    public static func turned(_ size: CGSize, by degrees: Double) -> CGSize {
        guard degrees.isFinite, degrees != 0 else { return size }
        let angle = degrees * .pi / 180
        return CGSize(width: abs(size.width * cos(angle)) + abs(size.height * sin(angle)), height: abs(size.width * sin(angle)) + abs(size.height * cos(angle)))
    }

    /// The room this object takes, turned as it is.
    public var turnedSize: CGSize { NoteObject.turned(rect.size, by: rotation) }

    public init(id: String, kind: Kind, rawType: String? = nil, rect: CGRect, rotation: Double = 0, pageIndex: Int? = nil) {
        self.id = id; self.kind = kind; self.rawType = rawType ?? kind.rawValue; self.rect = rect; self.rotation = rotation; self.pageIndex = pageIndex
    }
}

public struct NotePage: Sendable, Identifiable {
    public var id: String
    public var width: Double
    public var height: Double
    public var background: UInt32
    public var objects: [NoteObject]
    public var drawnRect: CGRect?
    /// True when the page is a bare page: only the attributes and parts a new page has, and
    /// layers with nothing in them. Anything else on it (a template, a PDF page, a cached
    /// picture, a layer set to hidden, attributes this client does not know) makes it not bare.
    public var isBare = false
    /// The attributes that give a page its look. A spare page looks like the page before it.
    public var look = ""
    /// The same without the page's height.
    public var lookButHeight = ""
    /// The paper's ruling, when the page has one of the built-in ones.
    public var template: PageTemplate?
    /// The file of a picture that lies under the page as its paper.
    public var backgroundImage: String?
    /// The page of a PDF document that is this page's paper: the document's file and the
    /// page's number in it, from 0.
    public var pdf: (file: String, page: Int)?
}

public struct ContentFile: Sendable, Identifiable {
    public var id: String              // SHA-256 of the bytes
    public var name: String?
}

/// A note as the sync service describes it, parsed from its XML.
public struct NoteDocument: Sendable {
    public var id: String
    public var createdMicros: Int64
    public var syncModifiedTime: Int64
    public var isLocked: Bool
    public var isEncrypted: Bool
    public var attributes: [String: String]
    public var title: RichText
    public var body: RichText
    public var bodyMargins: (left: Double, top: Double, right: Double, bottom: Double)
    public var pages: [NotePage]
    public var floating: [NoteObject]
    public var files: [ContentFile]
    /// Voice recordings and sound files kept with the note.
    public var recordings: [NoteRecording] = []
    public var penNames: [Int: String]
    public var commitID: String?
    public var downloadURLs: [String: String]

    public var width: Double { attributes["width"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? pages.first?.width ?? 1080 }
    public var pageHeight: Double { pages.first?.height ?? attributes["pageDefaultHeight"].flatMap(Double.init) ?? width * 1.414 }
    public var pageGap: Double { attributes["pageVerticalPadding"].flatMap(Double.init) ?? 0 }
    /// Page units per text unit. Text is set as on a page 360 units wide, whatever the page
    /// measures in the writing device's pixels: a picture set in the text by the Windows client
    /// starts at the text's 16-unit margin times exactly this ratio (37.689 on its 848-wide page).
    /// (For a note laid out lying on its side, it is the page's height that is 360 units.)
    public var density: Double {
        let side = orientation == 0 ? width : (attributes["pageDefaultHeight"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? width)
        return min(max(side / 360, 0.5), 12)
    }
    /// 0 for pages that stand upright; another number for a note laid out lying on its side.
    public var orientation: Int { attributes["orientation"].flatMap(Int.init) ?? 0 }
    /// True for a note of one page that grows as it is written on ("infinite scroll"); false
    /// for a note of separate pages.
    public var isEndless: Bool { attributes["pageMode"] == "1" }
    public var displayModified: Date? { attributes["displayModifiedTime"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } }
    public var displayCreated: Date? { attributes["displayCreatedTime"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } }
    public var isFavorite: Bool { attributes["isFavorite"]?.lowercased() == "true" }
    public var allObjects: [NoteObject] { pages.flatMap(\.objects) + floating }
    public var hasInk: Bool { allObjects.contains { $0.kind == .stroke || $0.kind == .painting } }
    public var firstImage: String? { allObjects.first { $0.kind == .image }?.imageID ?? allObjects.first { $0.kind == .painting }?.thumbnailFile }

    public enum Failure: Error { case noNote }

    /// Accepts the service's `CompareNoteView` and the client's own `NoteResource`.
    public init(xml data: Data) throws {
        let root = try XMLTree.parse(data)
        guard let note = root.name.lowercased() == "noteresource" ? root : (root.child("noteResource") ?? root.descendant("NoteResource")) else { throw Failure.noNote }
        id = note["id"] ?? ""
        createdMicros = note["createdTime"].flatMap(Int64.init) ?? 0
        syncModifiedTime = note["syncModifiedTime"].flatMap(Int64.init) ?? 0
        isLocked = note.bool("isLocked")
        isEncrypted = note.bool("isEncrypted")
        let attributeNode = note.child("attributes")
        attributes = attributeNode?.attributes ?? [:]
        func textObject(_ holder: XMLNode?) -> XMLNode? { holder?.child("object") }
        let titleObject = textObject(attributeNode?.child("title"))
        title = RichText(encoded: titleObject?.value("text") ?? "")
        // The skeleton in noteTree also has a bodyText element; the one with the object is a direct child.
        let bodyObject = note.all("bodyText").compactMap { $0.child("object") }.first
        body = RichText(encoded: bodyObject?.value("text") ?? "")
        bodyMargins = (bodyObject?.double("leftMargin") ?? 16, bodyObject?.double("topMargin") ?? 10, bodyObject?.double("rightMargin") ?? 16, bodyObject?.double("bottomMargin") ?? 10)
        var names: [Int: String] = [:]
        for entry in attributeNode?.child("stringIdList")?.all("stringId") ?? [] {
            if let index = entry.int("id"), let text = entry["text"]?.decodedBase64 { names[index] = text }
        }
        penNames = names
        // A page names the picture under it by the number its file is bound under.
        var bound: [Int: String] = [:]
        for entry in note.all("contentFileList").flatMap({ $0.all("contentFile") }) {
            guard let hash = entry["id"] else { continue }
            let named = entry["name"]?.decodedBase64.flatMap { $0.split(separator: "@", maxSplits: 1).first.flatMap { Int($0) } }
            if let number = entry.int("bindNumber") ?? named { bound[number] = hash }
        }
        recordings = (attributeNode?.child("voiceDataList")?.all("voiceData") ?? []).enumerated().map { index, entry in
            // Its length in milliseconds; from older writers only as text. Kept to what a length can be.
            let length = entry.double("recordingTime").map { $0 / 1000 } ?? NoteFile.seconds(playTime: entry["playTime"]?.decodedBase64 ?? "")
            return NoteRecording(id: "\(index):\(entry["attachFile"] ?? "")", title: entry["name"]?.decodedBase64 ?? "", file: entry["attachFile"],
                                 seconds: length.isFinite ? min(max(length, 0), 1_000_000) : 0)
        }
        pages = (note.all("pageList").last?.all("page") ?? []).map { page in
            var parsed = NotePage(id: page["id"] ?? "", width: page.double("width") ?? 1080, height: page.double("height") ?? 1527,
                                  background: page["bgColor"].flatMap { Int32($0) }.map { UInt32(bitPattern: $0) } ?? 0xFFFC_FCFC,
                                  objects: page.child("layerList")?.all("layer").flatMap { $0.child("objectList")?.all("object") ?? [] }.map(NoteDocument.object) ?? [],
                                  drawnRect: page.child("drawnRect").map(NoteDocument.rect))
            parsed.isBare = NoteDocument.isBare(page)
            let looks = ["bgColor", "bgImageMode", "bgWidth", "width", "height", "orientation", "offsetX", "offsetY", "templateType", "bgImageId", "bgRotation"]
            parsed.look = looks.map { page[$0] ?? "-" }.joined(separator: "|")
            parsed.lookButHeight = looks.filter { $0 != "height" }.map { page[$0] ?? "-" }.joined(separator: "|")
            let kind = page.int("templateType") ?? 0
            parsed.template = PageTemplate(code: kind)
            if let number = page.int("bgImageId"), number >= 0 { parsed.backgroundImage = bound[number] }
            if let data = page.child("pdfDataList")?.child("pdfData"), let hash = data["hash"], !hash.isEmpty { parsed.pdf = (hash, max(data.int("pageIndex") ?? 0, 0)) }
            // Sticky notes are kept beside the page's layers, each with a picture of itself.
            for custom in page.child("customObjectList")?.all("customObject") ?? [] where custom["type"] == "1" {
                var sticky = NoteObject(id: custom["id"] ?? UUID().uuidString, kind: .sticky, rawType: "stickyNote", rect: custom.child("rect").map(NoteDocument.rect) ?? .zero)
                func pairs(_ list: String) -> [String: String] {
                    var out: [String: String] = [:]
                    for pair in custom.child(list)?.all("pair") ?? [] { if let key = pair["key"]?.decodedBase64, let value = pair["value"] { out[key] = value } }
                    return out
                }
                sticky.thumbnailFile = pairs("attachedFileList")["co_thumbnail_path"]
                sticky.attachFile = pairs("attachedFileList")["co_attach_file"]
                sticky.paper = pairs("customDataList")["skn_bg_color"]?.decodedBase64.flatMap { Int32($0) }.map { UInt32(bitPattern: $0) }
                parsed.objects.append(sticky)
            }
            return parsed
        }
        floating = (note.child("floatingObjectList")?.all("object") ?? []).map(NoteDocument.object)
        // A table is set in the text by its place there.
        let placed = Set(body.runs.compactMap(\.objectID))
        for index in floating.indices where floating[index].kind == .table && placed.contains(floating[index].id) { floating[index].anchored = true }
        files = (note.all("contentFileList").flatMap { $0.all("contentFile") }).reduce(into: [ContentFile]()) { list, node in
            guard let hash = node["id"], !list.contains(where: { $0.id == hash }) || node["name"] != nil else { return }
            list.removeAll { $0.id == hash }
            list.append(ContentFile(id: hash, name: node["name"]?.decodedBase64))
        }
        commitID = root.value("commitId")
        var urls: [String: String] = [:]
        for entry in root.child("downloadUrls")?.all("downloadUrl") ?? [] {
            if let hash = entry.value("id"), let url = entry.value("url") { urls[hash] = url }
        }
        downloadURLs = urls
    }

    /// What every page the clients have been seen to write has, and nothing more.
    private static let bareAttributes: Set<String> = [
        "id", "hash", "isTextOnly", "orientation", "width", "height", "offsetX", "offsetY", "formatVersion", "bgImageMode", "bgColor", "bgWidth",
        "minFormatVersion", "editableFormatVersion", "currentLayerIndex", "createdTime", "modifiedTime",
        // A ruling or a picture under the page is paper, not content: a spare page has the
        // paper of the page before it, which `look` compares.
        "templateType", "templateUri", "bgImageId", "bgRotation",
    ]
    private static let bareLayerAttributes: Set<String> = [
        "id", "hash", "flagEventForwardable", "visible", "lockState", "layerNumber", "createdTime", "modifiedTime", "thumbnail",
    ]

    static func isBare(_ page: XMLNode) -> Bool {
        guard Set(page.attributes.keys).isSubset(of: bareAttributes), page.children.allSatisfy({ $0.name == "layerList" }) else { return false }
        return (page.child("layerList")?.all("layer") ?? []).allSatisfy { layer in
            Set(layer.attributes.keys).isSubset(of: bareLayerAttributes)
                && layer["visible"]?.lowercased() != "false" && layer["lockState"]?.lowercased() != "true"
                && (layer["thumbnail"] ?? "-1") == "-1"
                && layer.children.allSatisfy { $0.name == "objectList" && $0.children.isEmpty }
        }
    }

    static func rect(_ node: XMLNode) -> CGRect {
        // Numbers from a note are kept finite and within reason, so that no arithmetic on them can trap.
        func sane(_ name: String) -> Double { (node.double(name)).flatMap { $0.isFinite ? min(max($0, -10_000_000), 10_000_000) : nil } ?? 0 }
        let l = sane("l"), t = sane("t"), r = sane("r"), b = sane("b")
        return CGRect(x: l, y: t, width: r - l, height: b - t)
    }

    static func object(_ node: XMLNode) -> NoteObject {
        let type = node["type"] ?? ""
        var object = NoteObject(id: node["id"] ?? "", kind: NoteObject.Kind(rawValue: type) ?? .other, rawType: type,
                                rect: node.child("rect").map(rect) ?? .zero, rotation: node.double("rotationDegree") ?? 0, pageIndex: node.int("pageIndex"))
        if let fill = node.child("fillEffect"), fill["type"] == "image" { object.imageID = fill["imageId"]; if object.kind == .other || object.kind == .shape { object.kind = .image } }
        object.layoutType = node["layoutType"]
        object.attachFile = node["attachFile"]
        object.thumbnailFile = node["thumbnailFile"] ?? node["thumbnailHash"] ?? node["thumbnail"]
        object.originalImageID = node["originalImageId"]
        if type == "tableNew" {
            object.kind = .table
            if let record = node.value("tableBinary").flatMap({ Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }), let table = SamsungTable(binary: record) {
                object.table = table
                object.tableIsExact = table.binary == record
            }
        }
        // A cropped picture: the part shown in pixels of its file, and the frame the whole
        // picture would have. Their relation gives the part in fractions of the whole.
        if let cut = node.child("cropRect").map(rect), cut.width > 0, cut.height > 0 {
            object.cropPixels = cut
            let whole = node.child(type == "painting" ? "originalRect" : "imageOriginalRect").map(rect) ?? .zero
            if whole.width > 0, whole.height > 0, object.rect.width > 0, object.rect.height > 0 {
                let part = CGRect(x: (object.rect.minX - whole.minX) / whole.width, y: (object.rect.minY - whole.minY) / whole.height, width: object.rect.width / whole.width, height: object.rect.height / whole.height)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if !part.isNull, part.width > 0.001, part.height > 0.001, part.width < 0.9995 || part.height < 0.9995 { object.crop = part }
            }
        }
        if let text = node.value("text"), !text.isEmpty { object.text = RichText(encoded: text) }
        object.margins = (node.double("leftMargin") ?? 0, node.double("topMargin") ?? 0, node.double("rightMargin") ?? 0, node.double("bottomMargin") ?? 0)
        object.growsWithText = node["textAutoFit"] == "2"
        return object
    }
}
