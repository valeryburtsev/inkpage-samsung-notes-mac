import AppKit
import PDFKit
import SamsungNotesKit
import SwiftUI

/// The text of a PDF that lies under a note's pages, picked out with the pointer as in
/// Preview: drag across it, press twice for a word, three times for a line, and copy it.
/// It is picked with ⌥ held, with the keyboard tool (Samsung's clients have nothing of the
/// kind: there a PDF in a note is paper to write and draw on), so typing is not in its way.
/// Nothing of it is stored: the PDF is not changed, and the note's own text is another thing.
@MainActor @Observable
final class PDFTextSelection {
    /// What is picked on one page of the note: the stretches of each line, in the page's own
    /// units, y down.
    struct Mark: Equatable {
        var page: Int
        var rects: [CGRect]
    }

    private(set) var marks: [Mark] = []
    @ObservationIgnored private(set) var string = ""
    /// The note whose pages are looked at; the session keeps it current.
    @ObservationIgnored var note: LoadedNote? { didSet { if note?.document.id != oldValue?.document.id { documents = [:]; clear() } } }
    @ObservationIgnored private var documents: [String: PDFDocument] = [:]
    /// Where the drag began: the page of the note, and the place on the PDF page in its own space.
    @ObservationIgnored private var anchor: (page: Int, point: CGPoint)?

    var isEmpty: Bool { marks.isEmpty }

    /// A page of the note as a page of its PDF, with what takes a place on the one to a place on the other.
    private struct Sheet {
        var file: String
        var page: PDFPage
        var number: Int
        /// The note's units for one point of the PDF, and where the PDF page's left edge lies on the note's page.
        var scale: Double
        var left: Double
        /// The PDF page's size as it is shown: its crop box, turned as the page says.
        var size: CGSize

        /// From the note's page (y down) into the PDF page's own space.
        func inward(_ point: CGPoint) -> CGPoint {
            let shown = CGPoint(x: (point.x - left) / scale, y: size.height - point.y / scale)
            return shown.applying(page.transform(for: .cropBox).inverted())
        }

        /// From the PDF page's own space onto the note's page.
        func outward(_ rect: CGRect) -> CGRect {
            let shown = rect.applying(page.transform(for: .cropBox))
            return CGRect(x: left + shown.minX * scale, y: (size.height - shown.maxY) * scale, width: shown.width * scale, height: shown.height * scale)
        }
    }

    private func sheet(_ index: Int) -> Sheet? {
        guard let note, let page = note.document.pages[safe: index], let pdf = page.pdf else { return nil }
        if documents[pdf.file] == nil, let url = note.fileURL(pdf.file), let opened = PDFDocument(url: url) { documents[pdf.file] = opened }
        guard let found = documents[pdf.file]?.page(at: pdf.page) else { return nil }
        let box = found.bounds(for: .cropBox)
        let size = found.rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 1, size.height > 1, page.width > 0, page.height > 0 else { return nil }
        // As the page is drawn: as large as fits, from the top, in the middle.
        let scale = min(page.width / size.width, page.height / size.height)
        return Sheet(file: pdf.file, page: found, number: pdf.page, scale: scale, left: (page.width - size.width * scale) / 2, size: size)
    }

    /// True where a page of the note is a page of a PDF.
    func isPDF(_ page: Int) -> Bool { note?.document.pages[safe: page]?.pdf != nil }

    /// True when the PDF has text at this place of a page of the note (or right beside it).
    func hasText(page: Int, at point: CGPoint) -> Bool {
        guard let sheet = sheet(page) else { return false }
        return word(sheet, at: sheet.inward(point)) != nil
    }

    private func word(_ sheet: Sheet, at point: CGPoint) -> PDFSelection? {
        // A little to either side counts: text is thin, and a drag often starts beside it.
        for reach in [CGPoint.zero, CGPoint(x: 0, y: 3), CGPoint(x: 0, y: -3), CGPoint(x: 3, y: 0), CGPoint(x: -3, y: 0)] {
            let near = CGPoint(x: point.x + reach.x, y: point.y + reach.y)
            if let found = sheet.page.selectionForWord(at: near), !(found.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               found.bounds(for: sheet.page).insetBy(dx: -3, dy: -3).contains(near) { return found }
        }
        return nil
    }

    /// The pointer went down on a page of the note: begins to pick the PDF's text there when
    /// there is some. One press sets where a drag starts, two pick the word, three the line.
    func begin(page: Int, at point: CGPoint, clicks: Int) -> Bool {
        guard let sheet = sheet(page) else { return false }
        let inside = sheet.inward(point)
        guard word(sheet, at: inside) != nil else { return false }
        anchor = (page, inside)
        switch clicks {
        case 2: show(word(sheet, at: inside))
        case 3...: show(sheet.page.selectionForLine(at: inside))
        default: show(nil)
        }
        return true
    }

    /// The pointer moved with the button down: everything from where it went down to here is picked.
    func drag(page: Int, to point: CGPoint) {
        guard let anchor, let from = sheet(anchor.page) else { return }
        // Only as far as the same document goes: another PDF, or a page of the note's own, ends it.
        guard let to = sheet(page), to.file == from.file, let document = documents[from.file] else { return }
        let end = to.inward(point)
        if to.number == from.number {
            show(from.page.selection(from: anchor.point, to: end))
        } else if from.number < to.number {
            show(document.selection(from: from.page, at: anchor.point, to: to.page, at: end))
        } else {
            show(document.selection(from: to.page, at: end, to: from.page, at: anchor.point))
        }
    }

    private func show(_ selection: PDFSelection?) {
        var found: [Int: [CGRect]] = [:]
        if let selection, let note {
            // Which page of the note shows which page of this document.
            var places: [Int: Int] = [:]
            let file = anchor.flatMap { sheet($0.page)?.file }
            for (index, page) in note.document.pages.enumerated() where page.pdf?.file == file { if let number = page.pdf?.page { places[number] = index } }
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    guard let number = page.document?.index(for: page), let index = places[number], let sheet = sheet(index) else { continue }
                    let rect = sheet.outward(line.bounds(for: page))
                    if rect.width > 0.5, rect.height > 0.5 { found[index, default: []].append(rect) }
                }
            }
        }
        let new = found.keys.sorted().map { Mark(page: $0, rects: found[$0] ?? []) }
        if new != marks { marks = new }
        string = selection?.string ?? ""
    }

    func clear() {
        anchor = nil
        if !marks.isEmpty { marks = [] }
        string = ""
    }

    /// Puts what is picked on the pasteboard. False when nothing is picked.
    @discardableResult
    func copy() -> Bool {
        guard !isEmpty, !string.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        return true
    }

    /// Where the lines of the PDF's text lie on a page of the note, from the top: for the checks.
    func lines(page: Int) -> [CGRect] {
        guard let sheet = sheet(page), let all = sheet.page.selection(for: sheet.page.bounds(for: .cropBox)) else { return [] }
        return all.selectionsByLine().map { sheet.outward($0.bounds(for: sheet.page)) }.filter { $0.width > 4 }.sorted { $0.minY < $1.minY }
    }

    /// True when a place on a page lies on what is picked.
    func isPicked(page: Int, at point: CGPoint) -> Bool { marks.first { $0.page == page }?.rects.contains { $0.insetBy(dx: -2, dy: -2).contains(point) } ?? false }
}

/// What is picked of a PDF's text on one page, laid over the page as the system marks picked text.
struct PDFTextMarks: View {
    let selection: PDFTextSelection
    let page: Int
    /// The note's units for one point of the view.
    let unit: Double

    var body: some View {
        if let mark = selection.marks.first(where: { $0.page == page }) {
            Canvas { context, _ in
                for rect in mark.rects {
                    context.fill(Path(CGRect(x: rect.minX / unit, y: rect.minY / unit, width: rect.width / unit, height: rect.height / unit)), with: .color(Color(nsColor: .selectedTextBackgroundColor)))
                }
            }
            // Laid over the page as a wash: the letters under it stay as dark as they are.
            .blendMode(.multiply)
            .allowsHitTesting(false)
        }
    }
}

/// Lies on a page of a PDF under the note's text: where the text view does not reach (the
/// page's edges beside the text's column), it takes the pointer in the text view's name, so
/// that ⌥ and a drag pick the PDF's text there as anywhere on the page.
struct PDFTextCatcher: NSViewRepresentable {
    let controller: TextController

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.controller = controller }

    final class CatcherView: NSView {
        weak var controller: TextController?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
        }

        private func point(_ event: NSEvent) { (controller?.view?.pdfPointer(at: event.locationInWindow, option: event.modifierFlags.contains(.option)) ?? .arrow).set() }
        override func mouseMoved(with event: NSEvent) { point(event) }
        override func cursorUpdate(with event: NSEvent) { point(event) }

        override func mouseDown(with event: NSEvent) {
            if controller?.view?.pickPDFText(with: event) == true { return }
            controller?.pdf?.clear()
            super.mouseDown(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? { controller?.view?.pdfMenu(for: event) ?? super.menu(for: event) }
    }
}
