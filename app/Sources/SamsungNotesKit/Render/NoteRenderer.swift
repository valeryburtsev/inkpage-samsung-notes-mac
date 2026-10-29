import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where a note's pages lie in the note's own coordinates: page pixels, y down, pages stacked.
public struct NoteLayout: Sendable {
    public let pageWidth: Double
    /// The height of the note's pages; of its first page, where they are not all of one
    /// height (see `height(_:)`). The text is set page by page at this height.
    public let pageHeight: Double
    public let gap: Double
    public private(set) var pageCount: Int
    /// Where each page begins and how high it is, in a note whose pages are not all of one
    /// height: the pages of a PDF keep the PDF's shape. Empty when every page is `pageHeight` high.
    private let tops: [Double]
    private let heights: [Double]

    public init(_ document: NoteDocument) {
        // Sizes come from the service: kept finite and within reason, so no arithmetic on them can trap.
        func sane(_ value: Double, _ fallback: Double, _ range: ClosedRange<Double>) -> Double { value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback }
        pageWidth = sane(document.width, 1080, 16...100_000)
        let first = sane(document.pageHeight, 1527, 16...400_000), between = sane(document.pageGap, 0, 0...10_000)
        pageHeight = first
        gap = between
        pageCount = min(max(document.pages.count, 1), 5_000)
        let own = document.pages.prefix(5_000).map { sane($0.height, first, 16...400_000) }
        if own.contains(where: { abs($0 - first) > 0.01 }) {
            var top = 0.0
            var all: [Double] = []
            for height in own { all.append(top); top += height + between }
            tops = all
            heights = own
        } else {
            tops = []
            heights = []
        }
    }

    /// The layout of the first `shown` pages of a note: the rest, spare pages at the end, are left off.
    public init(_ document: NoteDocument, shown: Int) {
        self.init(document)
        pageCount = min(max(shown, 1), pageCount)
    }

    public var size: CGSize { CGSize(width: pageWidth, height: top(pageCount - 1) + height(pageCount - 1)) }

    /// How high a page is.
    public func height(_ index: Int) -> Double { heights.isEmpty ? pageHeight : heights[min(max(index, 0), heights.count - 1)] }

    /// Where a page begins, from the top of the first.
    public func top(_ index: Int) -> Double {
        guard !tops.isEmpty else { return Double(index) * (pageHeight + gap) }
        if index < tops.count { return tops[max(index, 0)] }
        // Past the last page: on as the last page goes.
        return tops[tops.count - 1] + Double(index - tops.count + 1) * (heights[heights.count - 1] + gap)
    }

    /// The page a place this far down the note is on (the space under a page counts to it).
    public func page(at y: Double) -> Int {
        guard y.isFinite else { return 0 }
        if tops.isEmpty { return min(max(Int(min(max(y / max(pageHeight + gap, 1), 0), 100_000)), 0), pageCount - 1) }
        var found = 0
        for (index, top) in tops.prefix(pageCount).enumerated() where top <= y { found = index }
        return found
    }

    /// How many of a note's pages to show: up to the last one that may hold anything, and at least one.
    ///
    /// Samsung's clients end every note with an empty spare page and do not show it. A page is
    /// left off only when it can be shown to be empty, so that nothing is ever hidden that
    /// someone put there. The check is deliberately narrow: a page counts as holding something
    /// unless *all* of these are true of it and of every page after it:
    /// - it has no objects of any kind, whatever kind this client can or cannot draw;
    /// - it has no drawn area recorded;
    /// - no object placed on a page above it reaches down onto it;
    /// - the note's text does not reach it;
    /// - it is a bare page (see `NotePage.isBare`) that looks like the page before it.
    /// Empty pages between pages that hold something are always shown.
    /// `textBottom` is where the note's text ends, in page units from the top of the first page;
    /// without it, it is measured here.
    public static func shownPageCount(of document: NoteDocument, textBottom: Double? = nil) -> Int {
        let pages = document.pages
        guard pages.count > 1 else { return max(pages.count, 1) }
        let gap = document.pageGap.isFinite ? max(document.pageGap, 0) : 0
        var tops: [Double] = []
        var y = 0.0
        for page in pages {
            tops.append(y)
            y += (page.height.isFinite ? max(page.height, 1) : 1) + gap
        }
        // The last page that a stretch from the top of the document down to `bottom` touches.
        func lastPage(reaching bottom: Double) -> Int {
            var last = 0
            for (index, top) in tops.enumerated() where top < bottom - 0.5 { last = index }
            return last
        }
        var last = 0
        var textEnd = textBottom
        if textEnd == nil { textEnd = TextFlow(document)?.bottom }
        if let textEnd, textEnd.isFinite { last = max(last, lastPage(reaching: textEnd)) }
        for (index, page) in pages.enumerated() {
            // The spare page after the pages of a PDF is a plain page of the note's own height, not of the PDF's.
            let afterPDF = index == pages.count - 1 && index > 0 && pages[index - 1].pdf != nil
            let differs = index > 0 && (afterPDF ? page.lookButHeight != pages[index - 1].lookButHeight : page.look != pages[index - 1].look)
            let holds = !page.objects.isEmpty || page.drawnRect != nil || !page.isBare || differs
            if holds { last = max(last, index) }
            for object in page.objects {
                // Ink and the like lie on their page; a big object may run down onto the next.
                if object.rect.maxY.isFinite { last = max(last, lastPage(reaching: tops[index] + object.rect.maxY)) }
            }
        }
        for object in document.floating {
            let index = min(max(object.pageIndex ?? 0, 0), pages.count - 1)
            last = max(last, index)
            if object.rect.maxY.isFinite { last = max(last, lastPage(reaching: tops[index] + object.rect.maxY)) }
        }
        return min(last + 1, pages.count)
    }
    public func pageRect(_ index: Int) -> CGRect { CGRect(x: 0, y: top(index), width: pageWidth, height: height(index)) }
}

/// Draws notes with Core Graphics and Core Text. All drawing is in the note's coordinates with
/// y pointing down; the caller scales and places it.
public enum NoteRenderer {
    public typealias Images = (String) -> CGImage?

    static func color(_ argb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255, blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }

    public static func luminance(_ argb: UInt32) -> Double {
        (0.2126 * Double((argb >> 16) & 0xFF) + 0.7152 * Double((argb >> 8) & 0xFF) + 0.0722 * Double(argb & 0xFF)) / 255
    }

    /// On a dark page, ink and text that were dark for paper are shown light.
    public static func adapted(_ argb: UInt32, dark: Bool) -> UInt32 {
        // Only near-black turns light: a dark blue or red stays the colour it was written in.
        guard dark, max((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF) < 0x60 else { return argb }
        return (argb & 0xFF00_0000) | 0x00EC_ECEC
    }

    /// A page left plain: white or nearly so. The dark look turns such a page dark; a page
    /// given a colour keeps it in either look.
    static func isPlain(_ argb: UInt32) -> Bool { (argb >> 16) & 0xFF >= 0xF0 && (argb >> 8) & 0xFF >= 0xF0 && argb & 0xFF >= 0xF0 }

    /// True when what is written on a page has to be light to be read: a plain page in the dark
    /// look, or a page whose own colour is dark.
    public static func isDark(_ page: NotePage?, dark: Bool) -> Bool {
        // A page of a PDF is the PDF's own paper in either look, and what is written on it stays as it was written.
        if page?.pdf != nil { return false }
        guard let page, !isPlain(page.background) else { return dark }
        return luminance(page.background) < 0.42
    }

    public static func pageColor(_ page: NotePage?, dark: Bool) -> CGColor {
        if page?.pdf != nil { return color(0xFFFF_FFFF) }
        guard let page, !isPlain(page.background) else { return dark ? CGColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1) : color(page?.background ?? 0xFFFC_FCFC) }
        return color(page.background)
    }

    private final class Documents: @unchecked Sendable {
        let cache = NSCache<NSString, CGPDFDocument>()
        init() { cache.countLimit = 6 }
    }
    private static let documents = Documents()

    /// A page of a PDF document kept with the note, drawn to fill a page of the note.
    private static let pdfLock = NSLock()

    static func drawPDF(_ url: URL, page number: Int, in rect: CGRect, context: CGContext) {
        // One page at a time: several pages of a note are drawn at once, from one document.
        pdfLock.lock(); defer { pdfLock.unlock() }
        var document = documents.cache.object(forKey: url.path as NSString)
        if document == nil, let opened = CGPDFDocument(url as CFURL), !opened.isEncrypted || opened.unlockWithPassword("") {
            documents.cache.setObject(opened, forKey: url.path as NSString)
            document = opened
        }
        // The clients count a document's pages from 0, Core Graphics from 1.
        guard let page = document?.page(at: number + 1) else { return }
        let box = page.getBoxRect(.cropBox)
        let turned = page.rotationAngle % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 1, size.height > 1 else { return }
        let scale = min(rect.width / size.width, rect.height / size.height)
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let target = CGRect(x: rect.midX - size.width * scale / 2, y: rect.minY, width: size.width * scale, height: size.height * scale)
        context.fill(target)
        // PDF pages are drawn y up, in their own points.
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: scale, y: -scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// A page's paper: its colour, the picture or the PDF page under it, its ruling.
    static func drawPaper(_ page: NotePage?, in rect: CGRect, dark: Bool, images: Images, files: ((String) -> URL?)? = nil, context: CGContext) {
        context.setFillColor(pageColor(page, dark: dark))
        context.fill(rect)
        guard let page else { return }
        if let pdf = page.pdf, let url = files?(pdf.file) { drawPDF(url, page: pdf.page, in: rect, context: context) }
        if let hash = page.backgroundImage, let image = images(hash) {
            // Across the page's width, from its top.
            let height = rect.width * CGFloat(image.height) / CGFloat(max(image.width, 1))
            context.saveGState()
            context.clip(to: rect)
            drawImage(image, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height), context: context)
            context.restoreGState()
        }
        page.template?.draw(in: context, page: rect, dark: isDark(page, dark: dark))
    }

    /// From the top of one line of text to the top of the next, in multiples of the text's size.
    public static let linePitch = 1.35

    /// A stretch of text that takes the room of a picture set in the text, so that the lines
    /// after it start below the picture.
    static let objectAttribute = NSAttributedString.Key("SNObjectID")

    static func spacer(_ size: CGSize, id: String) -> NSAttributedString {
        let string = NSMutableAttributedString(attributedString: spacer(size))
        string.addAttribute(objectAttribute, value: id, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Where the pictures set in a text come to lie when it is laid out `width` wide: the
    /// top left corner of each, from the top left of the text.
    public static func objectPositions(_ text: RichText, width: Double, density: Double, objects: [String: CGSize]) -> [String: CGPoint] {
        let string = attributed(text, density: density, dark: false, objects: objects)
        guard string.length > 0, width > 1 else { return [:] }
        let setter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let height = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height + 64
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var out: [String: CGPoint] = [:]
        for (line, origin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let id = attributes[objectAttribute] as? String, out[id] == nil else { continue }
                let ascent = roomAscent(run, in: line)
                let x = origin.x + CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
                out[id] = CGPoint(x: x, y: height - origin.y - ascent)
            }
        }
        return out
    }

    /// How far above its line's baseline the room of a picture begins. In a line set to the
    /// height of the picture alone the baseline lies a little above the line's bottom, and
    /// the room begins at the line's top, not its own height above the baseline.
    static func roomAscent(_ run: CTRun, in line: CTLine) -> CGFloat {
        var own: CGFloat = 0, whole: CGFloat = 0
        CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &own, nil, nil)
        CTLineGetTypographicBounds(line, &whole, nil, nil)
        return min(own, whole)
    }

    static func spacer(_ size: CGSize) -> NSAttributedString {
        let box = UnsafeMutablePointer<CGSize>.allocate(capacity: 1)
        box.initialize(to: size)
        var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1,
                                               dealloc: { $0.assumingMemoryBound(to: CGSize.self).deallocate() },
                                               getAscent: { $0.assumingMemoryBound(to: CGSize.self).pointee.height },
                                               getDescent: { _ in 0 },
                                               getWidth: { $0.assumingMemoryBound(to: CGSize.self).pointee.width })
        guard let delegate = CTRunDelegateCreate(&callbacks, box) else { box.deallocate(); return NSAttributedString() }
        return NSAttributedString(string: "\u{FFFC}", attributes: [NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate])
    }

    /// The text of a run with its paragraphs' marks written in: a dot, a number or a box.
    static func marked(_ run: TextRun, atParagraphStart: inout Bool, counter: inout Int) -> String {
        guard let bullet = run.bullet else {
            if let last = run.text.last { atParagraphStart = last == "\n"; counter = 0 }
            return run.text
        }
        var out = ""
        for character in run.text {
            if character == "\n" { out.append(character); atParagraphStart = true; continue }
            if atParagraphStart {
                switch bullet {
                case .dot: out += "\u{2022}\u{2002}"
                case .number(let given): counter = given ?? counter + 1; out += "\(counter).\u{2002}"
                case .checkbox(let checked): out += checked ? "\u{2611}\u{2002}" : "\u{2610}\u{2002}"
                }
                atParagraphStart = false
            }
            out.append(character)
        }
        return out
    }

    static func attributed(_ text: RichText, density: Double, dark: Bool, defaultSize: Double = 17, objects: [String: CGSize] = [:]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var settings: [Setting] = []
        /// The height of the room of each picture, by its place in the string.
        var rooms: [Int: CGFloat] = [:]
        var atParagraphStart = true
        var counter = 0
        for var run in text.runs {
            run.text = marked(run, atParagraphStart: &atParagraphStart, counter: &counter)
            if run.text.contains("\u{FFFC}") {
                if let id = run.objectID, let size = objects[id], size.height > 0 {
                    for _ in run.text.filter({ $0 == "\u{FFFC}" }) { rooms[out.length] = size.height; out.append(spacer(size, id: id)) }
                }
                run.text = run.text.replacingOccurrences(of: "\u{FFFC}", with: "")
                if run.text.isEmpty { continue }
            }
            let size = CGFloat((run.fontSize ?? defaultSize) * density)
            var font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
            if let name = run.fontName, !name.isEmpty {
                // A font this Mac does not have falls back to the system's.
                let named = CTFontCreateWithName(name as CFString, size, nil)
                if (CTFontCopyFamilyName(named) as String).caseInsensitiveCompare(name) == .orderedSame || (CTFontCopyPostScriptName(named) as String).caseInsensitiveCompare(name) == .orderedSame { font = named }
            }
            var traits: CTFontSymbolicTraits = []
            if run.bold { traits.insert(.traitBold) }
            if run.italic { traits.insert(.traitItalic) }
            if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) { font = styled }
            // How its paragraph is set is decided for the paragraph as a whole, below.
            let firstIndent = CGFloat(run.indent) * size * 1.4
            settings.append(Setting(range: NSRange(location: out.length, length: (run.text as NSString).length), size: size,
                                    alignment: [.left, .right, .center, .justified][min(max(run.alignment, 0), 3)], firstIndent: firstIndent, restIndent: firstIndent + (run.bullet == nil ? 0 : size * 1.25)))
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                // Highlighted text keeps its own colour: the highlight is the paper it stands on.
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(adapted(run.color ?? 0xFF25_2525, dark: dark && (run.background ?? 0) >> 24 == 0)),
            ]
            if run.underline || run.link { attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue }
            if run.link { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = CGColor(srgbRed: 0.1, green: 0.42, blue: 0.95, alpha: 1) }
            if run.strikethrough { attributes[NSAttributedString.Key("NSStrikethrough")] = 1 }
            if let background = run.background, background >> 24 != 0 { attributes[NSAttributedString.Key(kCTBackgroundColorAttributeName as String)] = color(background) }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        // Paragraph by paragraph: from one line to the next is 1.35 times the size of the
        // paragraph's largest text, exactly, as Samsung's engine sets text (its rulings are made
        // to that measure). A paragraph that holds a picture is as high as the picture.
        let whole = out.string as NSString
        var next = 0
        var at = 0
        while at < whole.length {
            let range = whole.paragraphRange(for: NSRange(location: at, length: 0))
            at = max(NSMaxRange(range), at + 1)
            while next < settings.count, NSMaxRange(settings[next].range) <= range.location { next += 1 }
            var inside: [Setting] = []
            var index = next
            while index < settings.count, settings[index].range.location < NSMaxRange(range) { inside.append(settings[index]); index += 1 }
            guard let first = inside.first else { continue }
            var holdsPicture = false
            out.enumerateAttribute(objectAttribute, in: range) { value, _, _ in if value != nil { holdsPicture = true } }
            var alignment = first.alignment, firstIndent = first.firstIndent, restIndent = first.restIndent
            var height: CGFloat = holdsPicture ? 0 : (inside.map(\.size).max() ?? first.size) * CGFloat(linePitch)
            // A picture or a table alone in its paragraph: the paragraph is exactly as high as
            // the thing's room; the line break after it adds nothing. (Measured in a note of the
            // Windows client: the rooms of two tables, one under the other, touch.)
            if holdsPicture {
                let alone = (range.location..<NSMaxRange(range)).filter { whole.character(at: $0) == 0xFFFC }
                if alone.count == 1, let room = rooms[alone[0]], whole.substring(with: range).allSatisfy({ $0 == "\u{FFFC}" || $0.isNewline }) { height = room }
            }
            let style = withUnsafePointer(to: &alignment) { alignmentPointer in
                withUnsafePointer(to: &height) { heightPointer in
                    withUnsafePointer(to: &firstIndent) { firstPointer in
                        withUnsafePointer(to: &restIndent) { restPointer in
                            CTParagraphStyleCreate([
                                CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentPointer),
                                CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: heightPointer),
                                CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: heightPointer),
                                CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: firstPointer),
                                CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: restPointer),
                            ], 5)
                        }
                    }
                }
            }
            out.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: style, range: range)
        }
        return out
    }

    /// How a run of text asks for its paragraph to be set.
    private struct Setting {
        var range: NSRange
        var size: CGFloat
        var alignment: CTTextAlignment
        var firstIndent: CGFloat
        var restIndent: CGFloat
    }

    /// Draws text into a rectangle given with y down.
    static func drawText(_ string: NSAttributedString, in rect: CGRect, context: CGContext) {
        guard string.length > 0, rect.width > 1, rect.height > 1 else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let setter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// The sizes of the pictures set in a note's text, as the text makes room for them: never
    /// wider than the text column nor taller than the room a page has, so that each fits on a page.
    public static func pictureSizes(_ document: NoteDocument) -> [String: CGSize] {
        let column = TextColumn(document)
        var sizes: [String: CGSize] = [:]
        for object in document.allObjects where object.kind == .image || object.kind == .painting || object.kind == .table {
            // A turned picture needs the room of its corners; a table, the room Samsung's
            // clients leave around one.
            var room = object.turnedSize
            if object.kind == .table {
                let around = tableRoom(document.density)
                room = CGSize(width: room.width + around.width, height: room.height + around.height)
            }
            sizes[object.id] = CGSize(width: min(room.width, column.width), height: min(room.height, column.usable - 2))
        }
        return sizes
    }

    /// A folded sticky note, drawn as Samsung's clients draw one: a round-cornered square of
    /// its paper with the bottom right corner turned up, outlined in grey, a little see-through.
    /// `rect` is given with y down.
    public static func drawSticky(in rect: CGRect, paper: UInt32?, context: CGContext) {
        guard rect.width > 1, rect.height > 1 else { return }
        let argb = paper.flatMap { $0 >> 24 == 0 ? nil : $0 } ?? StickyDocument.papers[0]
        // The measures of the clients' own sign, which is 34 units square inside a line of 1.5.
        let side = min(rect.width, rect.height), unit = side / 36
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        let round = 8.5 * unit
        let shape = CGMutablePath()
        shape.move(to: at(21.2, 34.1))
        shape.addLine(to: at(34.1, 21.2))
        shape.addQuadCurve(to: at(35, 19), control: at(35, 20.3))
        shape.addArc(tangent1End: at(35, 1), tangent2End: at(1, 1), radius: round)
        shape.addArc(tangent1End: at(1, 1), tangent2End: at(1, 35), radius: round)
        shape.addArc(tangent1End: at(1, 35), tangent2End: at(35, 35), radius: round)
        shape.addLine(to: at(19, 35))
        shape.addQuadCurve(to: at(21.2, 34.1), control: at(20.3, 35))
        shape.closeSubpath()
        let fold = CGMutablePath()
        fold.move(to: at(34.5, 20.3))
        fold.addArc(tangent1End: at(20.3, 20.3), tangent2End: at(20.3, 34.4), radius: 7.4 * unit)
        fold.addLine(to: at(20.3, 34.4))
        context.saveGState()
        context.setAlpha(0.78)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(shape)
        context.setFillColor(color(argb))
        context.fillPath()
        context.setStrokeColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.32, alpha: 1))
        context.setLineWidth(max(1.5 * unit, 0.75))
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(shape)
        context.addPath(fold)
        context.strokePath()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// A folded sticky note as a picture, for where one is shown outside a page.
    /// `padded` leaves room around the square for its shadow.
    public static func stickyImage(paper: UInt32?, pixels: Int = 96, padded: Bool = true) -> CGImage? {
        let key = "\(paper ?? 0)|\(pixels)|\(padded)"
        stickyLock.lock(); defer { stickyLock.unlock() }
        if let known = stickyImages[key] { return known }
        let room = padded ? pixels + pixels / 2 : pixels, edge = padded ? pixels / 4 : 0
        guard let context = CGContext(data: nil, width: room, height: room, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(room))
        context.scaleBy(x: 1, y: -1)
        drawSticky(in: CGRect(x: edge, y: edge, width: pixels, height: pixels), paper: paper, context: context)
        let made = context.makeImage()
        stickyImages[key] = made
        return made
    }

    private static let stickyLock = NSLock()
    nonisolated(unsafe) private static var stickyImages: [String: CGImage] = [:]

    /// The room around a table set in the text, beyond its own rectangle: a hairline at either
    /// side, and above and below it ten units of text size and a hairline (as measured between
    /// two tables in a note of the Windows client).
    public static func tableRoom(_ density: Double) -> CGSize { CGSize(width: 0.3, height: 20 * density + 0.3) }

    /// Draws a table into a rectangle given with y down: its cells' papers, its lines, its texts.
    public static func drawTable(_ table: SamsungTable, in rect: CGRect, dark: Bool, context: CGContext) {
        guard rect.width > 1, rect.height > 1, table.rect.width > 0, table.rect.height > 0 else { return }
        let scale = rect.width / table.rect.width
        let density = Double(table.pageWidth > 0 ? table.pageWidth : 1183) / 360
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        let whole = CGRect(origin: .zero, size: table.rect.size)
        // Rounded at its outer corners, as the clients draw a table with its first kind of lines.
        let lines = table.lines
        let corner = lines == .rounded ? min(3.65 * density, whole.width / 2, whole.height / 2) : 0
        let outline = CGPath(roundedRect: whole, cornerWidth: corner, cornerHeight: corner, transform: nil)
        context.saveGState()
        context.addPath(outline)
        context.clip()
        let places = table.cellRects
        for (rowIndex, row) in table.rows.enumerated() {
            for (column, cell) in row.enumerated() {
                guard let place = places[safe: rowIndex]?[safe: column] else { continue }
                let paper = table.paper(row: rowIndex, column: column)
                if paper >> 24 != 0 {
                    context.setFillColor(color(paper))
                    context.fill(place)
                }
                let runs = cell.runs
                guard !runs.isEmpty else { continue }
                // Piece by piece, each in its style; the lines are set by the largest text.
                var height = CGFloat(Double(runs.map(\.fontSize).max() ?? cell.fontSize) * density) * CGFloat(linePitch)
                var alignment: CTTextAlignment = [.left, .right, .center, .justified][min(max(cell.alignment, 0), 3)]
                let style = withUnsafePointer(to: &height) { pointer in
                    withUnsafePointer(to: &alignment) { side in
                        CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: pointer),
                                                CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: pointer),
                                                CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: side)], 3)
                    }
                }
                let string = NSMutableAttributedString()
                for run in runs {
                    let size = CGFloat(Double(run.fontSize) * density)
                    var font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
                    var traits: CTFontSymbolicTraits = []
                    if run.bold { traits.insert(.traitBold) }
                    if run.italic { traits.insert(.traitItalic) }
                    if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) { font = styled }
                    var attributes: [NSAttributedString.Key: Any] = [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(adapted(run.color, dark: dark && paper >> 24 == 0)),
                        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
                    ]
                    if run.underline { attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue }
                    if run.strikethrough { attributes[NSAttributedString.Key("NSStrikethrough")] = 1 }
                    string.append(NSAttributedString(string: run.text, attributes: attributes))
                }
                drawText(string, in: place.insetBy(dx: 8 * density, dy: 4 * density), context: context)
            }
        }
        context.restoreGState()
        let line = color(dark ? 0xFF8A_8780 : table.lineColor)
        context.setStrokeColor(line)
        context.setLineWidth(max(0.3 * density, 0.75 / scale))
        func across(_ y: CGFloat) { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: whole.maxX, y: y)) }
        if lines == .rounded || lines == .grid || lines == .horizontal {
            for row in places.dropFirst() { if let first = row.first { across(first.minY) } }
        }
        if lines == .rounded || lines == .grid {
            for place in (places.first ?? []).dropFirst() { context.move(to: CGPoint(x: place.minX, y: 0)); context.addLine(to: CGPoint(x: place.minX, y: whole.maxY)) }
            context.addPath(outline)
        }
        if lines == .horizontal || lines == .topAndBottom { across(0); across(whole.maxY) }
        context.strokePath()
        context.restoreGState()
    }

    /// A table as a picture `pixelWidth` wide, for showing it where the text makes room for it.
    public static func tableImage(_ table: SamsungTable, pixelWidth: Int, dark: Bool) -> CGImage? {
        guard table.rect.width > 0, table.rect.height > 0, pixelWidth > 0, pixelWidth < 20_000 else { return nil }
        let scale = CGFloat(pixelWidth) / table.rect.width
        let height = Int((table.rect.height * scale).rounded(.up))
        guard height > 0, height < 60_000, let context = CGContext(data: nil, width: pixelWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        // A hair inside the bitmap, so that the outer line is not cut in half.
        drawTable(table, in: CGRect(x: 1, y: 1, width: CGFloat(pixelWidth) - 2, height: CGFloat(height) - 2), dark: dark, context: context)
        return context.makeImage()
    }

    public static func textHeight(_ text: RichText, width: Double, density: Double, objects: [String: CGSize] = [:]) -> Double {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, density: density, dark: false, objects: objects) as CFAttributedString)
        return Double(CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height)
    }

    /// Draws an image into a rectangle given with y down.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext, fill: Bool = false) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.clip(to: rect)
        var target = rect
        if fill {
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            target = CGRect(x: rect.midX - size.width / 2, y: size.height > rect.height * 1.3 ? rect.minY : rect.midY - size.height / 2, width: size.width, height: size.height)
        }
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }

    static func draw(_ object: NoteObject, note: LoadedNote, origin: CGPoint, dark: Bool, images: Images, context: CGContext) {
        let rect = object.rect.offsetBy(dx: origin.x, dy: origin.y)
        switch object.kind {
        case .stroke:
            guard var stroke = note.strokes[object.id] else { return }
            stroke.argb = adapted(stroke.argb, dark: dark)
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            InkRenderer.draw(stroke, in: context, dark: dark)
            context.restoreGState()
        case .image, .painting:
            context.saveGState()
            if object.rotation.isFinite, object.rotation != 0 {
                // About its middle; y points down here, so a positive angle turns it clockwise.
                context.translateBy(x: rect.midX, y: rect.midY)
                context.rotate(by: object.rotation * .pi / 180)
                context.translateBy(x: -rect.midX, y: -rect.midY)
            }
            if let image = picture(of: object, images: images) { drawImage(image, in: rect, context: context) } else { placeholder(rect, context: context, dark: dark) }
            context.restoreGState()
        case .textBox, .shape:
            guard let text = object.text, !text.isEmpty else { return }
            let density = note.document.density
            let inner = rect.insetBy(dx: object.margins.left * density, dy: object.margins.top * density)
            drawText(attributed(text, density: density, dark: dark), in: inner, context: context)
        case .table:
            if let table = object.table { drawTable(table, in: rect, dark: dark, context: context) } else { placeholder(rect, context: context, dark: dark) }
        case .sticky:
            // A sticky note lies on its page folded up, as a small square of its paper; what it
            // says is read by opening it.
            drawSticky(in: rect, paper: object.paper, context: context)
        default:
            // A table, a formula or another thing this client cannot draw itself: the picture
            // the client that made it keeps of it, when it keeps one.
            if let hash = object.thumbnailFile, let image = images(hash) { drawImage(image, in: rect, context: context) }
        }
    }

    private final class Shown: @unchecked Sendable {
        let cache = NSCache<NSString, CGImage>()
        init() { cache.countLimit = 48 }
    }
    private static let shown = Shown()

    /// The picture an object shows, cropped and cut out as the object says. Kept for the next
    /// time it is asked for: files are named by their content, so a picture is known by its
    /// file's name and the part of it that is shown.
    public static func picture(of object: NoteObject, images: Images) -> CGImage? {
        guard let hash = object.pictureFile, let image = images(hash) else { return nil }
        guard object.isCropped else { return image }
        var key = "\(hash)|\(image.width)x\(image.height)"
        if let crop = object.crop { key += "|\(crop.minX),\(crop.minY),\(crop.width),\(crop.height)" }
        if let outline = object.outline { key += "|" + outline.map { "\($0.x),\($0.y)" }.joined(separator: ";") }
        if let known = shown.cache.object(forKey: key as NSString) { return known }
        guard let made = object.shown(image) else { return image }
        shown.cache.setObject(made, forKey: key as NSString)
        return made
    }

    static func placeholder(_ rect: CGRect, context: CGContext, dark: Bool) {
        guard rect.width > 4, rect.height > 4 else { return }
        context.saveGState()
        context.setFillColor(CGColor(gray: dark ? 0.25 : 0.9, alpha: 1))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    /// Draws the whole note: page backgrounds when asked, body text, then everything on the pages.
    /// `page` limits the work to what lies on one page; `body: false` leaves out the note's text
    /// and the pictures set in it, for when a text view shows them.
    public static func draw(_ note: LoadedNote, in context: CGContext, dark: Bool, pageBackgrounds: Bool = true, page only: Int? = nil, body: Bool = true, images: Images) {
        let document = note.document
        let layout = NoteLayout(document)
        if pageBackgrounds {
            for index in 0..<layout.pageCount where only == nil || only == index {
                drawPaper(index < document.pages.count ? document.pages[index] : nil, in: layout.pageRect(index), dark: dark, images: images, files: { note.fileURL($0) }, context: context)
            }
        }
        // From here on `dark` says whether the writing has to be light: the note's paper decides.
        let dark = isDark(document.pages.first, dark: dark)
        var places: [String: CGPoint] = [:]
        var rooms: [String: CGSize] = [:]
        if body, let flow = TextFlow(document, dark: dark) {
            flow.draw(in: context, within: only.map { layout.pageRect($0) })
            places = flow.positions
            rooms = pictureSizes(document)
        }
        for (index, page) in document.pages.enumerated() where only == nil || only == index {
            let origin = layout.pageRect(index).origin
            for object in page.objects { draw(object, note: note, origin: origin, dark: dark, images: images, context: context) }
        }
        for object in document.floating where body || !object.inText {
            if object.inText, let place = places[object.id] {
                // A picture set in the text lies where the text, laid out now, has made room for
                // it, whatever place it was last saved with: a note saved before the text was
                // set page by page is drawn right without being saved again.
                let room = rooms[object.id] ?? object.rect.size
                var placed = object
                placed.rect = CGRect(x: place.x + (room.width - object.rect.width) / 2, y: place.y + (room.height - object.rect.height) / 2, width: object.rect.width, height: object.rect.height)
                if let only, !CGRect(origin: place, size: room).intersects(layout.pageRect(only)) { continue }
                draw(placed, note: note, origin: .zero, dark: dark, images: images, context: context)
                continue
            }
            let place = min(max(object.pageIndex ?? 0, 0), layout.pageCount - 1)
            let origin = layout.pageRect(place).origin
            // A big object may hang over the foot of its page: it is drawn with every page it touches.
            let reach = CGRect(origin: .zero, size: object.turnedSize).offsetBy(dx: origin.x + object.rect.midX - object.turnedSize.width / 2, dy: origin.y + object.rect.midY - object.turnedSize.height / 2)
            if let only, !reach.intersects(layout.pageRect(only)) { continue }
            draw(object, note: note, origin: origin, dark: dark, images: images, context: context)
        }
    }

    /// The part of the first page worth showing on a card: the ink when there is some, else the
    /// top of the text.
    static func cardRegion(_ note: LoadedNote) -> CGRect {
        let document = note.document
        let layout = NoteLayout(document)
        var ink = CGRect.null
        for (index, page) in document.pages.enumerated() {
            let origin = layout.pageRect(index).origin
            for object in page.objects where object.kind == .stroke {
                if let stroke = note.strokes[object.id] { ink = ink.union(stroke.bounds.offsetBy(dx: origin.x, dy: origin.y)) }
            }
            if !ink.isNull { break }
        }
        let textWidth = layout.pageWidth * (document.density >= 2 ? 0.5 : 0.42)
        if ink.isNull { return CGRect(x: 0, y: 0, width: textWidth, height: textWidth) }
        if !document.body.isEmpty { ink = ink.union(CGRect(x: 0, y: 0, width: textWidth, height: 10)) }
        let side = max(ink.width, ink.height, layout.pageWidth * 0.3) * 1.16
        return CGRect(x: ink.midX - side / 2, y: ink.midY - side / 2, width: side, height: side)
    }

    /// A square picture of the note for the grid.
    public static func thumbnail(_ note: LoadedNote, side: Int, dark: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Bitmap contexts have y up: turn it over so the drawing code's y points down.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        let full = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(pageColor(note.document.pages.first, dark: dark))
        context.fill(full)
        if note.document.allObjects.contains(where: { $0.kind == .image }), let hash = note.document.firstImage, let image = note.image(hash) {
            drawImage(image, in: full, context: context, fill: true)
            return context.makeImage()
        }
        let document = note.document
        let dark = isDark(document.pages.first, dark: dark)
        if document.pages.first?.pdf != nil {
            // A note made of a PDF shows the top of its first page, with what is written on it.
            let scale = CGFloat(side) / CGFloat(max(NoteLayout(document).pageWidth, 1))
            context.scaleBy(x: scale, y: scale)
            var cache: [String: CGImage] = [:]
            draw(note, in: context, dark: dark, page: 0) { hash in
                if let image = cache[hash] { return image }
                let image = note.image(hash)
                cache[hash] = image
                return image
            }
            return context.makeImage()
        }
        if !document.allObjects.contains(where: { $0.kind == .stroke || $0.kind == .painting || $0.kind == .image }) {
            // Text only: the card shows the text set to the card's own width, as Samsung's does.
            let width = 208 * document.density
            let scale = CGFloat(side) / width
            context.scaleBy(x: scale, y: scale)
            let inset = document.bodyMargins.left * document.density
            drawText(attributed(document.body, density: document.density, dark: dark), in: CGRect(x: inset, y: inset * 0.8, width: width - inset * 2, height: width * 4), context: context)
            return context.makeImage()
        }
        let region = cardRegion(note)
        let scale = CGFloat(side) / region.width
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -region.minX, y: -region.minY)
        var cache: [String: CGImage] = [:]
        draw(note, in: context, dark: dark, pageBackgrounds: false) { hash in
            if let image = cache[hash] { return image }
            let image = note.image(hash)
            cache[hash] = image
            return image
        }
        return context.makeImage()
    }

    /// One page as a picture `pixelWidth` wide.
    public static func pageImage(_ note: LoadedNote, page index: Int, pixelWidth: Int, dark: Bool, body: Bool = true, images: Images) -> CGImage? {
        let layout = NoteLayout(note.document)
        let rect = layout.pageRect(index)
        let scale = CGFloat(pixelWidth) / rect.width
        let scaled = (rect.height * scale).rounded()
        guard scaled.isFinite, scaled >= 1, scaled < 60_000 else { return nil }
        let height = Int(scaled)
        guard pixelWidth > 0, pixelWidth < 60_000, let context = CGContext(data: nil, width: pixelWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.clip(to: rect)
        draw(note, in: context, dark: dark, page: index, body: body, images: images)
        return context.makeImage()
    }

    public static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// The column a note's text is set in, page by page, in the note's own units.
public struct TextColumn: Sendable, Equatable {
    public var left: Double
    public var width: Double
    /// The margins above and below the text on every page.
    public var top: Double
    public var bottom: Double
    public var pageHeight: Double
    public var gap: Double
    /// Where each page begins and how high it is, in a note whose pages are not all of one
    /// height (the pages of a PDF keep its shape); empty when every page is `pageHeight` high.
    public var tops: [Double] = []
    public var heights: [Double] = []

    public init(_ document: NoteDocument) {
        let layout = NoteLayout(document)
        let density = document.density
        func sane(_ value: Double, _ fallback: Double) -> Double { value.isFinite && value >= 0 ? value : fallback }
        left = sane(document.bodyMargins.left, 16) * density
        width = max(layout.pageWidth - left - sane(document.bodyMargins.right, 16) * density, 16)
        top = sane(document.bodyMargins.top, 10) * density
        bottom = sane(document.bodyMargins.bottom, 10) * density
        pageHeight = layout.pageHeight
        gap = layout.gap
        let all = (0..<max(document.pages.count, 1)).map { layout.height($0) }
        if all.contains(where: { abs($0 - layout.pageHeight) > 0.01 }) {
            heights = all
            tops = all.indices.map { layout.top($0) }
        }
    }

    /// From the top of one page to the top of the next.
    public var stride: Double { pageHeight + gap }
    /// The height text has on one page.
    public var usable: Double { max(pageHeight - top - bottom, 16) }

    /// Where a page begins, from the top of the first; pages past the note's last go on as the last does.
    public func top(ofPage page: Int) -> Double {
        guard !tops.isEmpty else { return Double(page) * stride }
        if page < tops.count { return tops[max(page, 0)] }
        return tops[tops.count - 1] + Double(page - tops.count + 1) * (heights[heights.count - 1] + gap)
    }

    /// The height text has on a given page.
    public func usable(onPage page: Int) -> Double {
        guard !heights.isEmpty else { return usable }
        return max(heights[min(max(page, 0), heights.count - 1)] - top - bottom, 16)
    }

    /// The page a place this far down the note lies on.
    public func page(at y: Double) -> Int {
        guard y.isFinite else { return 0 }
        guard !tops.isEmpty else { return max(Int(min(max(y / max(stride, 1), 0), 100_000)), 0) }
        var found = 0
        var page = 0
        while page < 100_000, top(ofPage: page) <= y { found = page; page += 1; if page > tops.count + 2_000 { break } }
        return found
    }
}

/// A note's text laid out page by page: a line, or a picture set in the text, that does not
/// fit in what is left of a page starts the next page. Nothing is drawn across the break
/// between two pages.
public struct TextFlow {
    struct Piece {
        let frame: CTFrame
        /// Where the frame lies, in the note's units with y down.
        let rect: CGRect
    }

    let pieces: [Piece]
    public let column: TextColumn
    /// Where the text ends, from the top of the first page.
    public let bottom: Double
    /// How many pages the text reaches onto.
    public let pagesUsed: Int

    /// The flow of a note's own text; nil when it has none.
    public init?(_ document: NoteDocument, dark: Bool = false) {
        guard !document.body.runs.isEmpty else { return nil }
        let string = NoteRenderer.attributed(document.body, density: document.density, dark: dark, objects: NoteRenderer.pictureSizes(document))
        self.init(string, column: TextColumn(document))
    }

    init?(_ string: NSAttributedString, column: TextColumn) {
        guard string.length > 0, column.width > 1 else { return nil }
        self.column = column
        let setter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        var pieces: [Piece] = []
        var start = 0
        var page = 0
        while start < string.length, page < 5_000 {
            var rect = CGRect(x: column.left, y: column.top(ofPage: page) + column.top, width: column.width, height: column.usable(onPage: page))
            var frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
            var visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 {
                // Something that no page has room for: it is set here all the same, with what follows it.
                rect.size.height = 1_000_000
                frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
                visible = CTFrameGetVisibleStringRange(frame)
                if visible.length <= 0 { break }
            }
            pieces.append(Piece(frame: frame, rect: rect))
            start = visible.location + visible.length
            page += 1
        }
        guard let last = pieces.last else { return nil }
        self.pieces = pieces
        // The foot of the last line of the last piece.
        let lines = CTFrameGetLines(last.frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(last.frame, CFRange(location: 0, length: 0), &origins)
        var end = last.rect.minY
        if let line = lines.last, let origin = origins.last {
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, nil, &descent, nil)
            end = last.rect.minY + last.rect.height - (origin.y - descent)
        }
        bottom = end
        pagesUsed = max(column.page(at: end - 0.5) + 1, 1)
    }

    /// Where each line of the text lies, from the top left of the first page: from its ascent
    /// to its descent, as wide as what is written on it.
    public var lineRects: [CGRect] {
        var out: [CGRect] = []
        for piece in pieces {
            let lines = CTFrameGetLines(piece.frame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(piece.frame, CFRange(location: 0, length: 0), &origins)
            for (line, origin) in zip(lines, origins) {
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil) - CTLineGetTrailingWhitespaceWidth(line)
                guard width > 0.5 else { continue }
                out.append(CGRect(x: piece.rect.minX + origin.x, y: piece.rect.minY + piece.rect.height - origin.y - ascent, width: width, height: ascent + descent))
            }
        }
        return out
    }

    /// Where each picture set in the text comes to lie: its top left corner, from the top left of the first page.
    public var positions: [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        for piece in pieces {
            let lines = CTFrameGetLines(piece.frame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(piece.frame, CFRange(location: 0, length: 0), &origins)
            for (line, origin) in zip(lines, origins) {
                for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    guard let id = attributes[NoteRenderer.objectAttribute] as? String, out[id] == nil else { continue }
                    let ascent = NoteRenderer.roomAscent(run, in: line)
                    let x = origin.x + CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
                    out[id] = CGPoint(x: piece.rect.minX + x, y: piece.rect.minY + piece.rect.height - origin.y - ascent)
                }
            }
        }
        return out
    }

    /// Draws the text; with `within`, only the part that lies there.
    func draw(in context: CGContext, within area: CGRect? = nil) {
        for piece in pieces {
            if let area, !piece.rect.intersects(area) { continue }
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: piece.rect.minX, y: piece.rect.maxY)
            context.scaleBy(x: 1, y: -1)
            CTFrameDraw(piece.frame, context)
            context.restoreGState()
        }
    }
}
