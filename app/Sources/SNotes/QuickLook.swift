import AppKit
import PDFKit
import Quartz
import SamsungNotesKit

/// Notes as PDF files: for exporting, Quick Look, sharing and printing.
enum NotePDF {
    /// Draws every page of a note into a PDF file. Safe to call off the main thread.
    static func write(_ note: LoadedNote, to url: URL) -> Bool {
        // Without the empty spare page at the end that notes keep.
        let layout = NoteLayout(note.document, shown: NoteLayout.shownPageCount(of: note.document))
        guard layout.pageWidth > 0, layout.pageHeight > 0 else { return false }
        let scale = 595.0 / layout.pageWidth
        var box = CGRect(x: 0, y: 0, width: 595, height: layout.pageHeight * scale)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        var pictures: [String: CGImage] = [:]
        for index in 0..<layout.pageCount {
            let rect = layout.pageRect(index)
            // Each page of the file is as high as its page of the note: they need not all be alike.
            var sheet = CGRect(x: 0, y: 0, width: 595, height: rect.height * scale)
            context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &sheet, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.translateBy(x: 0, y: sheet.height)
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            context.clip(to: rect)
            NoteRenderer.draw(note, in: context, dark: false) { hash in
                if let image = pictures[hash] { return image }
                let image = note.image(hash)
                pictures[hash] = image
                return image
            }
            context.endPDFPage()
        }
        context.closePDF()
        return true
    }

    /// A name a file can have, from a note's title.
    static func fileName(_ title: String) -> String {
        var name = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        if name.hasPrefix(".") { name = String(name.dropFirst()) }
        if name.isEmpty { name = String(localized: "Note") }
        return String(name.prefix(120))
    }

    /// Where the PDFs for Quick Look, sharing and printing are kept until the app quits.
    static let scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("SNotes Previews", isDirectory: true)

    static func removeScratch() { try? FileManager.default.removeItem(at: scratch) }

    /// PDFs of these notes in the scratch folder, in the same order. Locked notes and notes that
    /// are not on this Mac are left out.
    @MainActor
    static func temporary(_ ids: [String], in model: AppModel) async -> [URL] {
        // What is being typed in an open note is written first, so the PDF shows it.
        model.flushAll()
        let jobs: [(id: String, name: String, key: String)] = ids.compactMap { id in
            guard let item = model.item(id), !item.record.isLocked else { return nil }
            return (id, fileName(item.title), ThumbnailCache.key(item.record, dark: false))
        }
        let store = model.store
        return await Task.detached(priority: .userInitiated) {
            var urls: [URL] = []
            for job in jobs {
                // One folder per version of a note, so a picture of an older version is never shown.
                let folder = scratch.appendingPathComponent(String(UInt(bitPattern: job.key.hashValue), radix: 36) + "-" + LocalStoreName.safe(job.id), isDirectory: true)
                let url = folder.appendingPathComponent(job.name + ".pdf")
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    guard let note = try? store.load(job.id), write(note, to: url) else { continue }
                }
                urls.append(url)
            }
            return urls
        }.value
    }
}

enum LocalStoreName {
    /// A note's id as a folder name of the scratch area.
    static func safe(_ id: String) -> String { String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(Character.init).prefix(64)) }
}

/// The actions on notes that go through a PDF.
@MainActor
enum NoteExport {
    private static var printing: PDFDocument?

    /// Asks where to save, then writes one PDF per note.
    static func export(_ ids: [String], in model: AppModel) {
        model.flushAll()
        let items = ids.compactMap { model.item($0) }.filter { !$0.record.isLocked }
        guard !items.isEmpty else { return nothingToDo() }
        let store = model.store
        if items.count == 1, let item = items.first {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = NotePDF.fileName(item.title) + ".pdf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task {
                let done = await Task.detached(priority: .userInitiated) { (try? store.load(item.id)).map { NotePDF.write($0, to: url) } ?? false }.value
                if !done { model.lastError = String(localized: "“\(item.title)” could not be exported.") }
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Export")
            panel.message = String(localized: "Choose a folder for \(Format.notes(items.count)) as PDF files.")
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let jobs = items.map { (id: $0.id, name: NotePDF.fileName($0.title)) }
            Task {
                let failed = await Task.detached(priority: .userInitiated) { () -> Int in
                    var failed = 0
                    var used: Set<String> = []
                    for job in jobs {
                        var name = job.name
                        var number = 2
                        while used.contains(name.lowercased()) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + ".pdf").path) {
                            name = "\(job.name) \(number)"
                            number += 1
                        }
                        used.insert(name.lowercased())
                        if let note = try? store.load(job.id), NotePDF.write(note, to: folder.appendingPathComponent(name + ".pdf")) { continue }
                        failed += 1
                    }
                    return failed
                }.value
                if failed > 0 { model.lastError = String(localized: "\(Format.notes(failed)) could not be exported.") }
            }
        }
    }

    static func share(_ ids: [String], in model: AppModel) {
        Task {
            let urls = await NotePDF.temporary(ids, in: model)
            guard !urls.isEmpty else { return nothingToDo() }
            guard let view = Dialogs.host?.contentView else { return }
            let picker = NSSharingServicePicker(items: urls)
            let point = view.isFlipped ? view.bounds.minY + 56 : view.bounds.maxY - 56
            picker.show(relativeTo: NSRect(x: view.bounds.maxX - 180, y: point, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
    }

    static func print(_ ids: [String], in model: AppModel) {
        Task {
            let urls = await NotePDF.temporary(ids, in: model)
            let document = PDFDocument()
            for url in urls {
                guard let part = PDFDocument(url: url) else { continue }
                for index in 0..<part.pageCount { if let page = part.page(at: index) { document.insert(page, at: document.pageCount) } }
            }
            guard document.pageCount > 0 else { return nothingToDo() }
            let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
            operation.jobTitle = ids.count == 1 ? model.item(ids[0])?.title : String(localized: "Notes")
            printing = document
            if let window = Dialogs.host {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                operation.run()
            }
        }
    }

    private static func nothingToDo() {
        Dialogs.inform(title: String(localized: "There is nothing to show for this note"),
                       message: String(localized: "Locked notes, and notes that have not been downloaded to this Mac yet, cannot be previewed, exported or printed."))
    }
}

/// Quick Look for the selected notes: Space in the list, or the Note menu.
@MainActor
final class QuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []
    private var request = 0
    private weak var model: AppModel?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(_ ids: [String], in model: AppModel) {
        if isVisible { QLPreviewPanel.shared().orderOut(nil) } else { show(ids, in: model) }
    }

    func show(_ ids: [String], in model: AppModel) {
        self.model = model
        request += 1
        let mine = request
        Task {
            let urls = await NotePDF.temporary(ids, in: model)
            guard mine == request else { return }
            guard !urls.isEmpty else { NSSound.beep(); return }
            self.urls = urls
            guard let panel = QLPreviewPanel.shared() else { return }
            if panel.isVisible {
                panel.reloadData()
                panel.currentPreviewItemIndex = 0
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// With the panel open, it follows the selection, as in the Finder.
    func selectionChanged(in model: AppModel) {
        guard isVisible, model.path.isEmpty else { return }
        let ids = model.ordered(model.selection)
        guard !ids.isEmpty else { return }
        show(ids, in: model)
    }

    // The application delegate hands the panel over when it opens.
    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    /// Arrow keys typed in the panel move the selection in the window behind it.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, urls.count == 1, let key = event.specialKey,
              [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(key),
              let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }), window.isVisible else { return false }
        window.sendEvent(event)
        return true
    }
}
