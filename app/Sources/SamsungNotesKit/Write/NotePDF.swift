import CoreGraphics
import Foundation

/// The pages of a PDF document, as far as making a note of it needs them.
public struct PDFPages: Sendable, Equatable {
    /// Each page's size as it is shown: its crop box, turned as the page says.
    public var sizes: [CGSize]

    /// More pages than this are not made a note of: every page is a page of the note.
    public static let most = 2_000

    /// Nil for what is not a PDF, has no pages, or cannot be opened without a password.
    public init?(data: Data) {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), document.numberOfPages > 0,
              !document.isEncrypted || document.unlockWithPassword("") else { return nil }
        var out: [CGSize] = []
        for number in 1...document.numberOfPages {
            // A page that cannot be read keeps its place, at a sheet's shape: the pages are named by their numbers.
            guard let page = document.page(at: number) else { out.append(CGSize(width: 595, height: 842)); continue }
            let box = page.getBoxRect(.cropBox)
            let size = page.rotationAngle % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
            out.append(size.width > 1 && size.height > 1 ? size : CGSize(width: 595, height: 842))
        }
        sizes = out
    }
}

extension LocalEdits {
    public enum PDFProblem: Error, CustomStringConvertible {
        case notReadable
        case tooLong(Int)
        case endless

        public var description: String {
            switch self {
            case .notReadable: return "The file is not a PDF that can be opened: it may be damaged, or locked with a password."
            case .tooLong(let pages): return "The PDF has \(pages) pages; a note takes up to \(PDFPages.most)."
            case .endless: return "A note that scrolls without pages cannot take the pages of a PDF."
            }
        }
    }

    private func pages(of data: Data) throws -> PDFPages {
        guard let pages = PDFPages(data: data) else { throw PDFProblem.notReadable }
        guard pages.sizes.count <= PDFPages.most else { throw PDFProblem.tooLong(pages.sizes.count) }
        return pages
    }

    /// A PDF as a note, as Samsung's clients import one: a page of the note for every page of
    /// the document and of its shape, the document itself kept as a file of the note and shown
    /// under whatever is written on the pages, and the usual spare page at the end.
    public func createPDFNote(title: String, pdf data: Data, parent: String = TreeNode.rootID, now: Date = Date()) throws -> String {
        let pages = try pages(of: data)
        let hash = NoteFile.sha256(data)
        return try store.exclusive {
            let file = NoteFile.newTextNote(title: title, body: "", now: now)
            guard file.addPDFPages(hash: hash, fileName: UUID().uuidString.lowercased() + ".pdf", sizes: pages.sizes, at: 0, now: now) != nil else { throw PDFProblem.endless }
            // The empty page a new note begins with gives way to the PDF's; the spare page after it stays.
            file.removePage(pages.sizes.count, now: now)
            file.attributes.attributes["fileRevision"] = "1"
            try store.write(file)
            store.writeFile(file.id, hash, data)
            var record = try LocalEdits.record(from: file, serverID: "", commitID: "", pending: .create, deviceName: Host.current().localizedName ?? "Mac")
            record.revision = 1
            record.unsentFiles = [hash]
            let made = record
            store.update { library in
                library.notes[made.id] = made
                library.nodes[made.id] = TreeNode(id: made.id, kind: .note, parentID: parent, name: title, now: now)
                var dirty = library.dirtyNodes ?? []
                dirty.insert(made.id)
                library.dirtyNodes = dirty
            }
            return made.id
        }
    }

    /// Adds the pages of a PDF to a note, before its page `place` (after its pages without
    /// it). With `replacing`, the page at `place` (an empty one) gives way to them. Returns
    /// where the first of them is and how many they are.
    @discardableResult
    public func addPDFPages(_ noteID: String, pdf data: Data, at place: Int? = nil, replacing: Bool = false, now: Date = Date()) throws -> (first: Int, count: Int) {
        let pages = try pages(of: data)
        let hash = NoteFile.sha256(data)
        let added = try change(noteID, now: now, pagesChanged: true, addedFiles: [hash]) { file -> Range<Int>? in
            store.writeFile(noteID, hash, data)
            guard let range = file.addPDFPages(hash: hash, fileName: UUID().uuidString.lowercased() + ".pdf", sizes: pages.sizes, at: place, now: now) else { throw PDFProblem.endless }
            if replacing, place != nil { file.removePage(range.upperBound, now: now) }
            _ = try settleText(file, now: now)
            return range
        }
        guard let added else { throw PDFProblem.endless }
        return (added.lowerBound, added.count)
    }
}

/// A note as it stood at a moment: its document, and its strokes and attached files held on to,
/// so that a change of its pages or its paper can be taken back whole.
public struct NoteSnapshot: Sendable {
    public let noteID: String
    let folder: URL

    /// Forgets the snapshot: what it held on to is let go.
    public func discard() { try? FileManager.default.removeItem(at: folder) }
}

extension LocalEdits {
    /// Keeps the note as it stands. Strokes and files are held by links, not copied, where the disk allows.
    public func snapshot(_ noteID: String) throws -> NoteSnapshot {
        try store.exclusive {
            let files = FileManager.default
            let folder = files.temporaryDirectory.appendingPathComponent("snotes-undo-" + UUID().uuidString)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.copyItem(at: store.noteURL(noteID), to: folder.appendingPathComponent("note.xml"))
            for part in ["strokes", "media"] {
                let from = store.directory(noteID).appendingPathComponent(part), to = folder.appendingPathComponent(part)
                try files.createDirectory(at: to, withIntermediateDirectories: true)
                for name in (try? files.contentsOfDirectory(atPath: from.path)) ?? [] where !name.hasPrefix(".") {
                    let source = from.appendingPathComponent(name), target = to.appendingPathComponent(name)
                    if (try? files.linkItem(at: source, to: target)) == nil { try files.copyItem(at: source, to: target) }
                }
            }
            return NoteSnapshot(noteID: noteID, folder: folder)
        }
    }

    /// Puts a note back as a snapshot has it: pages, paper, text, strokes and files. What the
    /// note has since been sent as is sent again as it now stands.
    public func restore(_ snapshot: NoteSnapshot, now: Date = Date()) throws {
        let noteID = snapshot.noteID
        try store.exclusive {
            let files = FileManager.default
            let file = try NoteFile(data: try Data(contentsOf: snapshot.folder.appendingPathComponent("note.xml")))
            guard file.id == noteID else { throw CocoaError(.fileReadCorruptFile) }
            let current = try store.noteFile(noteID)
            // What comes back that the note does not have just now has to be sent again.
            let strokesNow = Set(store.partNames(noteID).strokes), filesNow = Set(current.fileIDs)
            var strokesBack: [String] = []
            for part in ["strokes", "media"] {
                let from = snapshot.folder.appendingPathComponent(part), to = store.directory(noteID).appendingPathComponent(part)
                try files.createDirectory(at: to, withIntermediateDirectories: true)
                let kept = Set((try? files.contentsOfDirectory(atPath: from.path)) ?? [])
                for name in kept where !files.fileExists(atPath: to.appendingPathComponent(name).path) {
                    try files.copyItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name))
                }
                if part == "strokes" {
                    // Strokes made since are not part of the note as it was.
                    for name in (try? files.contentsOfDirectory(atPath: to.path)) ?? [] where name.hasSuffix(".bin") && !kept.contains(name) { try? files.removeItem(at: to.appendingPathComponent(name)) }
                    strokesBack = kept.filter { $0.hasSuffix(".bin") }.map { String($0.dropLast(4)) }.filter { !strokesNow.contains($0) }
                }
            }
            file.touch(now, content: true)
            try store.write(file)
            try refreshRestored(noteID, file: file, now: now, strokes: strokesBack, files: file.fileIDs.filter { !filesNow.contains($0) })
        }
    }
}
