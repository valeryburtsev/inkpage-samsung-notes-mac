import CoreGraphics
import Foundation

/// Tables of an editable note: Samsung's own kind (`type="tableNew"`), kept as a binary record
/// in the object and set in the text by a place of their own.
extension NoteFile {
    /// The format a note with a table in it says it is in, and needs a client to know.
    static let tableFormat = 5400

    func raiseFormat(to version: Int, body raised: Bool = true) {
        for name in ["formatVersion", "minFormatVersion"] where (attributes.int(name) ?? 0) < version { attributes.attributes[name] = String(version) }
        if raised, let body = bodyObject, (body.int("formatVersion") ?? 0) < version { body.attributes["formatVersion"] = String(version) }
    }

    /// The parts of a table's object that follow from the table: its rectangle, the outline it
    /// was made with, and its record.
    static func shapeTable(_ object: XMLNode, _ table: SamsungTable) {
        func node(_ name: String, _ attributes: [String: String], _ children: [XMLNode] = []) -> XMLNode {
            let node = XMLNode(name: name, attributes: attributes)
            node.children = children
            return node
        }
        let rect = table.rect, made = table.outline
        func corners(_ name: String) -> XMLNode { node(name, ["l": float(rect.minX), "t": float(rect.minY), "r": float(rect.maxX), "b": float(rect.maxY)]) }
        object.children.removeAll { ["rect", "connectionPointList", "originalRect", "path", "tableBinary"].contains($0.name) }
        let record = node("tableBinary", [:])
        record.text = table.binary.base64EncodedString()
        object.children.append(contentsOf: [
            corners("rect"),
            node("connectionPointList", [:], [
                node("point", ["x": wide(made.midX), "y": wide(made.minY)]), node("point", ["x": wide(made.maxX), "y": wide(made.midY)]),
                node("point", ["x": wide(made.midX), "y": wide(made.maxY)]), node("point", ["x": wide(made.minX), "y": wide(made.midY)]),
            ]),
            corners("originalRect"),
            node("path", [:], [node("segmentList", [:], [
                node("segment", ["type": "1", "x": float(made.minX), "y": float(made.minY)]), node("segment", ["type": "2", "x": float(made.maxX), "y": float(made.minY)]),
                node("segment", ["type": "2", "x": float(made.maxX), "y": float(made.maxY)]), node("segment", ["type": "2", "x": float(made.minX), "y": float(made.maxY)]),
                node("segment", ["type": "6"]),
            ])]),
            record,
        ])
    }

    /// Enters a table into the note, at a place in its text (at its end without one). Written
    /// as the Windows client writes one. Returns the table's id.
    @discardableResult
    public func addTable(_ table: SamsungTable, textOffset: Int? = nil, now: Date = Date()) -> String {
        let time = String(table.modified)
        let hash = NoteHash.object(id: table.id, time: time)
        let object = XMLNode(name: "object", attributes: [
            "type": "tableNew", "id": table.id, "hash": hash, "formatVersion": String(NoteFile.tableFormat), "appendTime": String(table.appended), "modifiedTime": time, "createdTime": "0",
            "clippable": "True", "ellipsisType": "2", "flippable": "False", "haveBeenToAtt": "True", "isHintTextVisible": "False", "isHorizontalFlipped": "False",
            "isReplayable": "True", "isTemplateObject": "False", "isTextEditable": "True", "isTextReadOnly": "False", "isTransparency": "False", "isVerticalFlipped": "False",
            "layoutType": "3", "lockState": "False", "movable": "True", "originalDegree": "0", "ownerPageHeight": "0", "ownerPageWidth": String(table.pageWidth),
            "pageIndex": String(table.pageIndex), "removable": "True", "resizable": "0", "rotatable": "False", "selectable": "True", "shapeType": "4", "timeStamp": "0", "visible": "True",
        ])
        NoteFile.shapeTable(object, table)
        floatingList.children.append(object)
        treeFloatingList.children.append(XMLNode(name: "object", attributes: ["id": table.id, "t": time, "h": hash]))
        var text = bodyText
        if let textOffset { text.insertObject(id: table.id, at: textOffset, tail: "3,2") } else { text.appendObject(id: table.id, tail: "3,2") }
        setBodyText(text, now: now)
        raiseFormat(to: NoteFile.tableFormat)
        touch(now, content: true)
        return table.id
    }

    /// The table of an object of the note, read from its record.
    public func table(_ id: String) -> SamsungTable? {
        guard let object = note.child("floatingObjectList")?.all("object").first(where: { $0["id"] == id && $0["type"] == "tableNew" }),
              let record = object.value("tableBinary").flatMap({ Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return nil }
        return SamsungTable(binary: record)
    }

    /// Writes a table over the one with its id: its record, its rectangle, and a new time and hash.
    @discardableResult
    public func setTable(_ changed: SamsungTable, now: Date = Date()) -> Bool {
        guard let object = restampFloating(changed.id, now: now), object["type"] == "tableNew" else { return false }
        var table = changed
        // The record carries the object's own time.
        table.modified = Int64(object["modifiedTime"] ?? "") ?? table.modified
        object.attributes["pageIndex"] = String(table.pageIndex)
        NoteFile.shapeTable(object, table)
        touch(now, content: true)
        return true
    }
}

extension LocalEdits {
    /// Puts a new table of empty cells into a note's text. Returns the table's id.
    @discardableResult
    public func addTable(_ noteID: String, rows: Int, columns: Int, textOffset: Int? = nil, id: String? = nil, now: Date = Date()) throws -> String? {
        try change(noteID, now: now) { file -> String? in
            var table = SamsungTable(rows: rows, columns: columns, pageWidth: file.pageSize(0).width, top: file.textColumn.top, now: now)
            if let id { table.id = id }
            let made = file.addTable(table, textOffset: textOffset, now: now)
            _ = try settleText(file, now: now)
            return made
        }
    }

    /// Gives a table other texts, row by row; rows and columns come and go with them. Only a
    /// table this client can write as it found it is changed. True when it was.
    /// `bold` and `italic`, where given, say for each cell whether all of its text is.
    @discardableResult
    public func setTable(_ noteID: String, id: String, texts: [[String]], bold: [[Bool]]? = nil, italic: [[Bool]]? = nil, now: Date = Date()) throws -> Bool {
        try change(noteID, now: now) { file -> Bool? in
            guard let object = file.root.descendants("object").first(where: { $0["id"] == id && $0["type"] == "tableNew" }),
                  let record = object.value("tableBinary").flatMap({ Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
                  let table = SamsungTable(binary: record), table.binary == record else { return nil }
            guard file.setTable(table.with(texts: texts, bold: bold, italic: italic, now: now), now: now) else { return nil }
            _ = try settleText(file, now: now)
            return true
        } ?? false
    }

    /// Writes a table as it now is over the one with its id: its cells, their styles, its
    /// columns. The text makes room for its new height. True when it was written.
    @discardableResult
    public func setTable(_ noteID: String, table: SamsungTable, now: Date = Date()) throws -> Bool {
        try change(noteID, now: now) { file -> Bool? in
            guard let stored = file.table(table.id) else { return nil }
            var changed = table
            // It stands where the note has it now, whatever was typed above it meanwhile.
            changed.pageIndex = stored.pageIndex
            changed.move(to: stored.rect.origin)
            guard file.setTable(changed, now: now) else { return nil }
            _ = try settleText(file, now: now)
            return true
        } ?? false
    }

    /// Puts a table of Samsung's own kind where a picture stands in the text (a table that an
    /// earlier build of this app kept as a picture), with these cells; the picture goes.
    /// Without a place in the text the table goes to its end. Returns the table's id.
    @discardableResult
    public func replaceWithTable(_ noteID: String, picture: String, texts: [[String]], bold: [[Bool]]? = nil, id: String? = nil, now: Date = Date()) throws -> String? {
        try change(noteID, now: now) { file -> String? in
            var text = file.bodyText
            let offset = text.spans.first { $0.key == NoteText.objectKey && $0.value.split(separator: ",").first.map(String.init) == picture }?.start
            if text.removeObjects([picture]) { file.setBodyText(text, now: now) }
            _ = file.removeFloating([picture], now: now)
            var table = SamsungTable(rows: max(texts.count, 1), columns: max(texts.map(\.count).max() ?? 1, 1), pageWidth: file.pageSize(0).width, top: file.textColumn.top, now: now)
            if let id { table.id = id }
            let made = file.addTable(table.with(texts: texts, bold: bold, now: now), textOffset: offset, now: now)
            _ = try settleText(file, now: now)
            return made
        }
    }
}
