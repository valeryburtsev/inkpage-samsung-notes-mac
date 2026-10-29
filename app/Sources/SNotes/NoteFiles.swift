import AppKit
import PDFKit
import SamsungNotesKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Notes out to files other than PDF, and files in as notes.
@MainActor
enum NoteFiles {
    static func fileName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Note" : String(cleaned.prefix(80))
    }

    /// One PNG per page into a folder the user picks.
    static func exportPictures(_ id: String, in model: AppModel) {
        guard let item = model.item(id), !item.record.isLocked else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the pages of “\(item.title)” as pictures."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let store = model.store
        let name = fileName(item.title)
        Task {
            let written = await Task.detached(priority: .userInitiated) { () -> Int in
                guard let note = try? store.load(id) else { return 0 }
                let images = NoteImages(note: note)
                var written = 0
                for index in 0..<NoteLayout(note.document, shown: NoteLayout.shownPageCount(of: note.document)).pageCount {
                    guard let image = NoteRenderer.pageImage(note, page: index, pixelWidth: 1696, dark: false, images: { images.image($0) }) else { continue }
                    NoteRenderer.writePNG(image, to: folder.appendingPathComponent("\(name) \(index + 1).png"))
                    written += 1
                }
                return written
            }.value
            if written == 0 { model.lastError = "“\(item.title)” could not be exported." } else { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }

    /// The note's title, text and what was read in its handwriting, as a text file.
    static func exportText(_ id: String, in model: AppModel) {
        guard let item = model.item(id), !item.record.isLocked else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = fileName(item.title) + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var parts = [item.title]
        if let rich = model.edits.richText(id) { parts.append(rich.body.plain) }
        if let ink = item.record.inkText, !ink.isEmpty { parts.append("Handwriting:\n" + ink) }
        do { try parts.filter { !$0.isEmpty }.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8) } catch {
            model.lastError = "“\(item.title)” could not be exported. \(AppModel.describe(error))"
        }
    }

    static let importable: [UTType] = [.image, .pdf, .plainText]

    /// Asks for files and makes notes of them.
    static func chooseAndImport(in model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = importable
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Pictures, PDF documents and text files become notes."
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, in: model)
    }

    /// Asks for PDF documents and makes a note of each, as the Windows client's "Import PDF" does.
    static func chooseAndImportPDF(in model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Each page of the PDF becomes a page of a new note, to read and to write on."
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, in: model)
    }

    static func canImport(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return importable.contains { type.conforms(to: $0) }
    }

    /// Makes notes of files: a text file becomes a text note, a PDF a note of its pages,
    /// pictures one note holding them all. The folder shown in the sidebar takes them.
    static func importFiles(_ urls: [URL], in model: AppModel) {
        let urls = urls.filter(canImport)
        guard !urls.isEmpty else { return }
        var parent = TreeNode.rootID
        if case .folder(let id) = model.section { parent = id }
        let edits = model.edits
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (made: [String], failed: [String]) in
                var made: [String] = [], failed: [String] = []
                var pictures: [(name: String, file: PictureFile)] = []
                for url in urls {
                    let name = url.deletingPathExtension().lastPathComponent
                    let type = UTType(filenameExtension: url.pathExtension) ?? .data
                    if type.conforms(to: .pdf) {
                        // As Samsung's clients take a PDF in: its pages are the note's pages, the document itself a file of the note.
                        do {
                            made.append(try edits.createPDFNote(title: name, pdf: try Data(contentsOf: url), parent: parent))
                        } catch let problem as LocalEdits.PDFProblem {
                            failed.append("\(url.lastPathComponent) (\(problem.description))")
                        } catch {
                            failed.append(url.lastPathComponent)
                        }
                    } else if type.conforms(to: .image) {
                        if let data = try? Data(contentsOf: url), let file = PictureFile(data: data) { pictures.append((name, file)) } else { failed.append(url.lastPathComponent) }
                    } else if let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) {
                        let whole = text.replacingOccurrences(of: "\r\n", with: "\n")
                        if whole.count > 200_000 { failed.append("all of \(url.lastPathComponent) (only its first 200,000 characters were taken)") }
                        if let id = try? edits.createTextNote(title: name, body: String(whole.prefix(200_000)), parent: parent) { made.append(id) } else { failed.append(url.lastPathComponent) }
                    } else {
                        failed.append(url.lastPathComponent)
                    }
                }
                if let first = pictures.first, let id = try? edits.createTextNote(title: pictures.count == 1 ? first.name : "\(first.name) and \(pictures.count - 1) more", body: "", parent: parent) {
                    for picture in pictures where (try? edits.addImage(id, data: picture.file.data, fileExtension: picture.file.fileExtension, pixelSize: picture.file.pixels)) == nil { failed.append(picture.name) }
                    made.append(id)
                }
                return (made, failed)
            }.value
            model.changed()
            if !result.failed.isEmpty { model.lastError = "Could not import \(result.failed.joined(separator: ", "))." }
            if result.made.count == 1, let only = result.made.first, model.path.isEmpty { model.open(only) } else { model.selection = Set(result.made) }
        }
    }
}

/// Reads the handwriting of notes in the background, so that search finds what was written by hand.
@MainActor
final class InkIndexer {
    static let shared = InkIndexer()
    private var running = false
    private var again = false

    /// Looks for notes whose handwriting has not been read yet and reads them, one at a time.
    func schedule(_ model: AppModel) {
        guard !running else { again = true; return }
        let waiting = model.library.notes.values.filter { $0.hasInk && $0.inkText == nil && !$0.isLocked }.sorted { $0.modifiedAt > $1.modifiedAt }.map { ($0.id, $0.revision, $0.commitID) }
        guard !waiting.isEmpty else { return }
        running = true
        let store = model.store, edits = model.edits
        Task {
            await Task.detached(priority: .utility) {
                for (id, revision, commit) in waiting.prefix(200) {
                    guard let note = try? store.load(id) else { continue }
                    edits.setInkText(id, InkIndexer.read(note), forRevision: revision, commit: commit)
                }
            }.value
            running = false
            model.changed(sync: false)
            if again { again = false; schedule(model) }
        }
    }

    /// The text Vision finds on the pages that have handwriting.
    nonisolated static func read(_ note: LoadedNote) -> String {
        let images = NoteImages(note: note)
        var found: [String] = []
        for (index, page) in note.document.pages.enumerated().prefix(60) where page.objects.contains(where: { $0.kind == .stroke }) {
            guard let image = NoteRenderer.pageImage(note, page: index, pixelWidth: 1500, dark: false, body: false, images: { images.image($0) }) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { continue }
            for observation in request.results ?? [] {
                if let best = observation.topCandidates(1).first, best.confidence > 0.3 { found.append(best.string) }
            }
        }
        return String(found.joined(separator: "\n").prefix(20_000))
    }
}
