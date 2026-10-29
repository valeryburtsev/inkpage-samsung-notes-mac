import AppKit
import PDFKit
import SamsungNotesKit
import SwiftUI
import UniformTypeIdentifiers

/// How a note's pages follow one another on screen.
enum ScrollDirection: String, CaseIterable, Identifiable {
    case vertical, horizontal, twoPage

    /// The scroll direction is a matter of how a note is looked at on this Mac: it is kept in
    /// the app's settings for each note, not in the note.
    static func remembered(for noteID: String) -> ScrollDirection {
        guard let all = UserDefaults.standard.dictionary(forKey: "scrollDirections") as? [String: String] else { return .vertical }
        return all[noteID].flatMap(ScrollDirection.init(rawValue:)) ?? .vertical
    }

    func remember(for noteID: String) {
        var all = UserDefaults.standard.dictionary(forKey: "scrollDirections") as? [String: String] ?? [:]
        if self == .vertical { all[noteID] = nil } else { all[noteID] = rawValue }
        UserDefaults.standard.set(all, forKey: "scrollDirections")
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        case .twoPage: return "2-page horizontal"
        }
    }
    var symbol: String {
        switch self {
        case .vertical: return "rectangle.portrait.arrowtriangle.2.outward"
        case .horizontal: return "rectangle.portrait.arrowtriangle.2.inward"
        case .twoPage: return "book"
        }
    }
}

/// Pictures and PDF pages the user has added as papers of their own: kept in the app's folder,
/// one file each, and put into a note when they are chosen for it.
enum OwnTemplates {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        _ = LocalStore.defaultRoot  // the folder of the app's former name moved first
        return base.appendingPathComponent(LocalStore.appName, isDirectory: true).appendingPathComponent("Templates", isDirectory: true)
    }

    static func all() -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return found.filter { ["png", "jpg"].contains($0.pathExtension.lowercased()) }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
    }

    /// Takes pictures and the pages of PDF documents in as papers. Returns how many came in.
    @discardableResult
    static func add(_ urls: [URL]) -> Int {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var added = 0
        func keep(_ file: PictureFile) {
            let url = folder.appendingPathComponent(UUID().uuidString.lowercased() + "." + file.fileExtension)
            if (try? file.data.write(to: url)) != nil { added += 1 }
        }
        for url in urls {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                guard let document = CGPDFDocument(url as CFURL) else { continue }
                for number in 1...max(min(document.numberOfPages, 24), 1) {
                    if let page = document.page(at: number), let file = PictureFile(pdfPage: page) { keep(file) }
                }
            } else if let data = try? Data(contentsOf: url), let file = PictureFile(data: data) {
                keep(file)
            }
        }
        return added
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

extension PictureFile {
    /// A page of a PDF as a picture, at most 1600 pixels wide and 2200 high.
    init?(pdfPage page: CGPDFPage) {
        let box = page.getBoxRect(.cropBox)
        let turned = page.rotationAngle % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 1, size.height > 1 else { return nil }
        let scale = min(1600 / size.width, 2200 / size.height, 3)
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), rotate: 0, preserveAspectRatio: true))
        // getDrawingTransform never scales up: do that ourselves around the box it fitted.
        if scale > 1 {
            context.translateBy(x: box.midX, y: box.midY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.midX, y: -box.midY)
        }
        context.drawPDFPage(page)
        let out = NSMutableData()
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        self.init(data: out as Data, fileExtension: "jpg", pixels: CGSize(width: width, height: height))
    }
}

/// The note style panel, as in the original: how the pages scroll, the paper's colour, and the
/// paper's ruling or a picture of one's own under the page.
struct NoteStylePanel: View {
    let session: NoteSession
    /// The page the note is at: the one a template is given to when not all pages get it.
    let page: Int
    @Binding var scroll: ScrollDirection
    let dark: Bool
    @State private var tab = Tab.page
    @State private var allPages = true
    @State private var own: [URL] = OwnTemplates.all()

    private enum Tab: String, CaseIterable { case page = "Page", template = "Template" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Note style").font(.title3.weight(.semibold))
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .page: pageTab
            case .template: templateTab
            }
        }
        .padding(18)
        .frame(width: 396)
    }

    // MARK: Page

    private var pageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scroll direction").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(ScrollDirection.allCases) { direction in
                    Button { scroll = direction } label: {
                        VStack(spacing: 6) {
                            Image(systemName: direction.symbol).font(.system(size: 20)).frame(height: 26)
                            Text(direction.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(scroll == direction ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                        .background(scroll == direction ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(scroll == direction ? Color.accentColor : .clear, lineWidth: 1.5) }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(direction.title)
                    .accessibilityAddTraits(scroll == direction ? .isSelected : [])
                }
            }
            Text("Background colour").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            let chosen = session.note?.document.pages.first?.background ?? PaperColors.plain
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 6), spacing: 10) {
                ForEach(PaperColors.all, id: \.argb) { paper in
                    Button { session.setPaperColor(paper.argb) } label: {
                        Rectangle().fill(PenChoice.color(paper.argb))
                            .frame(height: 44)
                            .overlay { if paper.argb == PaperColors.plain { Image(systemName: "circle.slash").font(.caption).foregroundStyle(.tertiary).opacity(chosen == paper.argb ? 0 : 1) } }
                            .overlay { if chosen == paper.argb { Image(systemName: "checkmark").font(.body.bold()).foregroundStyle(NoteRenderer.luminance(paper.argb) < 0.42 ? .white : .black) } }
                            .overlay { Rectangle().strokeBorder(.primary.opacity(0.1)) }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(paper.name)
                    .accessibilityLabel(paper.name)
                    .accessibilityAddTraits(chosen == paper.argb ? .isSelected : [])
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            Text("The colour is for every page of the note.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Template

    private var templateTab: some View {
        let style = session.note?.document.pages[safe: page]
        return VStack(alignment: .leading, spacing: 10) {
            Toggle("Apply to all pages", isOn: $allPages)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Default").font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(PageTemplate.allCases) { template in
                            let chosen = style?.backgroundImage == nil && (style?.template ?? .blank) == template
                            Button { session.setTemplate(template, page: allPages ? nil : page) } label: {
                                Canvas { context, size in
                                    // The rulings that repeat are shown at twice their size, from the page's
                                    // top left corner, so that one can be told from another; the others whole.
                                    let zoom: CGFloat = template.pitch > 0 ? 2 : 1
                                    context.withCGContext { template.draw(in: $0, page: CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom), dark: false) }
                                }
                                .background(Color.white)
                                .aspectRatio(90.0 / 127.0, contentMode: .fit)
                                .overlay { Rectangle().strokeBorder(chosen ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: chosen ? 2.5 : 1) }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(template.title)
                            .accessibilityLabel(template.title)
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                    HStack {
                        Text("Your own").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button { addOwn() } label: { Image(systemName: "plus").frame(width: 24, height: 22).contentShape(.rect) }
                            .buttonStyle(.plain)
                            .help("Add pictures or PDF pages to use as paper")
                            .accessibilityLabel("Add a template of your own")
                    }
                    .padding(.top, 6)
                    if own.isEmpty {
                        Text("Add a picture or a PDF, such as a planner page, to write on it.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                            ForEach(own, id: \.self) { url in
                                Button { useOwn(url) } label: {
                                    OwnTemplateTile(url: url)
                                        .aspectRatio(90.0 / 127.0, contentMode: .fit)
                                        .overlay { Rectangle().strokeBorder(Color.primary.opacity(0.12)) }
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button("Remove from Your Templates", systemImage: "trash", role: .destructive) { OwnTemplates.remove(url); own = OwnTemplates.all() } }
                                .accessibilityLabel("Template of your own")
                            }
                        }
                        Text("Right-click one to remove it from this list. Notes that use it keep it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(height: 400)
        }
    }

    private func addOwn() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Pictures and the pages of PDF documents become papers you can write on."
        guard panel.runModal() == .OK else { return }
        OwnTemplates.add(panel.urls)
        own = OwnTemplates.all()
    }

    private func useOwn(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let file = PictureFile(data: data) else { return }
        session.setTemplate(picture: file, page: allPages ? nil : page)
    }
}

private struct OwnTemplateTile: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.white
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .clipped()
        .task(id: url) {
            let url = url
            image = await Task.detached { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 360] as CFDictionary) else { return nil }
                return NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
            }.value
        }
    }
}

/// Watches for a sideways swipe on the trackpad over the view it lies behind, and says which
/// way the page should turn: 1 for the next, -1 for the one before.
struct SwipeWatcher: NSViewRepresentable {
    let turn: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView { SwipeView() }
    func updateNSView(_ view: SwipeView, context: Context) { view.turn = turn }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.stop() }
}

final class SwipeView: NSView {
    var turn: ((Int) -> Void)?
    private var monitor: Any?
    private var across: CGFloat = 0
    private var along: CGFloat = 0
    private var turned = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.watch(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func watch(_ event: NSEvent) {
        guard event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        // Only a swipe of the fingers, from where they touch down to where they lift.
        if event.phase == .began { across = 0; along = 0; turned = false }
        guard event.phase == .changed, !turned else { return }
        across += event.scrollingDeltaX
        along += abs(event.scrollingDeltaY)
        if abs(across) > 90, abs(across) > along * 2.5 {
            turned = true
            turn?(across < 0 ? 1 : -1)
        }
    }
}
