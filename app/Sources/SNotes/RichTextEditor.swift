import AppKit
import SamsungNotesKit
import SwiftUI

/// What the formatting bar shows for the selection.
struct FormatState: Equatable {
    var bold = false, italic = false, underline = false, strikethrough = false
    var color: UInt32 = 0xFF25_2525
    var highlight: UInt32 = 0
    var size: Double = 12
    var mark: NoteText.Mark = .none
    var alignment = 0
    var indent = 0
    var hasSelection = false
}

/// A picture set in the text.
final class PictureAttachment: NSTextAttachment {
    var objectID = ""
}

final class PictureCell: NSTextAttachmentCell {
    var picture: CGImage?
    /// The room the picture takes in the text: its own size, or, turned, the box around its corners.
    var size = NSSize(width: 40, height: 40)
    /// The picture's own size, and the angle it is turned by, in degrees clockwise.
    var pictureSize = NSSize(width: 40, height: 40)
    var rotation = 0.0

    /// Alone in its paragraph: the paragraph's line is then exactly as high as this room, and
    /// the picture is drawn into the line, not onto its baseline.
    var alone = false

    override func cellSize() -> NSSize { size }
    override func cellBaselineOffset() -> NSPoint { .zero }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        var frame = cellFrame
        if alone, let view = controlView as? NSTextView, charIndex < (layoutManager.textStorage?.length ?? 0) {
            let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: charIndex), effectiveRange: nil)
            frame.origin.y = line.minY + view.textContainerOrigin.y
            frame.size.height = line.height
        }
        draw(withFrame: frame, in: controlView)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if let picture {
            // In the middle of its room, turned about its own middle. The text view's y points
            // down (so a positive angle turns clockwise); pictures are drawn y up.
            context.translateBy(x: cellFrame.midX, y: cellFrame.midY)
            if rotation != 0 { context.rotate(by: rotation * .pi / 180) }
            context.translateBy(x: -pictureSize.width / 2, y: pictureSize.height / 2)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(picture, in: CGRect(origin: .zero, size: pictureSize))
        } else {
            context.setFillColor(NSColor.quaternaryLabelColor.cgColor)
            context.addPath(CGPath(roundedRect: cellFrame, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.fillPath()
        }
        context.restoreGState()
    }
}

/// Draws the marks of list paragraphs: they are not characters of the text.
final class MarkLayoutManager: NSLayoutManager {
    weak var controller: TextController?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        // Text is laid out and drawn on the main thread.
        MainActor.assumeIsolated { drawMarks(glyphsToShow, at: origin) }
    }

    @MainActor private func drawMarks(_ glyphsToShow: NSRange, at origin: NSPoint) {
        guard let controller, let storage = textStorage else { return }
        let string = storage.string as NSString
        var lines: [(location: Int, rect: NSRect, baseline: CGFloat)] = []
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphs, _ in
            let characters = self.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard characters.location == 0 || string.character(at: characters.location - 1) == 0x0A else { return }
            lines.append((characters.location, rect.offsetBy(dx: origin.x, dy: origin.y), rect.minY + self.location(forGlyphAt: glyphs.location).y + origin.y))
        }
        for line in lines { controller.drawMark(paragraphStartingAt: line.location, line: line.rect, baseline: line.baseline) }
        // The empty line after a final line break has no glyphs of its own.
        if extraLineFragmentTextContainer != nil, NSMaxRange(glyphsToShow) >= numberOfGlyphs, string.length > 0 {
            controller.drawMark(paragraphStartingAt: string.length, line: extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y), baseline: nil)
        }
    }
}

/// The text's column, page by page: a line, or a picture, that does not fit in what is left of
/// a page is set at the top of the next. Nothing is laid across the break between two pages.
final class PagedTextContainer: NSTextContainer {
    /// The height text has on a page, and the step from one page's text to the next's, in points.
    var room: CGFloat = 0
    var stride: CGFloat = 0
    /// Where each page's text begins and how high it may be, in a note whose pages are not all
    /// of one height; empty when they are.
    var tops: [CGFloat] = []
    var rooms: [CGFloat] = []

    private var paged: Bool { room > 1 && stride > room }

    /// The page a height lies on, with where that page's text begins, how high it may be, and where the next page's begins.
    func page(at y: CGFloat) -> (index: Int, top: CGFloat, room: CGFloat, next: CGFloat) {
        guard !tops.isEmpty, tops.count == rooms.count else {
            let page = (max(y, 0) / max(stride, 1)).rounded(.down)
            return (Int(page), page * stride, room, (page + 1) * stride)
        }
        // Past the note's last page the pages go on as the last one does.
        let step = tops.count > 1 ? tops[tops.count - 1] - tops[tops.count - 2] : stride
        var index = 0
        while index + 1 < tops.count + 4_000, top(index + 1, step) <= y + 0.5 { index += 1 }
        return (index, top(index, step), rooms[min(index, rooms.count - 1)], top(index + 1, step))
    }

    private func top(_ index: Int, _ step: CGFloat) -> CGFloat {
        index < tops.count ? tops[index] : tops[tops.count - 1] + CGFloat(index - tops.count + 1) * max(step, 1)
    }

    override var isSimpleRectangularTextContainer: Bool { !paged }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int, writingDirection baseWritingDirection: NSWritingDirection, remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = proposedRect
        if paged, rect.minY.isFinite, rect.height.isFinite {
            let page = page(at: rect.minY)
            // Past the foot of this page's room: on to the next page, unless it already stands
            // at the top of one and is simply taller than a page.
            if rect.maxY > page.top + page.room + 0.5, rect.minY > page.top + 0.5 { rect.origin.y = page.next }
        }
        return super.lineFragmentRect(forProposedRect: rect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
    }
}

final class NoteTextView: NSTextView {
    weak var controller: TextController?

    // The pictures' places are found from the laid-out text: again whenever the view comes on
    // screen or changes size, not only when the text changes.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.layoutChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        if old != newSize { controller?.layoutChanged() }
    }

    // Only plain text comes in from outside: the note's own formatting is the only formatting.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// A picture file, or picture data that comes without any text, is taken as a picture.
    private func holdsPicture(_ board: NSPasteboard) -> Bool {
        if board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: ["public.image"]]) { return true }
        return board.string(forType: .string) == nil && board.availableType(from: [.png, PictureFile.jpegType, .tiff]) != nil
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if isEditable, holdsPicture(board), let controller, controller.pastePicture(from: board, at: nil) { return }
        pasteAsPlainText(sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + [.fileURL, .png, PictureFile.jpegType, .tiff] }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isEditable && holdsPicture(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isEditable && holdsPicture(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable, holdsPicture(sender.draggingPasteboard), let controller else { return super.performDragOperation(sender) }
        // The picture goes in where it was dropped.
        return controller.pastePicture(from: sender.draggingPasteboard, at: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)))
    }

    /// True where something else lies over the text at the pointer, so that the pointer's shape
    /// is not the text's to choose: a picture's grip chooses its own, a field typed into keeps
    /// the text pointer, and over anything else (a bar of buttons floating over the note, an
    /// open sticky note's strip) it is an arrow, not the I-beam of the text beneath.
    private func isCovered(_ event: NSEvent) -> Bool {
        guard let over = PointerOver.view(event, in: window), over !== self, !over.isDescendant(of: self) else { return false }
        if !(over is PictureGripView), !(over is PointerOwner), !PointerOver.isTextInput(over) { NSCursor.arrow.set() }
        return true
    }

    /// The pointer over a page of a PDF, when it is not the text view's usual one: with ⌥ held
    /// over the PDF's text it is the text pointer, for ⌥ and a drag pick that text; where the
    /// note has no text of its own it is otherwise an arrow, for the PDF is paper, and an
    /// I-beam would say its text could be picked just so. Nil where the text view decides.
    func pdfPointer(at location: NSPoint, option: Bool) -> NSCursor? {
        guard let controller else { return nil }
        let point = convert(location, from: nil)
        guard let place = controller.pagePlace(point), let pdf = controller.pdf, pdf.isPDF(place.page) else { return nil }
        if option, pdf.hasText(page: place.page, at: place.point) { return .iBeam }
        return controller.hasText(at: point) ? nil : .arrow
    }

    override func mouseMoved(with event: NSEvent) {
        if isCovered(event) { return }
        if let pointer = pdfPointer(at: event.locationInWindow, option: event.modifierFlags.contains(.option)) { pointer.set(); return }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isCovered(event) { return }
        if let pointer = pdfPointer(at: event.locationInWindow, option: event.modifierFlags.contains(.option)) { pointer.set(); return }
        super.cursorUpdate(with: event)
    }

    // ⌥ pressed or let go with the pointer at rest: its shape follows at once.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window, let over = window.contentView?.hitTest(window.mouseLocationOutsideOfEventStream), over === self || over is PDFTextCatcher.CatcherView else { return }
        pdfPointer(at: window.mouseLocationOutsideOfEventStream, option: event.modifierFlags.contains(.option))?.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.pointerDown()
        if let controller, controller.clickedMark(at: point) { return }
        if let controller, event.clickCount == 1, !controller.hasText(at: point), let place = controller.pagePlace(point), controller.onPageClick?(place.page, place.point) == true { return }
        if pickPDFText(with: event) { return }
        controller?.pdf?.clear()
        super.mouseDown(with: event)
    }

    /// The pointer went down with ⌥ held, here or on a page's edge beside the text: when it is
    /// on text of the PDF under the page, that text is picked, as in Preview, for as long as
    /// the button is held. False without ⌥, or when there is nothing of the PDF's there.
    func pickPDFText(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option), let controller, let pdf = controller.pdf, let place = controller.pagePlace(convert(event.locationInWindow, from: nil)),
              pdf.begin(page: place.page, at: place.point, clicks: event.clickCount) else { return false }
        // The keys stay with the text, so that Copy comes here.
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        // Held at the window's edge, the pages go on scrolling under the pointer, and the picking with them.
        NSEvent.startPeriodicEvents(afterDelay: 0.15, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var last = event
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]), next.type != .leftMouseUp {
            if next.type == .leftMouseDragged { last = next } else if last.type != .leftMouseDragged { continue }
            autoscroll(with: last)
            if let to = controller.pagePlace(convert(last.locationInWindow, from: nil)) { pdf.drag(page: to.page, to: to.point) }
        }
        return true
    }

    /// The menu for what is picked of the PDF, when the pointer is on it.
    func pdfMenu(for event: NSEvent) -> NSMenu? {
        guard let controller, let pdf = controller.pdf, let place = controller.pagePlace(convert(event.locationInWindow, from: nil)), pdf.isPicked(page: place.page, at: place.point) else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "").target = self
        return menu
    }

    // What is picked of the PDF is copied when nothing of the note's own text is.
    override func copy(_ sender: Any?) {
        if selectedRange().length == 0, controller?.pdf?.copy() == true { return }
        super.copy(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), selectedRange().length == 0, controller?.pdf?.isEmpty == false { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? { pdfMenu(for: event) ?? super.menu(for: event) }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        controller?.pdf?.clear()
        super.insertText(string, replacementRange: replacementRange)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let controller, isEditable else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch key {
            case "b": controller.toggle(NoteText.bold); return true
            case "i": controller.toggle(NoteText.italic); return true
            case "u": controller.toggle(NoteText.underline); return true
            case "z": window?.undoManager?.undo(); return true
            default: break
            }
        } else if flags == [.command, .shift] {
            switch key {
            case "l": controller.setMark(.checkbox(checked: false)); return true     // checklist, as in Notes
            case "u": controller.toggleTicks(); return true                          // tick or untick
            case "z": window?.undoManager?.redo(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { controller?.isFocused = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { controller?.isFocused = false }
        return resigned
    }
}

/// Keeps a text view and the note's stored text in step. The stored text is the truth: every
/// edit in the view is applied to it, and what the view shows is drawn from it, so text read
/// from a note and not touched goes back exactly as it came.
@MainActor @Observable
final class TextController: NSObject, NSTextViewDelegate {
    struct Metrics: Equatable {
        /// Points on screen per unit of text size.
        var scale: CGFloat = 1
        var dark = false
        /// The height text has on a page, and the step from one page's text to the next's, in
        /// points. Zero for one unbroken column.
        var pageRoom: CGFloat = 0
        var pageStride: CGFloat = 0
        /// The same page by page, for a note whose pages are not all of one height; empty when they are.
        var pageTops: [CGFloat] = []
        var pageRooms: [CGFloat] = []
        /// Where the text's column begins on the pages, in points, and the note's units for
        /// one point: with them a place in the text view is a place on a page.
        var left: CGFloat = 0
        var top: CGFloat = 0
        var unit: CGFloat = 1
    }

    @ObservationIgnored private(set) var text = NoteText(hasSection: true)
    @ObservationIgnored weak var view: NoteTextView?
    @ObservationIgnored let storage = NSTextStorage()
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called after the text has been laid out anew (a different text, a different size).
    @ObservationIgnored var onRelayout: (() -> Void)?
    /// A picture set in the text, by its object's id: the picture, its size in units of text
    /// size, and the angle it is turned by.
    /// `around` is room the text leaves beyond the picture's own size (a table has some).
    @ObservationIgnored var picture: ((String) -> (image: CGImage?, size: CGSize, rotation: Double, around: CGSize))?
    /// Takes a picture pasted into the text. Returns false when it cannot be used.
    @ObservationIgnored var onPastePicture: ((NSPasteboard, Int) -> Bool)?
    @ObservationIgnored private(set) var metrics = Metrics()
    /// The text of a PDF under the note's pages, which the pointer can pick, and where the pages lie.
    @ObservationIgnored var pdf: PDFTextSelection?
    /// A press on a page where the note has no text of its own: true when something there took it (a tape).
    @ObservationIgnored var onPageClick: ((Int, CGPoint) -> Bool)?
    /// Calculations are answered where they are typed ("10+5=" becomes "10+5=15").
    @ObservationIgnored var calculates = true
    /// Puts a calculation written in words into plain arithmetic; nil when it is none.
    @ObservationIgnored var translate: ((String) async -> String?)?
    /// The colour a result is written in: by it a result is known as one, and kept up when the calculation changes.
    static let resultColor: UInt32 = 0xFFE0_9A00
    @ObservationIgnored var pages: NoteLayout?
    var state = FormatState()
    var isFocused = false
    /// Where each picture set in the text lies in the view, in points.
    private(set) var pictureFrames: [String: CGRect] = [:]
    /// The picture that is picked: Delete takes it away instead of a character.
    @ObservationIgnored var pickedObject: String?
    /// Called when the pointer is pressed in the text.
    @ObservationIgnored var onPointerDown: (() -> Void)?
    /// Called with the page the caret, or a place that was found, lies on: a note shown a page
    /// at a time turns to it.
    @ObservationIgnored var onPage: ((Int) -> Void)?

    /// A style chosen at the caret, for what is typed next.
    @ObservationIgnored private var pending: [String: String?] = [:]
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var typing = false
    /// Where the last typed character ended and when: letters typed in a row are undone together.
    @ObservationIgnored private var lastTyping: (end: Int, at: Date)?
    @ObservationIgnored private var attachments: [String: PictureAttachment] = [:]
    @ObservationIgnored private var starts: [Int] = [0]
    @ObservationIgnored private static let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static let defaultSize = 12.0

    // MARK: Loading

    /// Shows another text, forgetting what could be undone in the old one.
    func set(_ new: NoteText) {
        pending = [:]
        attachments = [:]
        forgetUndo()
        show(new, caret: false)
        refreshState()
    }

    /// Takes over a text that differs from the one on screen only by what saving tidied in it.
    func adopt(_ new: NoteText) {
        guard new != text else { return }
        show(new, caret: false)
        refreshState()
    }

    /// The window's undo manager: the text view has none of its own, undo here is by whole texts.
    private var undoManager: UndoManager? { view?.window?.undoManager }

    func forgetUndo() {
        lastTyping = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    /// The stretch in which two strings differ, as UTF-16 offsets that never cut a pair in two.
    private static func difference(_ old: [UInt16], _ new: [UInt16], caretEnd: Int?) -> (replaced: Range<Int>, inserted: Range<Int>) {
        var suffix = 0
        let most = min(old.count, new.count, caretEnd.map { max(new.count - $0, 0) } ?? Int.max)
        while suffix < most, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        // The unchanged tail must not begin with the second half of a pair.
        if suffix > 0, (0xDC00...0xDFFF).contains(new[new.count - suffix]) { suffix -= 1 }
        var prefix = 0
        let limit = min(old.count, new.count) - suffix
        while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
        // Nor the unchanged head end with the first half of one.
        if prefix > 0, (0xD800...0xDBFF).contains(old[prefix - 1]) { prefix -= 1 }
        return (prefix..<(old.count - suffix), prefix..<(new.count - suffix))
    }

    /// Makes the view show a text: only what differs is replaced in it.
    private func show(_ new: NoteText, caret: Bool) {
        let old = Array(storage.string.utf16), wanted = Array(new.string.utf16)
        text = new
        let change = TextController.difference(old, wanted, caretEnd: nil)
        applying = true
        if !change.replaced.isEmpty || !change.inserted.isEmpty {
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: change.replaced.lowerBound, length: change.replaced.count), with: String(decoding: wanted[change.inserted], as: UTF16.self))
            storage.endEditing()
        }
        applying = false
        restyle()
        if caret, let view { view.setSelectedRange(NSRange(location: min(change.inserted.upperBound, storage.length), length: 0)) }
    }

    func update(_ new: Metrics) {
        guard new != metrics else { return }
        metrics = new
        attachments = [:]
        applyPaging()
        restyle()
    }

    /// Tells the text's column where the pages are.
    private func applyPaging() {
        guard let container = view?.textContainer as? PagedTextContainer else { return }
        guard container.room != metrics.pageRoom || container.stride != metrics.pageStride || container.tops != metrics.pageTops || container.rooms != metrics.pageRooms else { return }
        container.room = metrics.pageRoom
        container.stride = metrics.pageStride
        container.tops = metrics.pageTops
        container.rooms = metrics.pageRooms
        view?.layoutManager?.textContainerChangedGeometry(container)
    }

    @ObservationIgnored private var layoutNoticePending = false

    /// The text was laid out anew, or the view it is in changed: the pages to show and the
    /// pictures' places are worked out again, once, after whatever is going on now.
    func layoutChanged() {
        guard !layoutNoticePending else { return }
        layoutNoticePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutNoticePending = false
            self.onRelayout?()
            self.updatePictureFrames()
        }
    }

    func focus() {
        guard let view, view.window?.firstResponder !== view else { return }
        view.window?.makeFirstResponder(view)
    }

    var selection: Range<Int> {
        guard let range = view?.selectedRange(), range.location != NSNotFound else { return text.length..<text.length }
        let lower = min(max(range.location, 0), text.length)
        return lower..<min(lower + range.length, text.length)
    }

    /// The picture objects still set in the text.
    var objectIDs: [String] { text.objectIDs }

    // MARK: Drawing the text from the stored text

    private func font(size: CGFloat, bold: Bool, italic: Bool, name: String?) -> NSFont {
        var font = NSFont.systemFont(ofSize: size)
        if let name, !name.isEmpty, let named = NSFont(name: name, size: size) ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) { font = named }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty, let styled = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) { font = styled }
        return font
    }

    private func color(_ argb: UInt32, adapt: Bool = true) -> NSColor {
        var value = argb
        // Near-black text is shown light on the dark page, as the pages themselves are.
        if metrics.dark, adapt, max((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF) < 0x60 { value = (argb & 0xFF00_0000) | 0x00EC_ECEC }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: CGFloat((value >> 24) & 0xFF) / 255)
    }

    private func attributes(_ run: TextRun) -> [NSAttributedString.Key: Any] {
        let size = CGFloat(run.fontSize ?? TextController.defaultSize) * metrics.scale
        var out: [NSAttributedString.Key: Any] = [
            .font: font(size: size, bold: run.bold, italic: run.italic, name: run.fontName),
            // Highlighted text keeps its own colour: the highlight is the paper it stands on.
            .foregroundColor: color(run.color ?? 0xFF25_2525, adapt: (run.background ?? 0) >> 24 == 0),
        ]
        if run.underline { out[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.strikethrough { out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let background = run.background, background >> 24 != 0 { out[.backgroundColor] = color(background, adapt: false) }
        return out
    }

    private func size(ofParagraph index: Int) -> CGFloat {
        let range = text.paragraphRange(index)
        let at = range.isEmpty ? max(range.lowerBound - 1, 0) : range.lowerBound
        return CGFloat(text.property(NoteText.fontSize, at: at).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) } ?? TextController.defaultSize) * metrics.scale
    }

    /// The size of the largest text of each paragraph, in units of text size; -1 for a paragraph
    /// that holds a picture, 0 for one with nothing in it yet.
    @ObservationIgnored private var lineSizes: [Double] = []
    /// The picture or table that is alone in a paragraph, by paragraph; nil for any other paragraph.
    @ObservationIgnored private var loneObjects: [String?] = []

    private func measureLines() {
        var sizes = Array(repeating: 0.0, count: max(starts.count, 1))
        var pictures = Array(repeating: [String](), count: sizes.count)
        var letters = Array(repeating: 0, count: sizes.count)
        var index = 0
        for run in text.runs {
            let size = run.fontSize ?? TextController.defaultSize
            for unit in run.text.utf16 {
                if unit == 0xFFFC { pictures[index].append(run.objectID ?? "") } else { sizes[index] = max(sizes[index], size) }
                if unit != 0xFFFC, unit != 0x0A { letters[index] += 1 }
                // For the text view a paragraph runs through the line break that ends it.
                if unit == 0x0A { index = min(index + 1, sizes.count - 1) }
            }
        }
        for index in sizes.indices where !pictures[index].isEmpty { sizes[index] = -1 }
        lineSizes = sizes
        loneObjects = sizes.indices.map { pictures[$0].count == 1 && letters[$0] == 0 && !pictures[$0][0].isEmpty ? pictures[$0][0] : nil }
    }

    private func indentStep(_ size: CGFloat) -> CGFloat { size * 1.4 }
    private func markWidth(_ size: CGFloat) -> CGFloat { size * 1.5 }

    private func paragraphStyle(_ index: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let size = size(ofParagraph: index)
        style.alignment = [.left, .right, .center, .justified][min(max(text.alignment(index), 0), 3)]
        // From one line to the next is 1.35 times the size of the paragraph's largest text,
        // exactly, as in the library and in Samsung's clients (whose rulings are made to that
        // measure). A picture's paragraph is as high as the picture.
        let measured = lineSizes[safe: index] ?? 0
        if measured >= 0 {
            let largest = measured > 0 ? measured : Double(size / max(metrics.scale, 0.0001))
            let height = CGFloat(largest * NoteRenderer.linePitch) * metrics.scale
            style.minimumLineHeight = height
            style.maximumLineHeight = height
        } else if index < loneObjects.count, let id = loneObjects[index], let cell = attachment(id).attachmentCell as? PictureCell {
            // Alone in its paragraph: exactly its room, as in the library and in Samsung's clients.
            cell.alone = true
            style.minimumLineHeight = cell.size.height
            style.maximumLineHeight = cell.size.height
        }
        let head = CGFloat(text.indentLevel(index)) * indentStep(size) + (text.mark(index) == .none ? 0 : markWidth(size))
        style.firstLineHeadIndent = head
        style.headIndent = head
        return style
    }

    private func attachment(_ id: String) -> PictureAttachment {
        if let known = attachments[id] { return known }
        let found = picture?(id)
        let cell = PictureCell()
        cell.picture = found?.image
        let own = NSSize(width: (found?.size.width ?? 40) * metrics.scale, height: (found?.size.height ?? 40) * metrics.scale)
        cell.pictureSize = own
        cell.rotation = found?.rotation ?? 0
        var size = NoteObject.turned(own, by: cell.rotation)
        size.width += (found?.around.width ?? 0) * metrics.scale
        size.height += (found?.around.height ?? 0) * metrics.scale
        // Never more room than the column is wide or a page is high, so that it fits on a page.
        if let width = view?.textContainer?.size.width, width > 20, width < 100_000 { size.width = min(size.width, width) }
        if metrics.pageRoom > 20 { size.height = min(size.height, metrics.pageRoom - 2) }
        cell.size = size
        let attachment = PictureAttachment()
        attachment.objectID = id
        attachment.attachmentCell = cell
        attachments[id] = attachment
        return attachment
    }

    /// A picture whose file has arrived or changed is drawn again.
    func forgetPictures() {
        attachments = [:]
        restyle()
    }

    /// Sets every attribute of the view's text from the stored text.
    func restyle() {
        starts = text.paragraphStarts
        measureLines()
        guard storage.length == text.length else { return }
        applying = true
        storage.beginEditing()
        let whole = NSRange(location: 0, length: storage.length)
        storage.setAttributes([.font: font(size: CGFloat(TextController.defaultSize) * metrics.scale, bold: false, italic: false, name: nil), .foregroundColor: color(0xFF25_2525)], range: whole)
        var offset = 0
        for run in text.runs {
            let length = run.text.utf16.count
            storage.addAttributes(attributes(run), range: NSRange(location: offset, length: length))
            offset += length
        }
        for span in text.spans where span.key == NoteText.objectKey && span.end - span.start == 1 && span.start < storage.length {
            guard let id = span.value.split(separator: ",").first.map(String.init) else { continue }
            storage.addAttribute(.attachment, value: attachment(id), range: NSRange(location: span.start, length: 1))
        }
        for known in attachments.values { (known.attachmentCell as? PictureCell)?.alone = false }
        for index in 0..<starts.count {
            // A paragraph for the text view runs from after its line break through the next one.
            let from = index == 0 ? 0 : starts[index] + 1
            let to = index + 1 < starts.count ? starts[index + 1] + 1 : storage.length
            if to > from { storage.addAttribute(.paragraphStyle, value: paragraphStyle(index), range: NSRange(location: from, length: to - from)) }
        }
        if storage.length < 40_000, let detector = TextController.links {
            for match in detector.matches(in: storage.string, range: whole) {
                if let url = match.url { storage.addAttribute(.link, value: url, range: match.range) }
            }
        }
        storage.endEditing()
        applying = false
        setTypingAttributes()
        // What is being looked for is marked in the text as it now is.
        if !query.isEmpty { refind(keepPlace: true) }
        view?.needsDisplay = true
        layoutChanged()
    }

    /// Finds where the pictures lie now, for the handles drawn over them.
    func updatePictureFrames() {
        guard let view, view.window != nil, let layout = view.layoutManager, let container = view.textContainer, storage.length > 0 else {
            if !pictureFrames.isEmpty { pictureFrames = [:] }
            return
        }
        var found: [String: CGRect] = [:]
        let origin = view.textContainerOrigin
        for span in text.spans where span.key == NoteText.objectKey && span.end - span.start == 1 && span.start < storage.length {
            guard let id = span.value.split(separator: ",").first.map(String.init) else { continue }
            let glyph = layout.glyphIndexForCharacter(at: span.start)
            var rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            if rect.width > 1, rect.height > 1 { found[id] = rect }
        }
        if found != pictureFrames { pictureFrames = found }
    }

    /// Moves a picture set in the text to where it was dropped: before or after the paragraph
    /// under its top edge, and to the left, middle or right of the column by where its middle
    /// lies. `frame` is the dropped picture's frame in the view's points.
    func moveObject(_ id: String, droppedFrame frame: CGRect) {
        guard let view, let layout = view.layoutManager, let container = view.textContainer,
              let span = text.spans.first(where: { $0.key == NoteText.objectKey && $0.value.hasPrefix(id) }), storage.length > 0 else { return }
        let string = storage.string as NSString
        let origin = view.textContainerOrigin
        let probe = NSPoint(x: frame.midX - origin.x, y: frame.minY + 6 - origin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: probe, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let character = min(layout.characterIndexForGlyph(at: min(glyph, max(layout.numberOfGlyphs - 1, 0))), string.length - 1)
        let paragraph = string.paragraphRange(for: NSRange(location: character, length: 0))
        let box = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil), in: container)
        // Between paragraphs only: before the one under the picture's top edge, or after it.
        let target = probe.y < box.midY ? paragraph.location : NSMaxRange(paragraph)
        let own = string.paragraphRange(for: NSRange(location: span.start, length: 0))
        let share = (frame.midX - origin.x) / max(container.size.width, 1)
        let alignment = share < 0.34 ? 0 : (share > 0.66 ? 1 : 2)
        let start = span.start
        change("Move Picture") { t in
            if target < own.location || target > NSMaxRange(own) {
                let before = t.length
                _ = t.removeObjects([id])
                var at = target
                if at > start { at -= before - t.length }
                t.insertObject(id: id, at: min(max(at, 0), t.length))
            }
            guard let moved = t.spans.first(where: { $0.key == NoteText.objectKey && $0.value.hasPrefix(id) }) else { return }
            let index = t.paragraphs(touching: moved.start..<(moved.start + 1)).lowerBound
            // A picture sits in a paragraph of its own: not in a list, not indented.
            t.setMark(.none, index)
            t.setIndentLevel(0, index)
            t.setAlignment(alignment, index)
        }
        pictureFrames = [:]
        updatePictureFrames()
    }

    /// Where in the text a picture dropped at `frame` (in the view's points) would be set:
    /// before the paragraph under its top edge, or after it.
    func boundary(forDroppedFrame frame: CGRect) -> Int {
        guard let view, let layout = view.layoutManager, let container = view.textContainer, storage.length > 0 else { return text.length }
        let string = storage.string as NSString
        let origin = view.textContainerOrigin
        let probe = NSPoint(x: frame.midX - origin.x, y: frame.minY + 6 - origin.y)
        layout.ensureLayout(for: container)
        if probe.y > layout.usedRect(for: container).maxY { return string.length }
        let glyph = layout.glyphIndex(for: probe, in: container)
        let character = min(layout.characterIndexForGlyph(at: min(glyph, max(layout.numberOfGlyphs - 1, 0))), string.length - 1)
        let paragraph = string.paragraphRange(for: NSRange(location: character, length: 0))
        let box = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil), in: container)
        if probe.y < box.midY { return paragraph.location }
        // After the paragraph: before its line break, where there is one.
        let end = NSMaxRange(paragraph)
        return end > paragraph.location && string.character(at: end - 1) == 0x0A ? end - 1 : end
    }

    /// Where the text goes on after a picture set in it.
    func offset(afterObject id: String) -> Int? {
        text.spans.first { $0.key == NoteText.objectKey && $0.value.split(separator: ",").first.map(String.init) == id }?.end
    }

    /// Puts plain text into the note's text at a place, as if typed there.
    func insert(_ string: String, at offset: Int, name: String = "Paste") {
        let at = min(max(offset, 0), text.length)
        change(name) { $0.replace(at..<at, with: string) }
        view?.setSelectedRange(NSRange(location: min(at + string.utf16.count, storage.length), length: 0))
    }

    /// Sets or removes a picture's place in the text without a step to undo: for a change that
    /// was written to the note already and that undoing the text could not take back.
    func settle(object id: String, at offset: Int?) {
        // Whatever comes of it, no earlier text may come back: it would not have the picture where the note now has it.
        forgetUndo()
        var after = text
        if let offset {
            guard !after.objectIDs.contains(id) else { return }
            after.insertObject(id: id, at: min(max(offset, 0), after.length))
        } else if !after.removeObjects([id]) {
            return
        }
        show(after, caret: false)
        refreshState()
        onChange?()
    }

    // MARK: Finding

    /// The places where the text holds what is being looked for, and which of them is shown.
    private(set) var found: [NSRange] = []
    private(set) var foundIndex = 0
    @ObservationIgnored private var query = ""

    /// Looks for a piece of text, whatever its case and accents, marks every place it stands
    /// and shows the first one at or after the caret.
    func find(_ wanted: String) {
        query = wanted
        refind(keepPlace: false)
        showFound()
    }

    private func refind(keepPlace: Bool) {
        clearFoundMarks()
        guard !query.isEmpty else {
            if !found.isEmpty { found = [] }
            foundIndex = 0
            return
        }
        let string = storage.string as NSString
        var ranges: [NSRange] = []
        var rest = NSRange(location: 0, length: string.length)
        while rest.length > 0, ranges.count < 5_000 {
            let hit = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: rest)
            if hit.location == NSNotFound || hit.length == 0 { break }
            ranges.append(hit)
            rest = NSRange(location: NSMaxRange(hit), length: string.length - NSMaxRange(hit))
        }
        if keepPlace {
            foundIndex = min(foundIndex, max(ranges.count - 1, 0))
        } else {
            let caret = selection.lowerBound
            foundIndex = ranges.firstIndex { $0.location >= caret } ?? 0
        }
        found = ranges
        markFound()
    }

    private func clearFoundMarks() {
        guard let layout = view?.layoutManager else { return }
        let whole = NSRange(location: 0, length: storage.length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
    }

    private func markFound() {
        guard let layout = view?.layoutManager else { return }
        for (index, range) in found.enumerated() where NSMaxRange(range) <= storage.length {
            let current = index == foundIndex
            layout.addTemporaryAttribute(.backgroundColor, value: current ? NSColor.systemOrange : NSColor.systemYellow.withAlphaComponent(0.55), forCharacterRange: range)
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.black, forCharacterRange: range)
        }
    }

    /// Brings the current place into view.
    private func showFound() {
        guard let view, found.indices.contains(foundIndex) else { return }
        let range = found[foundIndex]
        guard NSMaxRange(range) <= storage.length else { return }
        showPage(of: range)
        // After the page has been turned, where the note is shown a page at a time.
        DispatchQueue.main.async {
            view.scrollRangeToVisible(range)
            view.showFindIndicator(for: range)
        }
    }

    /// Goes on to the next place (or, with -1, back to the one before), round and round.
    func findStep(_ step: Int) {
        guard !found.isEmpty else { return }
        foundIndex = ((foundIndex + step) % found.count + found.count) % found.count
        clearFoundMarks()
        markFound()
        showFound()
    }

    /// Done looking: the marks go, and the caret is left at the place last shown.
    func endFind() {
        if let view, found.indices.contains(foundIndex), NSMaxRange(found[foundIndex]) <= storage.length { view.setSelectedRange(found[foundIndex]) }
        query = ""
        refind(keepPlace: false)
    }

    /// A press in the text: nothing picked there any more.
    fileprivate func pointerDown() { onPointerDown?() }

    /// A place in the text view as a place on a page of the note: the page, and the place in
    /// the page's own units. `pages` says which page lies how far down the note.
    func pagePlace(_ point: CGPoint) -> (page: Int, point: CGPoint)? {
        guard let pages, metrics.unit > 0 else { return nil }
        let x = Double(point.x + metrics.left) * Double(metrics.unit), y = Double(point.y + metrics.top) * Double(metrics.unit)
        let page = pages.page(at: y)
        let rect = pages.pageRect(page)
        guard y >= rect.minY, y <= rect.maxY else { return nil }
        return (page, CGPoint(x: x, y: y - rect.minY))
    }

    /// True where the note's own text has a letter (or a picture set in it) under the pointer.
    func hasText(at point: CGPoint) -> Bool {
        guard let view, let layout = view.layoutManager, let container = view.textContainer, storage.length > 0 else { return false }
        let origin = view.textContainerOrigin
        let inside = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layout.glyphIndex(for: inside, in: container)
        guard glyph < layout.numberOfGlyphs else { return false }
        return layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -2, dy: -1).contains(inside)
    }
    /// The height of the laid-out text in text units (the units of margins and sizes), or nil
    /// while no view on screen can be asked.
    var usedTextHeight: Double? {
        guard let view, view.window != nil, let container = view.textContainer, let layout = view.layoutManager, metrics.scale > 0 else { return nil }
        layout.ensureLayout(for: container)
        return Double(layout.usedRect(for: container).height) / Double(metrics.scale)
    }

    private func setTypingAttributes() {
        guard let view else { return }
        let caret = selection.lowerBound
        var run = TextRun(text: "")
        let at = max(caret - 1, 0)
        run.fontSize = text.property(NoteText.fontSize, at: at).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        run.color = text.property(NoteText.foreground, at: at).flatMap { Int32($0) }.map { UInt32(bitPattern: $0) }
        run.bold = state.bold; run.italic = state.italic; run.underline = state.underline; run.strikethrough = state.strikethrough
        var attributes = attributes(run)
        attributes[.paragraphStyle] = paragraphStyle(text.paragraphs(touching: caret..<caret).lowerBound)
        view.typingAttributes = attributes
    }

    // MARK: Marks

    private func paragraphIndex(startingAt location: Int) -> Int {
        if location == 0 { return 0 }
        // Paragraph k starts at its line break, which is the character before its first.
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= location - 1 { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private func markRect(paragraph index: Int, line: NSRect) -> NSRect {
        let size = size(ofParagraph: index)
        return NSRect(x: line.minX + CGFloat(text.indentLevel(index)) * indentStep(size), y: line.minY, width: markWidth(size), height: max(line.height, size))
    }

    fileprivate func drawMark(paragraphStartingAt location: Int, line: NSRect, baseline: CGFloat?) {
        let index = paragraphIndex(startingAt: location)
        let mark = text.mark(index)
        guard mark != .none else { return }
        let size = size(ofParagraph: index)
        let rect = markRect(paragraph: index, line: line)
        let ink = color(0xFF25_2525)
        switch mark {
        case .none: break
        case .dot, .number:
            var label = "\u{2022}"
            if case .number = mark { label = "\(text.numbers()[index] ?? 1)." }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: ink]
            let font = NSFont.systemFont(ofSize: size)
            let y = (baseline ?? (line.minY + font.ascender)) - font.ascender
            (label as NSString).draw(at: NSPoint(x: rect.minX + (mark == .dot ? size * 0.3 : 0), y: y), withAttributes: attributes)
        case .checkbox(let checked):
            let side = size * 0.92
            let centre = (baseline.map { $0 - size * 0.34 }) ?? (line.minY + size * 0.62)
            let box = NSRect(x: rect.minX + size * 0.06, y: centre - side / 2, width: side, height: side)
            let path = NSBezierPath(roundedRect: box, xRadius: side * 0.24, yRadius: side * 0.24)
            if checked {
                NSColor.controlAccentColor.setFill()
                path.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + side * 0.24, y: box.midY + side * 0.02))
                tick.line(to: NSPoint(x: box.minX + side * 0.43, y: box.maxY - side * 0.28))
                tick.line(to: NSPoint(x: box.maxX - side * 0.22, y: box.minY + side * 0.30))
                tick.lineWidth = max(side * 0.12, 1.2)
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                NSColor.white.setStroke()
                tick.stroke()
            } else {
                ink.withAlphaComponent(0.55).setStroke()
                path.lineWidth = max(side * 0.08, 1)
                path.stroke()
            }
        }
    }

    /// A click on a checkbox ticks or clears it.
    fileprivate func clickedMark(at point: NSPoint) -> Bool {
        guard let view, view.isEditable, let layout = view.layoutManager, let container = view.textContainer, storage.length > 0 else { return false }
        let origin = view.textContainerOrigin
        let inside = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var line = NSRect.zero
        var location = 0
        if layout.extraLineFragmentTextContainer != nil, layout.extraLineFragmentRect.minY <= inside.y, inside.y <= layout.extraLineFragmentRect.maxY {
            line = layout.extraLineFragmentRect
            location = storage.length
        } else {
            let glyph = layout.glyphIndex(for: inside, in: container)
            var glyphs = NSRange()
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
            guard line.minY <= inside.y, inside.y <= line.maxY else { return false }
            location = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
            guard location == 0 || (storage.string as NSString).character(at: location - 1) == 0x0A else { return false }
        }
        let index = paragraphIndex(startingAt: location)
        guard case .checkbox(let checked) = text.mark(index), markRect(paragraph: index, line: line).insetBy(dx: -3, dy: 0).contains(inside) else { return false }
        change(checked ? "Untick" : "Tick") { $0.setMark(.checkbox(checked: !checked), index) }
        return true
    }

    // MARK: Edits made in the view

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        typing = true
        // Typing is working in the text: no picture is picked any more.
        if pickedObject != nil { pickedObject = nil; onPointerDown?() }
        return true
    }

    func textDidChange(_ notification: Notification) {
        defer { typing = false }
        guard !applying, let view else { return }
        let before = text
        let old = Array(text.string.utf16), new = Array(storage.string.utf16)
        // What changed lies before the caret: the same letters after it are not part of the change.
        let selected = view.selectedRange()
        let caretEnd = selected.location == NSNotFound ? new.count : min(NSMaxRange(selected), new.count)
        let change = TextController.difference(old, new, caretEnd: caretEnd)
        guard !change.replaced.isEmpty || !change.inserted.isEmpty else { return }
        let inserted = String(decoding: new[change.inserted], as: UTF16.self)
        text.replace(change.replaced, with: inserted)
        for (key, value) in pending where !change.inserted.isEmpty { text.setProperty(key, value, in: change.inserted) }
        pending = [:]
        // A picture's placeholder that comes in as plain text (pasted back after a cut) names no
        // picture: it is taken out again.
        var strays: [Int] = []
        for offset in change.inserted where new[offset] == 0xFFFC && !text.spans.contains(where: { $0.key == NoteText.objectKey && $0.start == offset }) { strays.append(offset) }
        for offset in strays.reversed() { text.replace(offset..<(offset + 1), with: "") }
        if !text.isEmpty, !text.spans.contains(where: { $0.key != NoteText.objectKey }) {
            // The first text of an empty note: the style new notes have.
            var fresh = NoteText.uniform(text.string, like: nil, body: true)
            fresh.paragraphs = text.paragraphs
            fresh.spans.append(contentsOf: text.spans)
            text = fresh
        }
        text.renumber()

        // Undo goes back to the text as it was, formatting and all. Letters typed one after
        // another within a moment are one step.
        let plainTyping = change.replaced.isEmpty && inserted.utf16.count <= 2 && !inserted.contains("\n") && strays.isEmpty
        if let last = lastTyping, plainTyping, last.end == change.inserted.lowerBound, Date().timeIntervalSince(last.at) < 2 {
            lastTyping = (change.inserted.upperBound, Date())
        } else {
            registerUndo(before, "Typing")
            lastTyping = plainTyping ? (change.inserted.upperBound, Date()) : nil
        }

        // What is typed after a result is not part of the result, and is not written in its colour.
        var recoloured = false
        if !change.inserted.isEmpty, text.property(NoteText.foreground, at: change.inserted.lowerBound) == TextController.resultValue {
            var before = change.inserted.lowerBound - 1
            while before >= 0, text.property(NoteText.foreground, at: before) == TextController.resultValue { before -= 1 }
            text.setProperty(NoteText.foreground, before >= 0 ? text.property(NoteText.foreground, at: before) ?? "-14342875" : "-14342875", in: change.inserted)
            recoloured = true
        }

        if !strays.isEmpty {
            show(text, caret: true)
        } else if !view.hasMarkedText() {
            restyle()
        } else {
            starts = text.paragraphStarts
        }
        refreshState()
        onChange?()
        if !view.hasMarkedText(), strays.isEmpty { calculate(typed: inserted, recoloured: recoloured) }
    }

    // MARK: Calculations

    static let resultValue = String(Int32(bitPattern: resultColor))

    /// The line the caret is on, when it reads "calculation = result": where its "=" stands
    /// and how long the result after it is. A result is one written here (all in the result's
    /// colour), or none yet.
    private func calculation(typed: String) -> (expression: String, equals: Int, result: Range<Int>, before: [String])? {
        let whole = text.string as NSString
        let caret = min(selection.lowerBound, whole.length)
        var line = whole.paragraphRange(for: NSRange(location: caret, length: 0))
        while line.length > 0, [0x0A, 0x0D].contains(Int(whole.character(at: NSMaxRange(line) - 1))) { line.length -= 1 }
        let equals = whole.range(of: "=", options: .backwards, range: line)
        guard equals.location != NSNotFound else { return nil }
        let result = (equals.location + 1)..<NSMaxRange(line)
        if result.isEmpty {
            // Asked for by typing the sign: the caret stands right after it.
            guard typed == "=", caret == equals.location + 1 else { return nil }
        } else {
            guard result.allSatisfy({ text.property(NoteText.foreground, at: $0) == TextController.resultValue }) else { return nil }
        }
        let expression = whole.substring(with: NSRange(location: line.location, length: equals.location - line.location))
        let before = whole.substring(to: line.location).components(separatedBy: .newlines)
        return (expression, equals.location, result, before)
    }

    /// After something was typed: a calculation on the caret's line is answered, or its answer
    /// brought up to date. One in words is first read by the system's language model.
    private func calculate(typed: String, recoloured: Bool) {
        guard calculates, !recoloured, let found = calculation(typed: typed) else { return }
        let names = MathNotes.variables(in: found.before)
        // "total = 3 + 4 =" works out what is named; the name itself is not part of the sum.
        var expression = found.expression
        if let naming = expression.firstIndex(of: "="), MathNotes.isName(expression[..<naming].trimmingCharacters(in: .whitespaces)) { expression = String(expression[expression.index(after: naming)...]) }
        if MathNotes.isCalculation(expression, variables: names), let value = MathNotes.evaluate(expression, variables: names) {
            put(MathNotes.format(value), for: found, caretAfter: typed == "=")
        } else if !found.result.isEmpty {
            // No longer a calculation: its old answer is not left standing as if it were this one's.
            put("", for: found, caretAfter: false)
        } else if typed == "=", let translate, expression.rangeOfCharacter(from: .decimalDigits) != nil, expression.trimmingCharacters(in: .whitespaces).count <= 120 {
            let asked = found.expression
            Task { [weak self] in
                guard let arithmetic = await translate(expression), let self else { return }
                // Only if the line still asks the same thing.
                guard let now = self.calculation(typed: "="), now.expression == asked, now.result.isEmpty,
                      let value = MathNotes.evaluate(arithmetic, variables: MathNotes.variables(in: now.before)) else { return }
                self.put(MathNotes.format(value), for: now, caretAfter: true)
            }
        }
    }

    private func put(_ result: String, for found: (expression: String, equals: Int, result: Range<Int>, before: [String]), caretAfter: Bool) {
        guard (text.string as NSString).substring(with: NSRange(location: found.result.lowerBound, length: found.result.count)) != result else { return }
        let caret = selection.lowerBound
        let start = found.equals + 1, length = result.utf16.count
        change("Calculation") {
            $0.replace(found.result, with: result)
            if length > 0 { $0.setProperty(NoteText.foreground, TextController.resultValue, in: start..<(start + length)) }
        }
        // After the answer when it was just asked for; else where the hand is at work in the calculation.
        view?.setSelectedRange(NSRange(location: caretAfter ? start + length : min(caret, start), length: 0))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applying else { return }
        if !typing { pending = [:] }
        refreshState()
        if !typing { setTypingAttributes() }
        if let view, view.window?.firstResponder === view { showPage(of: view.selectedRange()) }
    }

    /// The page a place in the text lies on, by where it is laid out.
    func page(of range: NSRange) -> Int? {
        guard metrics.pageStride > 1, let view, let layout = view.layoutManager, let container = view.textContainer, range.location != NSNotFound, range.location <= storage.length else { return nil }
        var rect = NSRect.zero
        if range.location >= storage.length {
            layout.ensureLayout(for: container)
            rect = layout.extraLineFragmentTextContainer != nil ? layout.extraLineFragmentRect : layout.usedRect(for: container)
            if layout.extraLineFragmentTextContainer == nil { rect.origin.y = max(rect.maxY - 1, 0); rect.size.height = 1 }
        } else {
            rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        }
        if let paged = container as? PagedTextContainer, !paged.tops.isEmpty { return paged.page(at: rect.midY).index }
        return max(Int((rect.midY / metrics.pageStride).rounded(.down)), 0)
    }

    private func showPage(of range: NSRange) {
        guard let onPage, let page = page(of: range) else { return }
        onPage(page)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let range = selection
        let paragraphs = text.paragraphs(touching: range)
        let index = paragraphs.lowerBound
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return on an empty list line ends the list there.
            guard range.isEmpty, text.paragraphRange(index).isEmpty, text.mark(index) != .none || text.indentLevel(index) > 0 else { return false }
            change("List") { text in
                if text.indentLevel(index) > 0 { text.setIndentLevel(text.indentLevel(index) - 1, index) } else { text.setMark(.none, index) }
            }
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            // With a picture picked, Delete takes the picture away, not a letter.
            if let picked = pickedObject, text.objectIDs.contains(picked) {
                pickedObject = nil
                removeObject(picked)
                return true
            }
            guard selector == #selector(NSResponder.deleteBackward(_:)) else { return false }
            // Backspace at the start of a list line takes its mark off first.
            guard range.isEmpty, range.lowerBound == text.paragraphRange(index).lowerBound, text.mark(index) != .none else { return false }
            change("List") { $0.setMark(.none, index) }
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard paragraphs.contains(where: { text.mark($0) != .none || text.indentLevel($0) > 0 }) else { return false }
            indent(by: 1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            indent(by: -1)
            return true
        default:
            return false
        }
    }

    fileprivate func pastePicture(from board: NSPasteboard, at offset: Int?) -> Bool {
        onPastePicture?(board, min(max(offset ?? selection.lowerBound, 0), text.length)) ?? false
    }

    // MARK: Formatting

    /// Changes the stored text and shows the result; the change can be undone.
    private func change(_ name: String, _ work: (inout NoteText) -> Void) {
        let before = text
        var after = text
        work(&after)
        guard after != before else { return }
        registerUndo(before, name)
        lastTyping = nil
        if after.string == before.string {
            text = after
            restyle()
        } else {
            show(after, caret: true)
        }
        refreshState()
        onChange?()
    }

    private func registerUndo(_ snapshot: NoteText, _ name: String) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { controller in MainActor.assumeIsolated { controller.restore(snapshot, name) } }
        manager.setActionName(name)
    }

    /// Puts the text back as it was at a step, and makes the way forward again a step of its own.
    private func restore(_ snapshot: NoteText, _ name: String) {
        registerUndo(text, name)
        lastTyping = nil
        pending = [:]
        show(snapshot, caret: true)
        refreshState()
        onChange?()
    }

    private func isOn(_ key: String) -> Bool {
        if let chosen = pending[key] { return NoteText.isOn(chosen) }
        let range = selection
        return NoteText.isOn(range.isEmpty ? text.property(key, at: max(range.lowerBound - 1, 0)) : text.property(key, over: range, unset: "False"))
    }

    /// Bold, italic, underline or strikethrough, on or off.
    func toggle(_ key: String) {
        let range = selection
        let on = isOn(key)
        if range.isEmpty {
            pending[key] = on ? .some(nil) : .some("True")
            refreshState()
            return
        }
        change(key.replacingOccurrences(of: "span/", with: "").capitalized) { $0.setProperty(key, on ? nil : "True", in: range) }
    }

    /// A colour, a highlight or a size for the selection, or for what is typed next.
    func set(_ key: String, _ property: String, name: String) {
        let range = selection
        if range.isEmpty {
            pending[key] = .some(property)
            refreshState()
            return
        }
        change(name) { $0.setProperty(key, property, in: range) }
    }

    func setColor(_ argb: UInt32) { set(NoteText.foreground, String(Int32(bitPattern: argb)), name: "Text Colour") }
    func setHighlight(_ argb: UInt32) { set(NoteText.background, String(Int32(bitPattern: argb)), name: "Highlight") }
    func setSize(_ size: Double) { set(NoteText.fontSize, size == size.rounded() ? String(Int(size)) : String(size), name: "Text Size") }

    /// Makes the selected paragraphs a list of this kind, or plain again when they all are one already.
    func setMark(_ mark: NoteText.Mark) {
        let paragraphs = text.paragraphs(touching: selection)
        func same(_ a: NoteText.Mark, _ b: NoteText.Mark) -> Bool {
            switch (a, b) {
            case (.checkbox, .checkbox), (.dot, .dot), (.number, .number), (.none, .none): return true
            default: return false
            }
        }
        let all = paragraphs.allSatisfy { same(text.mark($0), mark) }
        change("List") { text in
            for index in paragraphs {
                if all { text.setMark(.none, index) } else if !same(text.mark(index), mark) { text.setMark(mark, index) }
            }
        }
        // An empty note has no text for the mark to hang on yet; it shows once something is typed.
        view?.needsDisplay = true
    }

    func indent(by step: Int) {
        let paragraphs = text.paragraphs(touching: selection)
        change(step > 0 ? "Indent" : "Outdent") { text in
            for index in paragraphs { text.setIndentLevel(text.indentLevel(index) + step, index) }
        }
    }

    func setAlignment(_ value: Int) {
        let paragraphs = text.paragraphs(touching: selection)
        change("Alignment") { text in for index in paragraphs { text.setAlignment(value, index) } }
    }

    /// Ticks the checklist lines of the selection, or clears them when all are ticked.
    func toggleTicks() {
        let boxes = text.paragraphs(touching: selection).filter { if case .checkbox = text.mark($0) { return true }; return false }
        guard !boxes.isEmpty else { return }
        let all = boxes.allSatisfy { text.mark($0) == .checkbox(checked: true) }
        change(all ? "Untick" : "Tick") { text in for index in boxes { text.setMark(.checkbox(checked: !all), index) } }
    }

    /// Sets a picture's placeholder into the text, on a line of its own.
    func insertObject(_ id: String, at offset: Int, tail: String = "0,0", name: String = "Insert Picture") {
        change(name) { $0.insertObject(id: id, at: offset, tail: tail) }
    }

    /// Takes a picture's place out of the text (the picture itself goes when the text is saved).
    func removeObject(_ id: String) {
        change("Delete Picture") { _ = $0.removeObjects([id]) }
    }

    private func refreshState() {
        let range = selection
        let at = range.isEmpty ? max(range.lowerBound - 1, 0) : range.lowerBound
        var next = FormatState()
        next.bold = isOn(NoteText.bold); next.italic = isOn(NoteText.italic); next.underline = isOn(NoteText.underline); next.strikethrough = isOn(NoteText.strikethrough)
        func value(_ key: String) -> String? { if let chosen = pending[key] { return chosen }; return text.property(key, at: at) }
        next.color = value(NoteText.foreground).flatMap { Int32($0) }.map { UInt32(bitPattern: $0) } ?? 0xFF25_2525
        next.highlight = value(NoteText.background).flatMap { Int32($0) }.map { UInt32(bitPattern: $0) } ?? 0
        next.size = value(NoteText.fontSize).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) } ?? TextController.defaultSize
        let index = text.paragraphs(touching: range).lowerBound
        next.mark = text.mark(index)
        next.alignment = text.alignment(index)
        next.indent = text.indentLevel(index)
        next.hasSelection = !range.isEmpty
        if next != state { state = next }
    }
}

/// Holds the text view and shows a stretch of it: all of it, or, when the note is shown a
/// page at a time, the part that lies on one page. The text view itself always spans every
/// page; here it is moved up by `lift` and cut off at this view's edges, for the eye and for
/// the pointer alike.
final class TextHost: NSView {
    let textView: NoteTextView
    /// How far down the text the shown stretch begins, in points.
    var lift: CGFloat = 0 { didSet { if lift != oldValue { place() } } }
    /// The height of the whole text view: the text's room on all pages.
    var textHeight: CGFloat = 0 { didSet { if textHeight != oldValue { place() } } }

    init(textView: NoteTextView) {
        self.textView = textView
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        let frame = NSRect(x: 0, y: -lift, width: bounds.width, height: max(textHeight, bounds.height + lift, 10))
        if textView.frame != frame { textView.frame = frame }
    }
}

/// The note's text, editable in place over the pages.
struct RichTextEditor: NSViewRepresentable {
    let controller: TextController
    var editable: Bool
    var metrics: TextController.Metrics
    /// The height of the text on all pages, and how far down it the part shown here begins.
    var textHeight: CGFloat
    var lift: CGFloat = 0

    func makeNSView(context: Context) -> TextHost {
        let layout = MarkLayoutManager()
        layout.controller = controller
        controller.storage.layoutManagers.forEach { controller.storage.removeLayoutManager($0) }
        controller.storage.addLayoutManager(layout)
        let container = PagedTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = NoteTextView(frame: .zero, textContainer: container)
        view.controller = controller
        view.delegate = controller
        view.drawsBackground = false
        view.isRichText = true
        view.importsGraphics = false
        view.usesFontPanel = false
        view.usesRuler = false
        // Undo is the controller's: it goes back to whole stored texts, so formatting, list marks and pictures come back too.
        view.allowsUndo = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.insertionPointColor = .controlAccentColor
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        view.setAccessibilityLabel("Note text")
        // The system's Writing Tools (proofread, rewrite, summarise) work on what is picked, in
        // their own panel; what they hand back comes in as plain text, like anything pasted.
        view.writingToolsBehavior = .limited
        view.allowedWritingToolsResultOptions = [.plainText]
        controller.view = view
        controller.update(metrics)
        controller.restyle()
        let host = TextHost(textView: view)
        host.textHeight = textHeight
        host.lift = lift
        return host
    }

    func updateNSView(_ host: TextHost, context: Context) {
        let view = host.textView
        // The same text shown in another place (another page, another layout) is this view's now.
        if controller.view !== view { controller.view = view }
        host.textHeight = textHeight
        host.lift = lift
        if view.isEditable != editable {
            view.isEditable = editable
            view.isSelectable = true
        }
        controller.update(metrics)
    }
}
