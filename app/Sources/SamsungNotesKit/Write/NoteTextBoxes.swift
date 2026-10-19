import CoreGraphics
import CoreText
import Foundation

/// Text boxes: a frame of text set down on a page, apart from the note's own text. As the
/// Windows client's code writes one (protocol 5.29): an object of the page's layer, like a
/// stroke, with the body text's encoding inside it.
extension NoteFile {
    /// The margins a new text box has around its text, in text units, and the size of its letters.
    public static let textBoxMargins = (left: 8.0, top: 4.0, right: 8.0, bottom: 4.0)
    public static let textBoxFontSize = 12.0

    /// How high a text box of this width must be to hold its text, in the page's units.
    public static func textBoxHeight(_ text: String, width: Double, pageWidth: Double, fontSize: Double = textBoxFontSize) -> Double {
        let density = pageWidth / 360
        let lineHeight = 1.35 * fontSize * density
        let inner = max(width - (textBoxMargins.left + textBoxMargins.right) * density, 8)
        var lines = 0.0
        if !text.isEmpty {
            let font = CTFontCreateUIFontForLanguage(.system, fontSize * density, nil) ?? CTFontCreateWithName("Helvetica Neue" as CFString, fontSize * density, nil)
            let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: inner, height: 1_000_000), transform: nil), nil)
            lines = Double((CTFrameGetLines(frame) as? [CTLine])?.count ?? 1)
            if text.hasSuffix("\n") { lines += 1 }
        }
        // An empty box is two lines high, as the Windows client makes it.
        return ((max(lines, text.isEmpty ? 2 : 1) * lineHeight) + (textBoxMargins.top + textBoxMargins.bottom) * density).rounded(.up)
    }

    private func textBox(_ id: String) -> (node: XMLNode, page: Int)? {
        for index in 0..<pageCount {
            if let node = layers(page: index)?.full.child("objectList")?.all("object").first(where: { $0["id"] == id && $0["type"] == "textBox" }) { return (node, index) }
        }
        return nil
    }

    /// What a text box says, as plain text; nil when the note has no such box.
    public func textBoxText(_ id: String) -> String? { textBox(id).map { NoteFile.noteText(of: $0.node, body: false).plain } }

    private static func setCorners(_ node: XMLNode, _ name: String, _ rect: CGRect) {
        let found = node.child(name) ?? {
            let made = XMLNode(name: name, attributes: [:])
            node.children.append(made)
            return made
        }()
        found.attributes = ["l": NoteFile.float(rect.minX), "t": NoteFile.float(rect.minY), "r": NoteFile.float(rect.maxX), "b": NoteFile.float(rect.maxY)]
    }

    private static func write(_ text: String, into node: XMLNode) {
        // A box another client wrote keeps the look of its text: its first letters' look, for all of it.
        let was = NoteFile.noteText(of: node, body: false)
        var stored = NoteText.uniform(text, like: was.spans.isEmpty ? nil : was, body: true)
        stored.hasSection = false
        let encoded = stored.encoded()
        // The text's parts lie after the box's own, in the order the client writes them.
        NoteFile.setText(node, encoded: text.isEmpty ? "" : encoded.text, spans: encoded.spanList)
    }

    /// Sets a text box down on a page. `sized` says the user gave it its size: then it no longer
    /// grows with its text. Returns its id, or nil when the note has no such page.
    @discardableResult
    public func addTextBox(id: String = UUID().uuidString.lowercased(), page index: Int, rect: CGRect, text: String, sized: Bool = false, now: Date = Date()) -> String? {
        guard let found = layers(page: index) else { return nil }
        let time = NoteFile.micros(now)
        let hash = NoteHash.object(id: id, time: time)
        let width = found.fullPage.int("width") ?? 848
        let node = XMLNode(name: "object", attributes: [
            "type": "textBox", "id": id, "hash": hash, "formatVersion": "4000", "rotatable": "True", "selectable": "True", "movable": "True", "flippable": "True", "visible": "True",
            "isReplayable": "True", "clippable": "True", "isTemplateObject": "False", "timeStamp": "0", "resizable": "0", "haveBeenToAtt": "True", "lockState": "False",
            "createdTime": "0", "modifiedTime": time, "appendTime": time, "ownerPageWidth": String(width), "ownerPageHeight": "0", "removable": "True",
            "isHorizontalFlipped": "False", "isVerticalFlipped": "False", "isHintTextVisible": "False", "isTextReadOnly": "False", "isTextEditable": "True", "isTransparency": "False",
            "shapeType": "4", "originalDegree": "0", "leftMargin": "8", "topMargin": "4", "rightMargin": "8", "bottomMargin": "4", "textGravity": "0", "ellipsisType": "2",
            "textAutoFit": sized ? "0" : "2",
        ])
        NoteFile.setCorners(node, "rect", rect)
        let color = XMLNode(name: "lineColorEffect", attributes: ["colorType": "2", "gradientRotatable": "False", "solidColor": "-16777216", "gradientType": "0", "angle": "0"])
        color.children = [XMLNode(name: "radialGradientPosition", attributes: ["x": "0", "y": "0"])]
        node.children.append(color)
        node.children.append(XMLNode(name: "lineStyleEffect", attributes: ["width": "0", "compoundType": "0", "dashType": "0", "capType": "0", "joinType": "0", "beginArrowType": "0", "beginArrowSize": "0",
                                                                          "endArrowType": "0", "endArrowSize": "0"]))
        NoteFile.setCorners(node, "originalRect", rect)
        NoteFile.write(text, into: node)
        found.full.ensureChild("objectList").children.append(node)
        found.tree.ensureChild("objectList").children.append(XMLNode(name: "object", attributes: ["id": id, "t": time, "h": hash]))
        widenDrawn(found.fullPage, by: rect)
        rehash(page: index, now: now)
        return id
    }

    private func widenDrawn(_ page: XMLNode, by rect: CGRect) {
        var drawn = page.child("drawnRect").map(NoteDocument.rect) ?? .null
        if drawn.isEmpty && drawn.origin == .zero { drawn = .null }
        drawn = drawn.union(rect)
        let node = page.child("drawnRect") ?? {
            let created = XMLNode(name: "drawnRect", attributes: [:])
            page.children.insert(created, at: 0)
            return created
        }()
        node.attributes = ["l": String(Float(drawn.minX)), "t": String(Float(drawn.minY)), "r": String(Float(drawn.maxX)), "b": String(Float(drawn.maxY))]
    }

    /// Gives a text box what it now says, where it now lies, or both; moved to another page
    /// when `page` names one. `sized`: the user gave it its size. False when there is no such box.
    @discardableResult
    public func setTextBox(_ id: String, text: String? = nil, rect: CGRect? = nil, page: Int? = nil, sized: Bool? = nil, now: Date = Date()) -> Bool {
        guard let box = textBox(id) else { return false }
        let time = NoteFile.micros(now)
        let hash = NoteHash.object(id: id, time: time)
        box.node.attributes["modifiedTime"] = time
        box.node.attributes["hash"] = hash
        if let text { NoteFile.write(text, into: box.node) }
        if let rect {
            NoteFile.setCorners(box.node, "rect", rect)
            NoteFile.setCorners(box.node, "originalRect", rect)
        }
        if let sized { box.node.attributes["textAutoFit"] = sized ? "0" : "2" }
        let target = page ?? box.page
        if target != box.page, let from = layers(page: box.page), let to = layers(page: target) {
            from.full.child("objectList")?.children.removeAll { $0 === box.node }
            let entry = from.tree.child("objectList")?.all("object").first { $0["id"] == id }
            from.tree.child("objectList")?.children.removeAll { $0["id"] == id }
            to.full.ensureChild("objectList").children.append(box.node)
            to.tree.ensureChild("objectList").children.append(entry ?? XMLNode(name: "object", attributes: ["id": id]))
            rehash(page: box.page, now: now)
        }
        if let found = layers(page: target) {
            if let entry = found.tree.child("objectList")?.all("object").first(where: { $0["id"] == id }) { entry.attributes["t"] = time; entry.attributes["h"] = hash }
            if let rect { widenDrawn(found.fullPage, by: rect) }
        }
        rehash(page: target, now: now)
        return true
    }
}

extension LocalEdits {
    /// Sets a new text box down on a page of a note.
    @discardableResult
    public func addTextBox(_ noteID: String, page: Int, rect: CGRect, text: String = "", id: String = UUID().uuidString.lowercased(), sized: Bool = false, now: Date = Date()) throws -> String? {
        try change(noteID, now: now, pagesChanged: true) { file in file.addTextBox(id: id, page: page, rect: rect, text: text, sized: sized, now: now) }
    }

    /// Changes what a text box says, where it lies, or both.
    public func setTextBox(_ noteID: String, id: String, text: String? = nil, rect: CGRect? = nil, page: Int? = nil, sized: Bool? = nil, now: Date = Date()) throws {
        _ = try change(noteID, now: now, pagesChanged: true) { file -> Bool? in file.setTextBox(id, text: text, rect: rect, page: page, sized: sized, now: now) ? true : nil }
    }

    /// Takes a text box off its page.
    public func removeTextBox(_ noteID: String, id: String, now: Date = Date()) throws {
        _ = try change(noteID, now: now, pagesChanged: true) { file -> Bool? in file.removeObjects([id], now: now).isEmpty ? nil : true }
    }
}
