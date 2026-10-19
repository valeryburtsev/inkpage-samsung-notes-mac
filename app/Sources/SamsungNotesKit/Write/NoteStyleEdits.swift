import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A recording kept with a note.
public struct NoteRecording: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    /// The content hash of its sound file.
    public var file: String?
    public var seconds: Double
}

extension PageTemplate {
    /// The number the clients keep a page's ruling under (`templateType`). 12 is a picture of
    /// one's own under the page and 16 a PDF page; neither is a ruling.
    public var code: Int {
        switch self {
        case .blank: return 0
        case .lineNarrow: return 1
        case .lineMedium: return 2
        case .lineWide: return 3
        case .gridNarrow: return 4
        case .gridMedium: return 5
        case .gridWide: return 6
        case .dotNarrow: return 7
        case .dotMedium: return 8
        case .dotWide: return 9
        case .todo: return 10
        case .oxford: return 11
        case .weekly: return 13
        case .monthly: return 14
        case .manuscript: return 15
        }
    }

    public init?(code: Int) {
        guard code != 0, let found = PageTemplate.allCases.first(where: { $0.code == code }) else { return nil }
        self = found
    }

    static let ownPicture = 12
}

extension NoteFile {
    // MARK: Cropping

    /// Shows a part of a picture, or all of it again. As the clients keep it: `rect` is the part
    /// shown, `cropRect` that part in pixels of the picture's file (left, top, right, bottom),
    /// and `imageOriginalRect` the frame the whole picture would have on the page, in whole
    /// units. The file itself is not changed.
    ///
    /// `crop` is the part in fractions of the whole picture, nil for all of it; `pixels` the
    /// size of the picture's file.
    @discardableResult
    public func setFloatingCrop(_ id: String, crop: CGRect?, pixels: CGSize, rect: CGRect, page: Int? = nil, now: Date = Date()) -> Bool {
        guard setFloatingRect(id, rect, page: page, now: now), let object = note.child("floatingObjectList")?.all("object").first(where: { $0["id"] == id }) else { return false }
        object.children.removeAll { $0.name == "cropRect" || $0.name == "imageOriginalRect" }
        guard let crop, crop.width > 0, crop.height > 0, pixels.width >= 1, pixels.height >= 1 else { return true }
        // Down to a whole pixel for the corner and up for the size, as the clients do; a hair's
        // breadth is allowed for, so that a part read from whole pixels goes back to the same ones.
        let slack = 0.0001
        let left = min(max(Int(crop.minX * pixels.width + slack), 0), Int(pixels.width) - 1), top = min(max(Int(crop.minY * pixels.height + slack), 0), Int(pixels.height) - 1)
        let right = min(left + max(Int((crop.width * pixels.width - slack).rounded(.up)), 1), Int(pixels.width)), bottom = min(top + max(Int((crop.height * pixels.height - slack).rounded(.up)), 1), Int(pixels.height))
        let size = CGSize(width: rect.width / crop.width, height: rect.height / crop.height)
        let whole = CGRect(x: rect.minX - crop.minX * size.width, y: rect.minY - crop.minY * size.height, width: size.width, height: size.height)
        let cut = XMLNode(name: "cropRect", attributes: ["l": String(left), "t": String(top), "r": String(right), "b": String(bottom)])
        // After the shape's own parts, and before the whole picture's frame, as the clients write them.
        let after = object.children.lastIndex { ["fillEffect", "path", "originalRect", "rect"].contains($0.name) }.map { $0 + 1 } ?? object.children.count
        object.children.insert(cut, at: after)
        object.children.append(NoteFile.outward("imageOriginalRect", whole))
        return true
    }

    /// A rectangle in whole units that holds `rect`.
    static func outward(_ name: String, _ rect: CGRect) -> XMLNode {
        // Numbers from a note are not to be trusted to be numbers one can count with.
        func whole(_ value: Double) -> String { String(Int(value.isFinite ? min(max(value, -1_000_000_000), 1_000_000_000) : 0)) }
        return XMLNode(name: name, attributes: ["l": whole(rect.minX.rounded(.down)), "t": whole(rect.minY.rounded(.down)), "r": whole(rect.maxX.rounded(.up)), "b": whole(rect.maxY.rounded(.up))])
    }

    /// Gives a picture object another file to show. `original` names the file it was made from
    /// (a picture cut out along a loop keeps the picture it was cut from), or nil when the file
    /// shown is the picture as it came. Files that are no longer shown lose a reference; the
    /// ones newly shown gain one.
    @discardableResult
    public func setFloatingImage(_ id: String, imageID: String, originalImageID: String?, now: Date = Date()) -> Bool {
        guard let object = restampFloating(id, now: now), let fill = object.child("fillEffect"), fill["type"] == "image" else { return false }
        let before = Set([fill["imageId"], object["originalImageId"]].compactMap { $0 })
        let after = Set([imageID, originalImageID].compactMap { $0 })
        fill.attributes["imageId"] = imageID
        object.attributes["originalImageId"] = originalImageID
        // A picture cut out along a loop is clear outside the loop.
        if object["isTransparency"] != nil || originalImageID != nil { object.attributes["isTransparency"] = originalImageID == nil ? "False" : "True" }
        for hash in after.subtracting(before) { addFile(hash: hash, name: "image_\(UUID().uuidString.lowercased()).png", now: now) }
        for hash in before.subtracting(after) { releaseFile(hash) }
        touch(now, content: true)
        return true
    }

    // MARK: Paper

    /// What a page's paper can be given.
    public enum Paper: Sendable {
        case color(UInt32)
        case template(PageTemplate)
        /// A picture of one's own under the page: its file's hash and extension.
        case picture(hash: String, fileExtension: String)
    }

    /// The numbers the note's files are bound under, to their hashes: a page names the picture
    /// under it by that number.
    var boundFiles: [Int: String] {
        var out: [Int: String] = [:]
        for entry in note.all("contentFileList").flatMap({ $0.all("contentFile") }) {
            guard let hash = entry["id"] else { continue }
            let named = entry["name"]?.decodedBase64.flatMap { $0.split(separator: "@", maxSplits: 1).first.flatMap { Int($0) } }
            if let number = entry.int("bindNumber") ?? named { out[number] = hash }
        }
        return out
    }

    /// Gives one page, or with `page` nil every page, a colour, a ruling or a picture under it.
    /// A ruling takes a picture away and a picture a ruling; `.blank` takes both.
    public func setPaper(_ paper: Paper, page only: Int? = nil, now: Date = Date()) { setPaper(paper, pages: only.map { [$0] }, now: now) }

    /// The same for several pages at once; nil is every page.
    public func setPaper(_ paper: Paper, pages only: Set<Int>?, now: Date = Date()) {
        guard let pages = note.all("pageList").last?.all("page"), let treePages = tree.child("pageList") else { return }
        let bound = boundFiles
        for (index, page) in pages.enumerated() where only == nil || only!.contains(index) {
            switch paper {
            case .color(let argb):
                page.attributes["bgColor"] = String(Int32(bitPattern: argb))
            case .template, .picture:
                // A page that is a page of a PDF keeps that paper: a ruling is not laid over it.
                if page["templateType"] == "16" || page.child("pdfDataList") != nil { continue }
                // The picture that lay under the page so far goes.
                let old = page.int("bgImageId").flatMap { bound[$0] }
                page.attributes["bgImageId"] = nil
                page.attributes["templateUri"] = nil
                if let old { releaseFile(old) }
                if case .template(let template) = paper {
                    page.attributes["templateType"] = template == .blank ? nil : String(template.code)
                } else if case .picture(let hash, let fileExtension) = paper {
                    let name = "template_\(hash.prefix(12)).\(fileExtension)"
                    addFile(hash: hash, name: name, now: now.addingTimeInterval(-0.01))
                    guard let number = boundFiles.first(where: { $0.value == hash })?.key else { continue }
                    page.attributes["templateType"] = String(PageTemplate.ownPicture)
                    page.attributes["bgImageId"] = String(number)
                    page.attributes["bgImageMode"] = "2"
                    page.attributes["templateUri"] = Data(name.utf8).base64EncodedString()
                }
            }
            guard let entry = treePages.all("page").first(where: { $0["id"] == page["id"] }) else { continue }
            let time = NoteFile.micros(now)
            let hash = NoteHash.container(id: page["id"] ?? "", time: time, children: entry.child("layerList")?.all("layer").map { $0["h"] ?? "" } ?? [])
            page.attributes["modifiedTime"] = time; page.attributes["hash"] = hash
            entry.attributes["t"] = time; entry.attributes["h"] = hash
        }
        touch(now, content: true)
    }

    // MARK: Recordings

    private var voiceList: XMLNode? { attributes.child("voiceDataList") }

    /// Enters a recording whose sound file is `fileHash`.
    public func addRecording(fileHash: String, fileName: String, title: String, seconds: Double, now: Date = Date()) {
        addFile(hash: fileHash, name: fileName, now: now.addingTimeInterval(-0.01))
        let list = attributes.ensureChild("voiceDataList")
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        let length = Int64((seconds * 1000).rounded())
        // As the clients write one: the name and the length as text ("00:01:23") in Base64, the
        // moment it was made in milliseconds, its length in milliseconds, and when the recording
        // started (action 1) and stopped (action 4), in microseconds.
        let entry = XMLNode(name: "voiceData", attributes: [
            "attachFile": fileHash, "name": Data(title.utf8).base64EncodedString(), "playTime": Data(NoteFile.playTime(seconds).utf8).base64EncodedString(),
            "createdTime": String(millis - length), "recordingTime": String(length),
        ])
        let moments = XMLNode(name: "propertyList", attributes: [:])
        moments.children = [
            XMLNode(name: "property", attributes: ["action": "1", "timeStamp": String((millis - length) * 1000)]),
            XMLNode(name: "property", attributes: ["action": "4", "timeStamp": String(millis * 1000)]),
        ]
        entry.children = [moments]
        list.children.append(entry)
        touch(now, content: true)
    }

    /// Takes a recording, and its sound file, out of the note. True when it was there.
    @discardableResult
    public func removeRecording(fileHash: String, now: Date = Date()) -> Bool {
        guard let list = voiceList, let entry = list.all("voiceData").first(where: { $0["attachFile"] == fileHash }) else { return false }
        // One entry, and the one reference it held: the same sound may have been put in twice.
        list.children.removeAll { $0 === entry }
        if list.children.isEmpty { attributes.children.removeAll { $0 === list } }
        releaseFile(fileHash)
        touch(now, content: true)
        return true
    }

    public var recordingTitles: [String] { (voiceList?.all("voiceData") ?? []).compactMap { $0["name"]?.decodedBase64 } }

    /// A length as the clients write it for a recording.
    static func playTime(_ seconds: Double) -> String {
        let whole = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }

    /// Reads a length written by any client: "hh:mm:ss", "mm:ss", or a count of milliseconds.
    static func seconds(playTime text: String) -> Double {
        let parts = text.split(separator: ":").map { Double($0) ?? 0 }
        if parts.count > 1 { return parts.reduce(0) { $0 * 60 + $1 } }
        return (Double(text) ?? 0) / 1000
    }
}

extension LocalEdits {
    /// The size in pixels of a picture file of a note, upright.
    func pixelSize(_ noteID: String, _ hash: String) -> CGSize? { LocalStore.pixelSize(of: store.mediaURL(noteID, hash)) }

    private func picture(_ file: NoteFile, _ id: String) -> (object: XMLNode, image: String, original: String?)? {
        guard let object = file.root.descendants("object").first(where: { $0["id"] == id && $0["type"] != nil }), let image = object.child("fillEffect")?["imageId"] else { return nil }
        return (object, image, object["originalImageId"])
    }

    private func settleIfInText(_ file: NoteFile, _ id: String, now: Date) throws {
        if file.root.descendants("object").first(where: { $0["id"] == id && $0["type"] != nil })?["layoutType"] == "2" { _ = try settleText(file, now: now) }
    }

    /// Shows a part of a picture: `crop` in fractions of the whole picture, or nil for all of
    /// what its file shows. With `restore`, a picture that was cut out along a loop becomes the
    /// picture it was cut from again. `rect` is the frame of what is shown afterwards.
    public func setFloatingCrop(_ noteID: String, id: String, crop: CGRect?, restore: Bool = false, rect: CGRect, page: Int? = nil, now: Date = Date()) throws {
        _ = try change(noteID, now: now) { file -> Bool? in
            guard let found = picture(file, id) else { return nil }
            var shown = found.image
            if restore, let original = found.original {
                file.setFloatingImage(id, imageID: original, originalImageID: nil, now: now)
                shown = original
            }
            guard file.setFloatingCrop(id, crop: crop, pixels: pixelSize(noteID, shown) ?? .zero, rect: rect, page: page, now: now) else { return nil }
            try settleIfInText(file, id, now: now)
            return true
        }
    }

    /// Cuts a picture out along a loop, as the clients keep it: a copy of the picture that is
    /// clear outside the loop becomes the picture shown, the picture it was made from is kept
    /// as its original, and the loop's bounding box is an ordinary crop. `loop` is in fractions
    /// of the whole picture; a loop drawn on a picture that was cut out before is applied to
    /// the picture as it first was.
    public func lassoCrop(_ noteID: String, id: String, loop: [CGPoint], rect: CGRect, page: Int? = nil, now: Date = Date()) throws {
        guard loop.count > 2 else { return }
        let box = loop.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0, box.height > 0 else { return }
        var made: String?
        _ = try change(noteID, now: now) { file -> Bool? in
            guard let found = picture(file, id) else { return nil }
            let source = found.original ?? found.image
            guard let data = LocalEdits.cutOut(store.mediaURL(noteID, source), along: loop) else { throw Failure.pictureUnreadable }
            let hash = NoteFile.sha256(data)
            store.writeFile(noteID, hash, data)
            made = hash
            file.setFloatingImage(id, imageID: hash, originalImageID: source, now: now)
            guard file.setFloatingCrop(id, crop: box, pixels: pixelSize(noteID, hash) ?? .zero, rect: rect, page: page, now: now) else { return nil }
            try settleIfInText(file, id, now: now)
            return true
        }
        // The new file has to be sent with the note.
        if let made { store.update { library in
            guard var record = library.notes[noteID], !(record.unsentFiles ?? []).contains(made) else { return }
            record.unsentFiles = (record.unsentFiles ?? []) + [made]
            library.notes[noteID] = record
        } }
    }

    /// Puts a picture back as it was at an earlier moment: the file it shows, the file that was
    /// made from, the part shown and its frame. For undoing a crop.
    public func setFloatingPicture(_ noteID: String, id: String, imageID: String, originalImageID: String?, crop: CGRect?, rect: CGRect, page: Int? = nil, now: Date = Date()) throws {
        _ = try change(noteID, now: now) { file -> Bool? in
            guard let found = picture(file, id) else { return nil }
            if found.image != imageID || found.original != originalImageID { file.setFloatingImage(id, imageID: imageID, originalImageID: originalImageID, now: now) }
            guard file.setFloatingCrop(id, crop: crop, pixels: pixelSize(noteID, imageID) ?? .zero, rect: rect, page: page, now: now) else { return nil }
            try settleIfInText(file, id, now: now)
            return true
        }
    }

    /// A copy of a picture file that is clear outside a loop given in fractions of the picture,
    /// as PNG, at most 4096 pixels on its longer side.
    static func cutOut(_ url: URL, along loop: [CGPoint]) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // The loop's y points down, the bitmap's up.
        let path = CGMutablePath()
        path.addLines(between: loop.map { CGPoint(x: $0.x * width, y: (1 - $0.y) * height) })
        path.closeSubpath()
        context.addPath(path)
        context.clip()
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        guard let cut = context.makeImage(), let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cut, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// The note's paper: a colour, a ruling, or a picture of one's own (its file as it will be
    /// kept), for one page or with `page` nil for every page.
    public enum PaperChange: Sendable {
        case color(UInt32)
        case template(PageTemplate)
        case picture(data: Data, fileExtension: String)
    }

    public func setPaper(_ noteID: String, _ paper: PaperChange, page: Int? = nil, now: Date = Date()) throws {
        try setPaper(noteID, paper, pages: page.map { [$0] }, now: now)
    }

    /// The same for several pages at once; nil is every page.
    public func setPaper(_ noteID: String, _ paper: PaperChange, pages: Set<Int>?, now: Date = Date()) throws {
        var added: [String] = []
        var stored: NoteFile.Paper
        switch paper {
        case .color(let argb): stored = .color(argb)
        case .template(let template): stored = .template(template)
        case .picture(let data, let fileExtension):
            let hash = NoteFile.sha256(data)
            store.writeFile(noteID, hash, data)
            added = [hash]
            stored = .picture(hash: hash, fileExtension: fileExtension)
        }
        _ = try change(noteID, now: now, pagesChanged: true, addedFiles: added) { file -> Bool? in
            file.setPaper(stored, pages: pages, now: now)
            return true
        }
    }

    /// Keeps a sound file with the note as a recording. Returns the recording's name.
    @discardableResult
    public func addRecording(_ noteID: String, data: Data, fileExtension: String, title: String? = nil, seconds: Double, now: Date = Date()) throws -> String? {
        let hash = NoteFile.sha256(data)
        return try change(noteID, now: now, addedFiles: [hash]) { file -> String? in
            store.writeFile(noteID, hash, data)
            // Named like the clients name theirs, with the next number that is free.
            var name = title ?? ""
            if name.isEmpty {
                let taken = Set(file.recordingTitles)
                var number = taken.count + 1
                repeat { name = String(format: "Voice%03d", number); number += 1 } while taken.contains(name)
            }
            // A name no other recording of the note has: the clients tell them apart by it.
            let taken = Set(file.recordingTitles)
            var unique = name, copy = 1
            while taken.contains(unique) { unique = "\(name) (\(copy))"; copy += 1 }
            let stamp = now.timeIntervalSince1970
            file.addRecording(fileHash: hash, fileName: String(format: "%x_%x.%@", Int(stamp), Int((stamp - stamp.rounded(.down)) * 1_000_000), fileExtension), title: unique, seconds: seconds, now: now)
            name = unique
            return name
        }
    }

    public func removeRecording(_ noteID: String, fileHash: String, now: Date = Date()) throws {
        _ = try change(noteID, now: now) { file -> Bool? in file.removeRecording(fileHash: fileHash, now: now) ? true : nil }
    }
}

extension NoteFile {
    /// Locks or unlocks the note, as the Windows client marks it: locked, the note says so,
    /// names whose it is and is of document type 5; unlocked, it names no one and is of type 0.
    /// The note's content is the same either way: the lock is kept by the clients.
    public func setLocked(_ locked: Bool, owner: String, now: Date = Date()) {
        note.attributes["isLocked"] = locked ? "True" : "False"
        note.attributes["ownerId"] = locked ? owner : ""
        attributes.attributes["documentType"] = locked ? "5" : "0"
        attributes.attributes["ownerId"] = locked ? owner : ""
        // Marked as changed like any edit, so that other clients draw the note's card anew
        // (a card drawn for a locked note shows a lock in place of the note).
        touch(now, content: true)
    }
}

extension LocalEdits {
    /// Locks or unlocks a note. `owner` is the mark of the account whose password guards it.
    public func setLocked(_ noteID: String, _ locked: Bool, owner: String, now: Date = Date()) throws {
        _ = try change(noteID, now: now) { file -> Bool? in
            guard file.note.bool("isLocked") != locked else { return nil }
            file.setLocked(locked, owner: owner, now: now)
            return true
        }
    }

    /// Gives a picture object another picture to show, whole: the object keeps its place and
    /// its width, and takes the new picture's proportions. The file shown before goes when
    /// nothing else shows it.
    public func replaceImage(_ noteID: String, id: String, data: Data, pixelSize: CGSize, now: Date = Date()) throws {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        let hash = NoteFile.sha256(data)
        _ = try change(noteID, now: now, addedFiles: [hash]) { file -> Bool? in
            guard let object = file.root.descendants("object").first(where: { $0["id"] == id && $0["type"] != nil }), let old = object.child("rect").map(NoteDocument.rect) else { return nil }
            store.writeFile(noteID, hash, data)
            guard file.setFloatingImage(id, imageID: hash, originalImageID: nil, now: now) else { return nil }
            let rect = CGRect(x: old.minX, y: old.minY, width: old.width, height: old.width * pixelSize.height / pixelSize.width)
            guard file.setFloatingCrop(id, crop: nil, pixels: pixelSize, rect: rect, now: now) else { return nil }
            if object["layoutType"] == "2" { _ = try settleText(file, now: now) }
            return true
        }
    }
}
