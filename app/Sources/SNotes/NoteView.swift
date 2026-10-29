import AppKit
import LocalAuthentication
import SamsungNotesKit
import SwiftUI
import UniformTypeIdentifiers

/// A note on screen. The work is in `NoteScreen`; this makes the note's session and keeps it
/// in step with the app.
struct NoteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let noteID: String
    @State private var session: NoteSession?
    /// The session made ready before the note was shown is taken over, not read again.
    @State private var adopted = false

    init(noteID: String) {
        self.noteID = noteID
        let ready = NoteSession.ready.removeValue(forKey: noteID)
        _session = State(initialValue: ready)
        _adopted = State(initialValue: ready != nil)
    }

    var body: some View {
        let record = model.library.notes[noteID]
        Group {
            if let session, session.noteID == noteID {
                NoteScreen(session: session)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: noteID) {
            if adopted, let ready = session, ready.noteID == noteID {
                adopted = false
                ready.undoManager = undoManager
                model.registerFlush(ready.flushKey) { [weak ready] in ready?.flush() }
                return
            }
            if let old = session {
                old.close()
                model.unregisterFlush(old.flushKey)
            }
            let made = NoteSession(noteID: noteID, model: model)
            made.undoManager = undoManager
            session = made
            model.registerFlush(made.flushKey) { [weak made] in made?.flush() }
            await made.load(text: true)
        }
        .onChange(of: undoManager) { session?.undoManager = undoManager }
        .onChange(of: record?.commitID) { session?.libraryChanged() }
        .onChange(of: record?.bytes) {
            // A picture of the note has arrived: show it.
            if let session, record?.pending == nil { Task { await session.load(text: false) } }
        }
        .onDisappear {
            if let session {
                session.close()
                model.unregisterFlush(session.flushKey)
            }
            model.discardIfEmpty(noteID)
        }
    }
}

private struct NoteScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.undoManager) private var undoManager
    let session: NoteSession

    @State private var zoom = 1.0
    @State private var pinchStart: Double?
    @State private var showInfo = false
    /// The pages down the side of the window. Remembered from one note to the next.
    @State private var showPages = NoteScreen.remembers && UserDefaults.standard.bool(forKey: "pagesSidebar")
    /// Scripted runs neither read nor leave settings behind.
    private static let remembers = Launch.value("--editor-check") == nil && Launch.value("--window-snapshot") == nil
    @State private var currentPage = 0
    /// How the pages follow one another: remembered for each note.
    @State private var scroll = ScrollDirection.vertical
    @State private var showStyle = false
    @State private var showDrawing = false
    /// The sticky note or table being written in the note itself.
    @State private var live: SmartLive?
    /// The table being written in the note itself.
    @State private var tableLive: TableLive?
    /// The text box being written in where it stands.
    @State private var boxLive: BoxLive?
    /// How far down the pages the window's top edge is: kept without drawing anything anew.
    @State private var viewport = Viewport()
    /// One just put into the note: it is opened to be written in as soon as it is there.
    @State private var awaiting: String?
    @State private var tableSetup = false
    @State private var drawing = false
    @State private var tool: InkTool = .pen
    /// The tool a note opens with has been chosen: it is not chosen again when the note is read anew.
    @State private var choseTool = false
    @State private var pen = PenChoice.stored()
    @State private var eraser = EraserChoice.stored()
    @State private var picking = SelectChoice.stored()
    /// The selection tool is in hand to change the style of what it picks.
    @State private var styling = false
    /// The options of the tool in hand are shown beside the tools.
    @AppStorage("toolPanelOpen") private var toolPanel = false
    /// The Easy writing pad is open, and where on the page what is written in it goes.
    @State private var padOn = false
    /// The pointer is in hand: a click picks a block of handwriting.
    @State private var pointing = false
    @State private var padTarget: PadTarget?
    @State private var padUsed = 0.0
    @State private var padRevision = 0
    /// The tools stand at the left edge of the note.
    @AppStorage("toolsOnLeft") private var toolsOnLeft = false
    @State private var pickedPicture: CGImage?
    @State private var pickedRevision = 0
    @State private var jumpTo: Int?
    /// The part of the picture being cropped that is kept, in fractions of the whole picture.
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @FocusState private var titleFocused: Bool
    /// Keeps what is chosen in the crop that is under way; set by the crop view.
    @State private var cropDone: (() -> Void)?
    /// Shows the whole picture again, as it first was.
    @State private var cropReset: (() -> Void)?

    private var noteID: String { session.noteID }

    var body: some View {
        let item = model.item(noteID)
        return watching(main(item))
            .navigationTitle(item?.title ?? "Note")
            .navigationSubtitle(item.map { Format.stamp($0.date) } ?? "")
            .toolbar { toolbar(item) }
    }

    private func main(_ item: NoteItem?) -> some View {
        HStack(spacing: 0) {
            if showPages, session.note != nil, !session.isLocked, item != nil {
                PagesSidebar(session: session, dark: scheme == .dark, current: min(currentPage, max(session.visiblePages - 1, 0))) { page in
                    currentPage = page
                    jumpTo = page
                }
                Divider()
            }
            noteArea(item)
        }
    }

    private func noteArea(_ item: NoteItem?) -> some View {
        GeometryReader { proxy in
            if item == nil {
                ContentUnavailableView("This note is no longer here", systemImage: "trash", description: Text("It was deleted on this Mac or on another device."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.isLocked {
                LockGate(session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let note = session.note, let images = session.images {
                pages(note, images, in: proxy.size)
            } else if session.failed {
                ContentUnavailableView("This note is not on this Mac yet", systemImage: "icloud.and.arrow.down", description: Text("Sync to download it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Lighter than the bars at the sides, as the paper's table is in Preview.
        .background(scheme == .dark ? Color(white: 0.075) : Color(white: 0.965))
        .gesture(MagnifyGesture().onChanged { value in
            if pinchStart == nil { pinchStart = zoom }
            zoom = min(max((pinchStart ?? 1) * value.magnification, 0.4), 4)
        }.onEnded { _ in pinchStart = nil })
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if session.finding, session.note != nil, !session.isLocked { FindBar(session: session) }
                if session.note != nil, !session.isLocked { RecordingsBar(session: session) }
                banner
            }
            .padding(.top, 10)
        }
        .overlay {
            // The tools, and the zoom under them, down the side they were put at.
            GeometryReader { geometry in
            VStack(alignment: toolsOnLeft ? .leading : .trailing, spacing: 12) {
                if session.canEdit {
                    ToolStrip(drawing: $drawing, tool: $tool, pen: $pen, eraser: $eraser, picking: $picking, styling: $styling, panel: $toolPanel,
                              onLeft: $toolsOnLeft, room: geometry.size.height - 190,
                              hasPDF: session.note?.document.pages.contains { $0.pdf != nil } ?? false, text: session.text, hasSelection: session.selection != nil,
                              canUndo: session.canUndo, canRedo: session.canRedo,
                              undo: { undoManager?.undo() }, redo: { undoManager?.redo() }, insert: insert,
                              restyle: { color, level in session.restyleSelection(argb: color, level: level) },
                              eraseAll: eraseAllInk,
                              tapesOpen: session.hasTapes ? session.tapesRevealed : nil,
                              setTapes: { session.setAllTapes(revealed: $0) }, pad: $padOn, pointing: $pointing, addBox: newBox)
                }
                if session.note != nil, !session.isLocked { zoomControl }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: toolsOnLeft ? .leading : .trailing)
            }
        }
        .overlay(alignment: .bottom) {
            if let cropping = session.cropping, session.canEdit {
                CropBar(lasso: cropping.lasso, canReset: session.pictureObject(cropping.id).map { $0.isCropped || $0.originalImageID != nil } == true || cropRect != NoteScreen.wholePicture,
                        reset: { resetCrop(cropping.id) }, cancel: { session.cropping = nil }, done: { cropDone?() })
                    .padding(.bottom, 18)
            } else if let open = tableLive, session.canEdit {
                TableBar(live: open, done: commitSmart)
                    .padding(.bottom, 18)
            } else if padOn, drawing, tool == .pen, session.canEdit, let document = session.note?.document {
                easyPad(document)
                    .padding(.bottom, 14)
            } else {
                VStack(spacing: 8) {
                    if scroll != .vertical, session.note != nil, !session.isLocked { pager }
                    // With the tool's options open the keyboard's are there; closed, they are in the bar below.
                    if session.canEdit, !drawing, !toolPanel { FormatBar(text: session.text) }
                }
                .padding(.bottom, 18)
            }
        }
        .background {
            // A sideways swipe turns the page where the note is shown a page at a time.
            if scroll != .vertical { SwipeWatcher { step in turn(by: step) } }
        }
    }

    /// The screen's reactions to changes, apart from its layout.
    private func watching(_ content: some View) -> some View {
        content
            .onChange(of: drawing) {
            session.saveNow()
            // What was picked of a PDF's text goes when the pens come out.
            if drawing { session.pdfText.clear() }
            if !drawing { session.selection = nil; session.text.focus() }
        }
            .onChange(of: tool) { if tool != .select { session.selection = nil } }
            .onChange(of: session.cropping) {
            cropRect = session.cropping.flatMap { session.pictureObject($0.id)?.crop } ?? NoteScreen.wholePicture
            if session.cropping == nil { cropDone = nil; cropReset = nil; session.text.focus() }
        }
            .onChange(of: pen) { pen.store() }
            .onChange(of: eraser) { eraser.store() }
            .onChange(of: model.mathResults, initial: true) { session.text.calculates = model.mathResults }
            .onChange(of: picking) { picking.store() }
            .onChange(of: showPages) { if NoteScreen.remembers { UserDefaults.standard.set(showPages, forKey: "pagesSidebar") } }
            .onChange(of: EditorRemote.shared.pages) { if let asked = EditorRemote.shared.pages { showPages = asked } }
            .onChange(of: EditorRemote.shared.style) { if let asked = EditorRemote.shared.style { showStyle = asked } }
            .onChange(of: EditorRemote.shared.scroll) { if let asked = EditorRemote.shared.scroll { scroll = asked } }
            .onChange(of: EditorRemote.shared.page) { if let asked = EditorRemote.shared.page { jumpTo = asked } }
            .onChange(of: session.selection) {
            pickedPicture = picture(of: session.selection)
            pickedRevision += 1
        }
            .onChange(of: session.note == nil) { startDrawingIfAsked() }
            .onChange(of: model.openForDrawing) { startDrawingIfAsked() }
            .onAppear {
            startDrawingIfAsked()
            scroll = NoteScreen.rememberedScroll(noteID)
            session.text.onPage = { page in if scroll != .vertical, currentPage != page { currentPage = min(page, max(session.visiblePages - 1, 0)) } }
        }
            .onChange(of: scroll) { NoteScreen.remember(scroll, for: noteID) }
            .sheet(isPresented: $tableSetup) {
            TableSetup { table in
                tableSetup = false
                // A table of Samsung's own kind, set in the text at the caret.
                if let table { awaiting = session.addTable(rows: table.cells.count, columns: table.columns) }
            }
        }
            .onChange(of: session.pictureRevision) {
            // The sticky note or table just put in has arrived in the note: it is written in at once.
            if let id = awaiting, session.stickyObject(id) != nil || session.pictureObject(id).map({ $0.table != nil || session.smartContent(id) != nil }) == true {
                awaiting = nil
                beginSmart(id)
            }
        }
            .onChange(of: session.pictureSelection) {
                if let live, session.pictureSelection != live.id { commitSmart() }
                if let tableLive, session.pictureSelection != tableLive.id { commitSmart() }
            }
            .onChange(of: drawing) { if drawing { commitSmart() } }
            .onChange(of: EditorRemote.shared.smartBegin) { if let id = EditorRemote.shared.smartBegin { beginSmart(id) } }
            .onChange(of: EditorRemote.shared.smartDone) { commitSmart() }
            .onChange(of: EditorRemote.shared.tableStep) {
                if let open = tableLive { EditorRemote.shared.tableChange?(open) }
            }
            .onChange(of: tableLive?.id) { EditorRemote.shared.tableOpen = tableLive }
            .onChange(of: EditorRemote.shared.tableSetup) { if let asked = EditorRemote.shared.tableSetup { tableSetup = asked } }
            .onChange(of: EditorRemote.shared.insert) { if let asked = EditorRemote.shared.insert { insert(asked) } }
            .onDisappear { commitSmart() }
            .sheet(isPresented: $showDrawing) {
            DrawingSheet { file in
                showDrawing = false
                // Into the text at the caret; with the pens out, onto the page being looked at.
                guard let file, let document = session.note?.document else { return }
                if drawing {
                    let layout = NoteLayout(document)
                    let width = min(layout.pageWidth * 0.6, max(file.pixels.width / 2 * document.density / 2, 60))
                    let height = width * file.pixels.height / max(file.pixels.width, 1)
                    let page = min(currentPage, max(session.visiblePages - 1, 0))
                    session.addPicture(file, onPage: (page, CGRect(x: (layout.pageWidth - width) / 2, y: layout.height(page) * 0.12, width: width, height: height)))
                    tool = .select
                } else {
                    session.addPicture(file, at: session.text.selection.lowerBound)
                }
            }
        }
            .modifier(RemoteTools(tool: $tool, pen: $pen, eraser: $eraser, picking: $picking, styling: $styling, panel: $toolPanel, pad: $padOn, pointing: $pointing, drawing: $drawing, canEdit: session.canEdit, box: remoteBox))
    }

    private func startDrawingIfAsked() {
        guard let note = session.note else { return }
        if model.openForDrawing == noteID {
            model.openForDrawing = nil
            if session.canEdit {
                tool = .pen
                drawing = true
            }
        } else if !choseTool, session.canEdit, note.document.pages.first?.pdf != nil, note.document.body.isEmpty {
            // A note made of a PDF is paper to write and draw on: it opens with the pen in hand.
            tool = .pen
            drawing = true
        }
        choseTool = true
    }

    // MARK: Pages

    private struct Measures {
        var width: Double
        var unit: Double
        var pageHeight: Double
        var gap: Double
        var total: Double
        var left: Double
        var top: Double
        var column: Double
        var metrics: TextController.Metrics
        var layout: NoteLayout

        /// A page's height and where it begins, in the pages' points: pages are not all of one
        /// height in a note made of a PDF.
        func height(_ index: Int) -> Double { layout.height(index) / unit }
        func top(_ index: Int) -> Double { layout.top(index) / unit }
        /// The page a place this far down the pages is on.
        func page(at y: Double) -> Int { layout.page(at: y * unit) }
    }

    private func measures(_ note: LoadedNote, _ layout: NoteLayout, in size: CGSize) -> Measures {
        // Two pages side by side share the window's width.
        let width = (scroll == .twoPage ? max(min((size.width - 170) / 2, 720), 260) : max(min(size.width - 150, 720), 320)) * zoom
        let unit = layout.pageWidth / width
        let density = note.document.density
        // The text's column and its pages, as the library lays the same text out.
        let column = TextColumn(note.document)
        return Measures(width: width, unit: unit, pageHeight: width * layout.pageHeight / layout.pageWidth, gap: layout.gap / unit, total: layout.size.height / unit,
                        left: column.left / unit, top: column.top / unit, column: max(column.width / unit, 40),
                        metrics: TextController.Metrics(scale: density / unit, dark: NoteRenderer.isDark(note.document.pages.first, dark: scheme == .dark), pageRoom: column.usable / unit, pageStride: column.stride / unit,
                                                        pageTops: column.tops.map { $0 / unit }, pageRooms: column.heights.indices.map { column.usable(onPage: $0) / unit },
                                                        left: column.left / unit, top: column.top / unit, unit: unit), layout: layout)
    }

    private func pages(_ note: LoadedNote, _ images: NoteImages, in size: CGSize) -> some View {
        let layout = NoteLayout(note.document, shown: session.visiblePages)
        let m = measures(note, layout, in: size)
        let at = min(currentPage, layout.pageCount - 1)
        // The text view turns the pointer's place into a place on a page with these.
        session.text.pages = layout
        return ScrollViewReader { reader in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: scroll == .twoPage ? .leading : .center, spacing: 10) {
                    titleField.frame(width: m.width)
                    switch scroll {
                    case .vertical:
                        // Every page, one under the other.
                        slot(note, images, layout, m, first: 0, count: layout.pageCount, live: true)
                            // The page a third of the way down the window is the one the note is at.
                            .onGeometryChange(for: Int.self) { geometry in
                                let top = geometry.frame(in: .scrollView).minY
                                return m.page(at: size.height / 3 - top)
                            } action: { page in
                                if currentPage != page { currentPage = page }
                            }
                    case .horizontal:
                        // One page at a time.
                        slot(note, images, layout, m, first: at, count: 1, live: true)
                    case .twoPage:
                        // Two pages side by side, as in an open book. The text is live on the page
                        // the note is at; the other shows it as it is stored, and a press turns to it.
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(stride(from: at - at % 2, to: min(at - at % 2 + 2, layout.pageCount), by: 1)), id: \.self) { index in
                                slot(note, images, layout, m, first: index, count: 1, live: index == at)
                            }
                        }
                    }
                }
                .padding(.vertical, 22)
                .frame(minWidth: size.width, minHeight: size.height, alignment: .top)
            }
            .onChange(of: jumpTo) {
                guard let page = jumpTo else { return }
                jumpTo = nil
                if scroll == .vertical { withAnimation { reader.scrollTo(page, anchor: .top) } } else { currentPage = page }
            }
        }
    }

    /// A run of the note's pages, one under the other, with all that lies on them: the pages
    /// themselves, the text, the ink and the pictures' handles. `live` puts the text view
    /// itself on them; without it the pages are drawn with the text as it is stored.
    private func slot(_ note: LoadedNote, _ images: NoteImages, _ layout: NoteLayout, _ m: Measures, first: Int, count: Int, live: Bool) -> some View {
        let dark = scheme == .dark
        let lift = m.top(first)
        let height = m.top(first + count - 1) + m.height(first + count - 1) - lift
        let range = first..<(first + count)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: m.gap) {
                ForEach(range, id: \.self) { index in
                    PageView(note: note, images: images, index: index, width: m.width, dark: dark, revision: session.pageRevisions[safe: index] ?? 0, text: !live)
                        .overlay {
                            // Beside the text's column the text view does not take the pointer: there the page does, for ⌥ and a drag over the PDF's text.
                            if live, !drawing, session.pdfText.isPDF(index) { PDFTextCatcher(controller: session.text) }
                            PDFTextMarks(selection: session.pdfText, page: index, unit: m.unit)
                        }
                        .frame(width: m.width, height: m.height(index))
                        .id(index)
                }
            }
            if live {
                RichTextEditor(controller: session.text, editable: session.canEdit && !drawing, metrics: m.metrics, textHeight: max(m.total - m.top, 10), lift: lift)
                    .frame(width: m.column, height: max(height - m.top, 10))
                    .padding(.leading, m.left)
                    .padding(.top, m.top)
                    .allowsHitTesting(!drawing)
            }
            VStack(spacing: m.gap) {
                ForEach(range, id: \.self) { index in
                    ZStack(alignment: .bottomTrailing) {
                        if drawing, session.canEdit {
                            overlay(page: index, layout: layout, m: m)
                            padBox(page: index, m: m)
                        } else if live {
                            Color.clear
                        } else {
                            // A page shown beside the one being worked on: a press turns to it.
                            Color.clear.contentShape(.rect).onTapGesture { currentPage = index; session.text.focus() }
                                .accessibilityLabel("Go to page \(index + 1)").accessibilityAddTraits(.isButton)
                        }
                        PageBadge(session: session, index: index, count: layout.pageCount)
                    }
                    .frame(width: m.width, height: m.height(index))
                }
            }
            pictureHandles(note: note, images: images, layout: layout, m: m, pages: range, lift: lift)
                .frame(width: m.width, height: height, alignment: .topLeading)
        }
        .frame(width: m.width, height: height, alignment: .topLeading)
        // Where the window's top edge is among the pages: a new text box is set down in view.
        .onGeometryChange(for: Double.self) { geometry in (-geometry.frame(in: .scrollView).minY).rounded() } action: { top in if live { viewport.top = top + lift } }
    }

    private var titleField: some View {
        @Bindable var session = session
        return TextField("Title", text: $session.title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 22 * min(max(zoom, 0.8), 1.6), weight: .semibold))
            .focused($titleFocused)
            .disabled(!session.canEdit)
            .onSubmit { session.text.focus() }
            .onChange(of: session.title) { session.titleChanged() }
            .padding(.horizontal, 6)
            .accessibilityLabel("Title")
    }

    private func overlay(page index: Int, layout: NoteLayout, m: Measures) -> some View {
        let unit = m.unit
        let size = pen.size(pageWidth: layout.pageWidth, pageHeight: layout.pageHeight)
        let picked: InkOverlay.Picked? = session.selection.flatMap { selection in
            guard selection.page == index else { return nil }
            let rect = CGRect(x: selection.bounds.minX / unit, y: selection.bounds.minY / unit, width: selection.bounds.width / unit, height: selection.bounds.height / unit)
            return InkOverlay.Picked(rect: rect, picture: pickedPicture, keepsShape: true, revision: pickedRevision)
        }
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * unit, y: p.y * unit) }
        return InkOverlay(
            tool: tool, shape: pen.shapeKind, color: PenChoice.nsColor(pen.liveColor), lineWidth: size / unit, highlighter: pen.active.isMarker || pen.active == .tape,
            straighten: pen.setting.straight ?? false, rectangle: picking.rectangle, pointer: pointing,
            onGrab: { where_ in
                session.selectBlock(at: point(where_), page: index, reach: max(6 * unit, 4)).map { CGRect(x: $0.minX / unit, y: $0.minY / unit, width: $0.width / unit, height: $0.height / unit) }
            },
            eraserRadius: eraser.area ? eraser.radius(pageWidth: layout.pageWidth) / unit : nil,
            dash: InkRenderer.dashLengths(lineType: pen.strokeStyle.lineType, sizeLevel: pen.strokeStyle.sizeLevel, penSize: size, pencil: pen.active == .pencil).map { [$0.dash / unit, $0.gap / unit] },
            onTap: { where_ in
                // With the Easy writing pad open, a press on the page says where its writing is to go.
                if padOn, let target = padTarget ?? firstPadTarget(session.note?.document) {
                    padTarget = PadTarget(page: index, origin: CGPoint(x: point(where_).x, y: point(where_).y - target.height / 2), height: target.height)
                    padUsed = 0
                    padRevision += 1
                    return true
                }
                return pen.taping && session.toggleTape(at: point(where_), page: index)
            },
            revision: session.pageRevisions[safe: index] ?? 0, picked: picked,
            onStroke: { pieces, pressures, times in
                let chosen = pen
                let writing = tool == .pen
                var style = writing ? chosen.strokeStyle : InkStroke.Style()
                style.topLayer = chosen.active.isMarker
                var strokes = pieces.map { piece in
                    NewStroke(points: piece.enumerated().map { InkPoint(x: $1.x * unit, y: $1.y * unit, pressure: pressures[safe: $0] ?? 1, time: times[safe: $0] ?? $0 * 4) },
                              argb: chosen.argb, penSize: size, pen: chosen.pen, style: style)
                }
                // "Straighten lines": the line from where the pen went down to where it came up, as the Windows client stores one.
                if writing, chosen.setting.straight == true, let drawn = strokes.first {
                    strokes = [NewStroke(points: InkEdit.straightened(drawn.points, pageWidth: layout.pageWidth, pageHeight: layout.height(index)), argb: chosen.argb, penSize: size, pen: chosen.pen, style: style)]
                }
                // "Adjust thickness to text": a highlighter or a tape drawn along a line of text covers that line, from where it began to where it ended.
                if writing, chosen.group != .pens, chosen.setting.fit == true, let drawn = strokes.first, let from = drawn.points.first, let to = drawn.points.last {
                    let across = CGRect(x: min(from.x, to.x), y: drawn.points.map(\.y).reduce(0, +) / Double(drawn.points.count) - 1, width: abs(to.x - from.x), height: 2)
                    if across.width > 4, let line = session.textLine(under: across, page: index) {
                        let ends = [InkPoint(x: across.minX, y: line.midY), InkPoint(x: across.maxX, y: line.midY)]
                        strokes = [NewStroke(points: InkEdit.straightened(ends, pageWidth: layout.pageWidth, pageHeight: layout.height(index)), argb: chosen.argb, penSize: line.height, pen: chosen.pen, style: style)]
                    }
                }
                session.draw(strokes, page: index, name: tool == .shape ? "Shape" : chosen.taping ? "Tape" : "Drawing")
            },
            onErase: { where_ in
                let only: NoteSession.InkFilter = eraser.tapeOnly ? .tapes : eraser.highlighterOnly ? .highlighters : .all
                if eraser.area {
                    session.eraseArea(at: point(where_), radius: eraser.radius(pageWidth: layout.pageWidth), page: index, only: only)
                } else {
                    session.erase(session.strokes(at: point(where_), page: index, reach: max(9 * unit, 6), only: only))
                }
            },
            onLasso: { loop in session.select(lasso: loop.map(point), page: index, partial: picking.partial, objects: pointing) },
            onPick: { where_ in session.select(at: point(where_), page: index, reach: max(6 * unit, 4)) },
            onTransform: { change in
                // From the view's points to the page's units and back around the change.
                session.transformSelection(CGAffineTransform(scaleX: 1 / unit, y: 1 / unit).concatenating(change).concatenating(CGAffineTransform(scaleX: unit, y: unit)))
            },
            onDelete: { session.deleteSelection() },
            onDropPicture: { board, where_ in
                guard let file = PictureFile(pasteboard: board) else { return false }
                // A third of the page's width, where it was dropped.
                let width = min(layout.pageWidth * 0.4, max(file.pixels.width, 40))
                let height = width * file.pixels.height / max(file.pixels.width, 1)
                let centre = point(where_)
                session.addPicture(file, onPage: (index, CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)))
                tool = .select
                return true
            })
    }

    // MARK: Easy writing pad

    private func firstPadTarget(_ document: NoteDocument?) -> PadTarget? {
        guard let document else { return nil }
        let column = TextColumn(document)
        return PadTarget.first(page: min(currentPage, max(session.visiblePages - 1, 0)), pageWidth: NoteLayout(document).pageWidth, left: column.left, top: column.top)
    }

    /// The pad at the foot of the note: its strokes go into the box on the page, as many times smaller as the box is lower than the pad.
    private func easyPad(_ document: NoteDocument) -> some View {
        let layout = NoteLayout(document)
        let column = TextColumn(document)
        let target = padTarget ?? firstPadTarget(document) ?? PadTarget(page: 0, origin: .zero, height: 60)
        let scale = target.height / EasyPad.height
        let size = pen.size(pageWidth: layout.pageWidth, pageHeight: layout.pageHeight)
        func move(to origin: CGPoint, page: Int? = nil) {
            padTarget = PadTarget(page: page ?? target.page, origin: origin, height: target.height)
            padUsed = 0
            padRevision += 1
        }
        func newLine() {
            var page = target.page
            var y = target.origin.y + target.height * 1.35
            if y + target.height > layout.height(page) - column.bottom, page + 1 < session.visiblePages { page += 1; y = column.top }
            move(to: CGPoint(x: column.left, y: min(y, layout.height(page) - target.height)), page: page)
        }
        func forward() {
            // On by what was written and a letter's space; past the page's edge, to the next line.
            let x = target.origin.x + (padUsed > 0 ? padUsed + 14 : EasyPad.padWidth * 0.4) * scale
            if x + target.height > layout.pageWidth - column.left { newLine() } else { move(to: CGPoint(x: x, y: target.origin.y)) }
        }
        func resize(_ factor: Double) {
            let height = min(max(target.height * factor, layout.pageWidth * 0.03), layout.pageWidth * 0.3)
            padTarget = PadTarget(page: target.page, origin: target.origin, height: height)
            padUsed = 0
            padRevision += 1
        }
        return EasyPad(pen: pen, width: EasyPad.padWidth, lineWidth: max(size / scale, 1), revision: padRevision, isEmpty: padUsed == 0,
                       onStroke: { pieces, pressures, times in
                           let chosen = pen
                           var style = chosen.strokeStyle
                           style.topLayer = chosen.active.isMarker
                           let strokes = pieces.map { piece in
                               NewStroke(points: piece.enumerated().map { InkPoint(x: target.origin.x + $1.x * scale, y: target.origin.y + $1.y * scale, pressure: pressures[safe: $0] ?? 1, time: times[safe: $0] ?? $0 * 4) },
                                         argb: chosen.argb, penSize: size, pen: chosen.pen, style: style)
                           }
                           session.draw(strokes, page: target.page, name: "Handwriting")
                           padUsed = max(padUsed, pieces.flatMap { $0 }.map(\.x).max() ?? 0)
                           if padTarget == nil { padTarget = target }
                           // Written past the line near the pad's edge: the pad makes room for what comes next.
                           if padUsed > EasyPad.padWidth * 0.85 { forward() }
                       },
                       back: { move(to: CGPoint(x: max(target.origin.x - EasyPad.padWidth * 0.4 * scale, column.left), y: target.origin.y)) },
                       forward: forward, newLine: newLine, smaller: { resize(1 / 1.2) }, larger: { resize(1.2) })
    }

    /// The box on a page that shows where the Easy writing pad's writing goes.
    @ViewBuilder private func padBox(page index: Int, m: Measures) -> some View {
        if padOn, drawing, tool == .pen, let target = padTarget ?? firstPadTarget(session.note?.document), target.page == index {
            let scale = target.height / EasyPad.height
            RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: EasyPad.padWidth * scale / m.unit, height: target.height / m.unit)
                .offset(x: target.origin.x / m.unit, y: target.origin.y / m.unit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// "Erase all handwriting": after asking, since it takes every stroke of the note (Undo brings them back).
    private func eraseAllInk() {
        let all = session.inkIDs
        guard !all.isEmpty else { return }
        Dialogs.confirm(title: String(localized: "Erase all handwriting?"), message: String(localized: "Everything written and drawn by hand in this note is erased. Text, pictures and the pages stay."),
                        action: String(localized: "Erase")) { session.erase(all, name: "Erase All Handwriting") }
    }

    /// The strokes or the picture that are picked, as one image for showing them while they are dragged.
    private func picture(of selection: InkSelection?) -> CGImage? {
        guard let selection, let note = session.note, selection.bounds.width > 0, selection.bounds.height > 0 else { return nil }
        let scale = min(1400 / max(selection.bounds.width, selection.bounds.height), 3)
        let width = Int((selection.bounds.width * scale).rounded(.up)), height = Int((selection.bounds.height * scale).rounded(.up))
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -selection.bounds.minX, y: -selection.bounds.minY)
        for id in selection.strokes { if let stroke = note.strokes[id] { InkRenderer.draw(stroke, in: context) } }
        return context.makeImage()
    }

    // MARK: Pictures on the pages

    /// A picture the pointer can pick, move, resize and turn.
    private struct Spot: Identifiable {
        let id: String
        /// The picture's own frame, not turned, in points in the pages' space.
        let frame: CGRect
        /// Degrees clockwise about the frame's middle.
        let angle: Double
        let inText: Bool
        let image: CGImage?
        /// A table: moved between paragraphs and opened to write in, never resized or turned.
        var table = false
        /// A sticky note of Samsung's own kind, folded up: moved about its page and opened by a click.
        var sticky = false
        /// A text box: moved, given a size by any handle, and opened to write in; never turned.
        var box = false
    }

    private func spots(_ note: LoadedNote, _ images: NoteImages, _ layout: NoteLayout, _ m: Measures) -> [Spot] {
        var out: [Spot] = []
        for object in note.document.floating where object.kind == .image || object.kind == .painting || (object.kind == .table && object.inText) {
            let size = CGSize(width: object.rect.width / m.unit, height: object.rect.height / m.unit)
            var middle: CGPoint
            if object.inText {
                // Where the text view has made room for it now, which is where it is drawn: in the middle of that room.
                guard let room = session.text.pictureFrames[object.id] else { continue }
                middle = CGPoint(x: room.midX + m.left, y: room.midY + m.top)
            } else {
                let page = min(max(object.pageIndex ?? 0, 0), layout.pageCount - 1)
                let origin = layout.pageRect(page).origin
                middle = CGPoint(x: (origin.x + object.rect.midX) / m.unit, y: (origin.y + object.rect.midY) / m.unit)
            }
            let frame = CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2, width: size.width, height: size.height)
            guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite, frame.width > 1, frame.height > 1 else { continue }
            if object.kind == .table {
                out.append(Spot(id: object.id, frame: frame, angle: 0, inText: true, image: session.tableImage(object), table: true))
                continue
            }
            out.append(Spot(id: object.id, frame: frame, angle: object.rotation.isFinite ? object.rotation : 0, inText: object.inText,
                            image: NoteRenderer.picture(of: object) { images.image($0) }))
        }
        for (index, page) in note.document.pages.enumerated() where index < layout.pageCount {
            let origin = layout.pageRect(index).origin
            for object in page.objects where object.kind == .sticky {
                let frame = CGRect(x: (origin.x + object.rect.minX) / m.unit, y: (origin.y + object.rect.minY) / m.unit, width: object.rect.width / m.unit, height: object.rect.height / m.unit)
                guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite, frame.width > 1, frame.height > 1 else { continue }
                out.append(Spot(id: object.id, frame: frame, angle: 0, inText: false, image: NoteRenderer.stickyImage(paper: object.paper, pixels: 72, padded: false), sticky: true))
            }
            for object in page.objects where object.kind == .textBox && object.id != boxLive?.id {
                let frame = CGRect(x: (origin.x + object.rect.minX) / m.unit, y: (origin.y + object.rect.minY) / m.unit, width: object.rect.width / m.unit, height: object.rect.height / m.unit)
                guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite, frame.width > 1, frame.height > 1 else { continue }
                out.append(Spot(id: object.id, frame: frame, angle: 0, inText: false, image: nil, box: true))
            }
        }
        return out
    }

    /// Where a sticky note lies open: a square from its folded square's corner, kept on its page.
    private func openFrame(ofSticky folded: CGRect, m: Measures) -> CGRect {
        let side = min(max(m.width * 0.4, 220), min(320, m.width - 16))
        let page = m.page(at: folded.midY)
        let top = m.top(page)
        let x = min(max(folded.minX, 8), max(m.width - side - 8, 8))
        let y = min(max(folded.minY, top + 8), max(top + m.height(page) - side - 8, top + 8))
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// Handles over the note's pictures: press one anywhere to pick it and move it at once;
    /// drag a handle to resize, the one above it to turn. They are there when typing and with
    /// the selection tool, and out of the way of the pens.
    /// `pages` are the pages shown where the handles are laid, and `lift` how far down the note
    /// they begin: the handles of the pictures on those pages are shown, moved up by that much.
    @ViewBuilder private func pictureHandles(note: LoadedNote, images: NoteImages, layout: NoteLayout, m: Measures, pages: Range<Int>, lift: Double) -> some View {
        let here = spots(note, images, layout, m).filter { pages.contains(m.page(at: $0.frame.midY)) }
        if session.canEdit, let cropping = session.cropping {
            if let spot = here.first(where: { $0.id == cropping.id }), let object = session.pictureObject(cropping.id) {
                cropper(spot, object, cropping, images: images, layout: layout, m: m, lift: lift)
            }
        } else if session.canEdit, !drawing || tool == .select {
            ZStack(alignment: .topLeading) {
                ForEach(here.filter { $0.id != live?.id && $0.id != tableLive?.id }) { spot in
                    PictureHandles(
                        frame: spot.frame.offsetBy(dx: 0, dy: -lift), angle: spot.angle, image: spot.image, picked: session.pictureSelection == spot.id && !spot.sticky, plain: spot.table || spot.sticky,
                        clickOpens: spot.sticky, box: spot.box,
                        pick: { if spot.sticky { commitSmart() } else { commitBox(); session.pointAtPicture(spot.id) } },
                        moved: { shown in
                            // From where it is shown to its place among all the note's pages.
                            let dropped = shown.offsetBy(dx: 0, dy: lift)
                            if spot.sticky {
                                let to = pagePlace(dropped, layout: layout, m: m)
                                session.moveSticky(spot.id, to: to.rect, page: to.page)
                            } else if spot.box {
                                let to = pagePlace(dropped, layout: layout, m: m)
                                session.changeTextBox(spot.id, rect: to.rect, page: to.page, name: "Move Text Box")
                            } else if spot.inText {
                                // The room it takes, in the text view's points: the pages' space less where the text view starts.
                                let room = NoteObject.turned(dropped.size, by: spot.angle)
                                let frame = CGRect(x: dropped.midX - room.width / 2 - m.left, y: dropped.midY - room.height / 2 - m.top, width: room.width, height: room.height)
                                session.text.moveObject(spot.id, droppedFrame: frame)
                            } else {
                                place(spot.id, at: dropped, layout: layout, m: m)
                            }
                        },
                        resized: { shown in
                            let changed = shown.offsetBy(dx: 0, dy: lift)
                            if spot.box {
                                // Given a size by hand, it keeps it: it no longer grows with its text.
                                let to = pagePlace(changed, layout: layout, m: m)
                                session.changeTextBox(spot.id, rect: to.rect, page: session.textBoxObject(spot.id)?.page, grows: false, name: "Resize Text Box")
                            } else if spot.inText {
                                session.resizePicture(spot.id, to: CGSize(width: changed.width * m.unit, height: changed.height * m.unit))
                            } else {
                                place(spot.id, at: changed, layout: layout, m: m)
                            }
                        },
                        turned: { angle in session.rotatePicture(spot.id, to: angle) },
                        delete: { session.removePicture(spot.id); session.pickPicture(nil) },
                        menu: { view in pictureMenu(spot, from: view, layout: layout, m: m) },
                        // A double click opens a sticky note or a table made here to change it; any other picture, to crop it.
                        open: {
                            if spot.box { beginBox(spot.id) } else if spot.table || spot.sticky || session.smartContent(spot.id) != nil { beginSmart(spot.id) } else if spot.image != nil { startCrop(spot.id, lasso: false) }
                        })
                }
                // A text box that is being written in: its letters are the editor's, in the box's place.
                if let open = boxLive, pages.contains(open.page) {
                    boxInPlace(open, m: m, lift: lift)
                }
                // A sticky note or a table that is being written in lies open in its place, over the others.
                if let live, let spot = here.first(where: { $0.id == live.id }) {
                    smartInPlace(live, at: (spot.sticky ? openFrame(ofSticky: spot.frame, m: m) : spot.frame).offsetBy(dx: 0, dy: -lift))
                }
                if let tableLive, let spot = here.first(where: { $0.id == tableLive.id }) {
                    tableInPlace(tableLive, at: spot.frame.offsetBy(dx: 0, dy: -lift), m: m)
                }
            }
        }
    }

    /// A frame given in the pages' points as a place on a page: the page its middle is over,
    /// and the frame in that page's units.
    private func pagePlace(_ frame: CGRect, layout: NoteLayout, m: Measures) -> (page: Int, rect: CGRect) {
        let page = m.page(at: frame.midY)
        let top = m.top(page)
        return (page, CGRect(x: frame.minX * m.unit, y: (frame.minY - top) * m.unit, width: frame.width * m.unit, height: frame.height * m.unit))
    }

    /// Puts a picture that lies freely on a page at a frame given in the pages' points.
    private func place(_ id: String, at frame: CGRect, layout: NoteLayout, m: Measures) {
        let to = pagePlace(frame, layout: layout, m: m)
        session.movePicture(id, to: to.rect, page: to.page)
    }

    /// The menu of a right click on a picture, as the original has it.
    private func pictureMenu(_ spot: Spot, from view: NSView, layout: NoteLayout, m: Measures) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let id = spot.id
        if spot.box {
            menu.addItem(ActionMenuItem("Edit Text", symbol: "character.cursor.ibeam") { beginBox(id) })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Delete", symbol: "trash") { session.removeTextBox(id) })
            return menu
        }
        if spot.sticky {
            menu.addItem(ActionMenuItem("Open Sticky Note", symbol: "note.text") { beginSmart(id) })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Delete", symbol: "trash") { if live?.id == id { live = nil }; session.removeSticky(id) })
            return menu
        }
        if spot.table {
            // A table is written in and deleted; it is not a picture to crop or share.
            menu.addItem(ActionMenuItem("Edit Table", symbol: "square.and.pencil") { beginSmart(id) })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Delete", symbol: "trash") { session.removePicture(id); session.pickPicture(nil) })
            return menu
        }
        if let content = session.smartContent(id) {
            menu.addItem(ActionMenuItem("Edit \(content.name)", symbol: "square.and.pencil") { beginSmart(id) })
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem("Cut", symbol: "scissors") { session.cutPicture(id) })
        menu.addItem(ActionMenuItem("Copy", symbol: "doc.on.doc") { session.copyPicture(id) })
        menu.addItem(ActionMenuItem("Paste", symbol: "doc.on.clipboard", enabled: NoteSession.canPaste) { session.paste(nextTo: id) })
        menu.addItem(ActionMenuItem("Delete", symbol: "trash") { session.removePicture(id); session.pickPicture(nil) })
        menu.addItem(.separator())
        // Only a picture with a file of its own: a painting keeps its picture another way.
        let croppable = spot.image != nil && session.pictureObject(id)?.imageID != nil
        menu.addItem(ActionMenuItem("Crop", symbol: "crop", enabled: croppable) { startCrop(id, lasso: false) })
        menu.addItem(ActionMenuItem("Lasso Crop", symbol: "lasso", enabled: croppable) { startCrop(id, lasso: true) })
        menu.addItem(.separator())
        if spot.inText {
            menu.addItem(ActionMenuItem("Remove Anchor to Text", symbol: "pin.slash") {
                let to = pagePlace(spot.frame, layout: layout, m: m)
                session.freePicture(id, at: to.rect, page: to.page)
            })
        } else {
            menu.addItem(ActionMenuItem("Anchor to Text", symbol: "pin") {
                // The room it takes, in the text view's points.
                let room = NoteObject.turned(spot.frame.size, by: spot.angle)
                let frame = CGRect(x: spot.frame.midX - room.width / 2 - m.left, y: spot.frame.midY - room.height / 2 - m.top, width: room.width, height: room.height)
                session.anchorPicture(id, at: session.text.boundary(forDroppedFrame: frame))
            })
        }
        menu.addItem(ActionMenuItem("Fit to Page Width", symbol: "arrow.left.and.right") { session.fitPictureToPageWidth(id) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Share…", symbol: "square.and.arrow.up") { session.sharePicture(id, from: view) })
        menu.addItem(ActionMenuItem("Save Image…", symbol: "square.and.arrow.down") { session.savePicture(id) })
        return menu
    }

    // MARK: Sticky notes and tables, written in place

    /// Opens a sticky note or a table to be written in where it stands.
    private func beginSmart(_ id: String) {
        guard session.canEdit, live?.id != id, tableLive?.id != id else { return }
        if let object = session.pictureObject(id), object.kind == .table {
            guard let table = object.table else {
                model.lastError = "This table has merged cells, which this Mac does not write. It is shown as it is."
                return
            }
            commitSmart()
            if drawing { drawing = false }
            session.cropping = nil
            session.pickPicture(id)
            tableLive = TableLive(id: id, table: table)
            return
        }
        if let sticky = session.stickyObject(id)?.object {
            // A sticky note of Samsung's own kind: what it says is in its own file.
            guard sticky.sticky != nil else {
                model.lastError = "This sticky note's own file is not on this Mac yet, or cannot be read. Sync the note and try again."
                return
            }
            commitSmart()
            if drawing { drawing = false }
            session.cropping = nil
            session.pickPicture(id)
            let content = SmartPicture.Sticky(text: sticky.sticky?.text ?? "", color: sticky.paper ?? sticky.sticky?.paper ?? StickyDocument.papers[0])
            live = SmartLive(id: id, content: .sticky(content), original: .sticky(content), real: true)
            return
        }
        // Kept as a picture by an earlier build of this app: it becomes one of Samsung's own
        // kind, which every client shows and changes, and that one is opened.
        guard let content = session.smartContent(id) else { return }
        commitSmart()
        if drawing { drawing = false }
        session.cropping = nil
        awaiting = session.convert(id, from: content)
    }

    /// Done writing: what the sticky note or the table now says is stored.
    private func commitSmart() {
        commitBox()
        if let done = tableLive {
            tableLive = nil
            if done.table != done.original { session.setTable(done.table) }
            if session.pictureSelection == done.id { session.pickPicture(nil) }
        }
        guard let done = live else { return }
        live = nil
        if done.content != done.original, case .sticky(let sticky) = done.content { session.changeSticky(done.id, text: sticky.text, paper: sticky.color) }
        if session.pictureSelection == done.id { session.pickPicture(nil) }
    }

    // MARK: Text boxes

    /// A new text box, where the page is being looked at, open to be written in at once. It is
    /// put into the note when something has been written in it.
    private func newBox() {
        guard session.canEdit, let place = session.newTextBoxPlace(viewTop: viewport.top) else { return }
        commitSmart()
        if drawing { drawing = false }
        session.cropping = nil
        session.pickPicture(nil)
        boxLive = BoxLive(id: UUID().uuidString.lowercased(), page: place.page, rect: place.rect, text: "", original: "", isNew: true)
    }

    /// Opens a text box to be written in where it stands.
    private func beginBox(_ id: String) {
        guard session.canEdit, boxLive?.id != id, let found = session.textBoxObject(id) else { return }
        commitSmart()
        if drawing { drawing = false }
        session.cropping = nil
        session.pickPicture(nil)
        let said = found.object.text?.plain ?? ""
        let look = found.object.text?.runs.first
        boxLive = BoxLive(id: id, page: found.page, rect: found.object.rect, text: said, original: said, grows: found.object.growsWithText,
                          fontSize: look?.fontSize ?? NoteFile.textBoxFontSize, color: look?.color ?? 0xFF25_2525, bold: look?.bold ?? false, italic: look?.italic ?? false)
        session.hideTextBoxText(id)
    }

    /// The frame a box needs for what it says now: as wide as it is, and as high as its lines.
    private func grown(_ open: BoxLive) -> CGRect {
        guard let sheet = session.note?.document.pages[safe: open.page] else { return open.rect }
        let needed = NoteFile.textBoxHeight(open.text, width: open.rect.width, pageWidth: sheet.width, fontSize: open.fontSize)
        var rect = open.rect
        // One the user gave a size keeps it, unless its text no longer fits.
        rect.size.height = open.grows ? needed : max(rect.height, needed)
        return rect
    }

    /// Done writing: what the box now says is stored. One with nothing in it is not kept.
    private func commitBox() {
        guard let done = boxLive else { return }
        boxLive = nil
        session.hideTextBoxText(nil)
        let said = done.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : done.text
        if done.isNew {
            if !said.isEmpty { session.addTextBox(page: done.page, rect: grown(done), text: said, id: done.id) }
        } else if said.isEmpty {
            session.removeTextBox(done.id)
        } else if said != done.original {
            session.changeTextBox(done.id, text: said, rect: grown(done))
        }
        session.text.focus()
    }

    private func boxInPlace(_ open: BoxLive, m: Measures, lift: Double) -> some View {
        let rect = grown(open)
        let frame = CGRect(x: rect.minX / m.unit, y: m.top(open.page) + rect.minY / m.unit - lift, width: rect.width / m.unit, height: rect.height / m.unit)
        let dark = NoteRenderer.isDark(session.note?.document.pages[safe: open.page], dark: scheme == .dark)
        let ink = NSColor(PenChoice.color(NoteRenderer.adapted(open.color, dark: dark)))
        return TextBoxEditor(text: Binding(get: { boxLive?.text ?? open.text }, set: { boxLive?.text = $0 }), scale: m.metrics.scale, fontSize: open.fontSize, color: ink,
                             bold: open.bold, italic: open.italic, done: commitBox)
            .frame(width: frame.width, height: frame.height)
            .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5).allowsHitTesting(false) }
            .offset(x: frame.minX, y: frame.minY)
    }

    /// What a scripted check asks of the text boxes.
    private func remoteBox(_ asked: EditorRemote.BoxAction) {
        switch asked {
        case .new: newBox()
        case .begin(let id): beginBox(id)
        case .done: commitBox()
        }
    }

    /// A sticky note lying open on its page.
    @ViewBuilder private func smartInPlace(_ live: SmartLive, at frame: CGRect) -> some View {
        if case .sticky(let sticky) = live.content {
            let now = Binding<SmartPicture.Sticky>(get: { if case .sticky(let now) = self.live?.content { return now }; return sticky }, set: { self.live?.content = .sticky($0) })
            let found = session.stickyObject(live.id)?.object
            StickyOpen(text: now.text, paper: now.color, side: frame.width, fontSize: max(session.text.metrics.scale * 12, 9),
                       editable: found?.stickyIsExact == true, delete: { self.live = nil; session.removeSticky(live.id) }, close: commitSmart)
                // A press on its paper stays here instead of falling through to the note's text.
                .background { PointerShield() }
                .onExitCommand { commitSmart() }
                .offset(x: frame.minX, y: frame.minY)
        }
    }

    /// A table lying open where it stands: its top left corner at the corner of the table as it is drawn.
    @ViewBuilder private func tableInPlace(_ open: TableLive, at frame: CGRect, m: Measures) -> some View {
        if let document = session.note?.document {
            let page = document.pages[safe: session.pictureObject(open.id)?.pageIndex ?? 0]
            TableEditor(live: open, scale: 1 / m.unit,
                        paper: Color(cgColor: NoteRenderer.pageColor(page, dark: scheme == .dark)), dark: NoteRenderer.isDark(page, dark: scheme == .dark), covers: frame.size)
                .onExitCommand { commitSmart() }
                .offset(x: frame.minX - TableEditor.margin, y: frame.minY - TableEditor.margin)
        }
    }

    private func startCrop(_ id: String, lasso: Bool) {
        // Not a painting, and not a picture whose cut-out is still being stored.
        guard let object = session.pictureObject(id), object.imageID != nil, object.outline == nil else { return }
        session.pickPicture(id)
        session.cropping = NoteSession.Cropping(id: id, lasso: lasso)
    }

    static let wholePicture = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The scroll direction is a matter of how a note is looked at on this Mac: it is kept in
    /// the app's settings for each note, not in the note.
    static func rememberedScroll(_ noteID: String) -> ScrollDirection { remembers ? ScrollDirection.remembered(for: noteID) : .vertical }

    static func remember(_ scroll: ScrollDirection, for noteID: String) {
        if remembers { scroll.remember(for: noteID) }
    }

    /// The picture being cropped, whole, with the part that is kept marked on it.
    private func cropper(_ spot: Spot, _ object: NoteObject, _ cropping: NoteSession.Cropping, images: NoteImages, layout: NoteLayout, m: Measures, lift: Double) -> some View {
        // The whole picture lies around the part shown so far, at the same scale. Worked out
        // where the picture is shown: `lift` above its place among all the note's pages.
        let shown = object.crop ?? NoteScreen.wholePicture
        let part = spot.frame.offsetBy(dx: 0, dy: -lift)
        let size = CGSize(width: part.width / max(shown.width, 0.001), height: part.height / max(shown.height, 0.001))
        let whole = CGRect(x: part.minX - shown.minX * size.width, y: part.minY - shown.minY * size.height, width: size.width, height: size.height)
        let pivot = CGPoint(x: part.midX, y: part.midY)
        let paper = NSColor(cgColor: NoteRenderer.pageColor(session.note?.document.pages[safe: object.pageIndex ?? 0], dark: scheme == .dark)) ?? .white
        func keep(_ part: CGRect, loop: [CGPoint]? = nil, restore: Bool = false) {
            // The kept part's frame along the picture's own sides, then its middle turned with the picture.
            let frame = CGRect(x: whole.minX + part.minX * whole.width, y: whole.minY + part.minY * whole.height, width: part.width * whole.width, height: part.height * whole.height)
            let arm = PictureHandles.turn(CGSize(width: frame.midX - pivot.x, height: frame.midY - pivot.y), by: spot.angle)
            let placed = CGRect(x: pivot.x + arm.width - frame.width / 2, y: pivot.y + arm.height - frame.height / 2 + lift, width: frame.width, height: frame.height)
            let to = pagePlace(placed, layout: layout, m: m)
            if let loop {
                session.lassoPicture(spot.id, loop: loop, rect: to.rect, page: to.page)
            } else {
                session.cropPicture(spot.id, crop: part, restore: restore, rect: to.rect, page: to.page)
            }
            session.cropping = nil
        }
        // A loop is drawn on the picture as it first was; the rectangle is set on the one shown.
        let file = cropping.lasso ? object.originalImageID ?? object.pictureFile : object.pictureFile
        return CropView(whole: whole, angle: spot.angle, pivot: pivot, image: file.flatMap { images.image($0) }, lasso: cropping.lasso, paper: paper,
                        crop: $cropRect,
                        looped: { loop in
                            let box = loop.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                            guard box.width > 0, box.height > 0 else { return }
                            keep(box, loop: loop)
                        },
                        done: { keep(cropRect) },
                        cancel: { session.cropping = nil })
            .onAppear { cropDone = { keep(cropRect) }; cropReset = { keep(NoteScreen.wholePicture, restore: true) } }
            .onChange(of: cropRect) { cropDone = { keep(cropRect) } }
    }

    /// Takes the crop off a picture: all of it is shown again, where the part shown lay.
    private func resetCrop(_ id: String) {
        cropRect = NoteScreen.wholePicture
        cropReset?()
    }

    private func insert(_ kind: InsertKind) {
        switch kind {
        case .image: choosePicture()
        case .pdf: choosePDF()
        case .drawing: showDrawing = true
        case .voice: session.startRecording()
        case .audio: chooseAudio()
        case .sticky:
            // An empty one on the page being looked at, open to be written on at once.
            commitSmart()
            awaiting = session.addSticky(page: min(currentPage, max(session.visiblePages - 1, 0)))
        case .table:
            commitSmart()
            tableSetup = true
        }
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Insert"
        panel.message = "Each page of the PDF becomes a page of the note."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.addPDF(url) { first in if let first { currentPage = first; jumpTo = first } }
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Insert"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.addRecording(from: url)
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Insert"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let offset = drawing ? nil : Optional(session.text.selection.lowerBound)
        Task {
            // Read and, where needed, converted off the main thread; each lands after the one before it.
            let read = await Task.detached(priority: .userInitiated) { urls.map { url in ((try? Data(contentsOf: url)).flatMap { PictureFile(data: $0) }, url.lastPathComponent) } }.value
            // At the caret the last goes in first, so that they end up in the order chosen; at the end of the text, in that order.
            for (file, name) in offset == nil ? read : read.reversed() {
                guard let file else {
                    model.lastError = "“\(name)” is not a picture this Mac can read."
                    continue
                }
                session.addPicture(file, at: offset)
            }
        }
    }

    // MARK: Around the pages

    @ViewBuilder private var banner: some View {
        if let text = session.notice ?? model.lastError {
            HStack(spacing: 10) {
                Image(systemName: session.notice != nil ? "doc.on.doc" : "exclamationmark.triangle.fill").foregroundStyle(session.notice != nil ? Color.accentColor : .orange)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button { if session.notice != nil { session.notice = nil } else { model.lastError = nil } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: 560)
            .floatingBar()
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    /// Turns to another page of a note shown a page at a time (or two at a time).
    private func turn(by step: Int) {
        let size = scroll == .twoPage ? 2 : 1
        let from = scroll == .twoPage ? currentPage - currentPage % 2 : currentPage
        currentPage = min(max(from + step * size, 0), max(session.visiblePages - 1, 0))
    }

    private var pager: some View {
        let count = session.visiblePages
        let at = min(currentPage, max(count - 1, 0))
        let last = scroll == .twoPage ? at - at % 2 + 2 >= count : at >= count - 1
        return HStack(spacing: 6) {
            Button { turn(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 22).contentShape(.rect) }
                .disabled(scroll == .twoPage ? at < 2 : at == 0).hoverHighlight(radius: 7).help("Previous page").accessibilityLabel("Previous page")
            Text("\(at + 1) / \(count)").font(.callout.monospacedDigit()).frame(minWidth: 48)
            Button { turn(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 22).contentShape(.rect) }
                .disabled(last).hoverHighlight(radius: 7).help("Next page").accessibilityLabel("Next page")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .floatingBar()
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var zoomControl: some View {
        VStack(spacing: 2) {
            Button { zoom = min(zoom + 0.25, 4) } label: { Image(systemName: "plus").frame(width: 30, height: 28).contentShape(.rect) }.hoverHighlight().named("Zoom in")
            Button { zoom = 1 } label: { Text("\(Int(zoom * 100))%").font(.caption2.monospacedDigit()).frame(width: 40, height: 20).contentShape(.rect) }
                .hoverHighlight(radius: 7).named("Zoom: \(Int(zoom * 100))%. Click for actual size")
            Button { zoom = max(zoom - 0.25, 0.4) } label: { Image(systemName: "minus").frame(width: 30, height: 28).contentShape(.rect) }.hoverHighlight().named("Zoom out")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .floatingBar()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }

    @ToolbarContentBuilder private func toolbar(_ item: NoteItem?) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // With saving as one types switched off: what is typed waits here to be stored.
            if !model.autoSave, session.unsaved {
                Button { session.saveNow() } label: { Label("Save", systemImage: "square.and.arrow.down.on.square") }
                    .help("Store what you typed (⌘S). Auto save is off in Settings.")
            }
            if let item {
                Button { model.setFavorite(noteID, !item.record.isFavorite) } label: {
                    Label(item.record.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: item.record.isFavorite ? "star.fill" : "star")
                }
                .help(item.record.isFavorite ? "Remove from favorites" : "Add to favorites")
                Button { session.flush(); model.setTrashed([noteID], !session.isTrashed) } label: {
                    Label(session.isTrashed ? "Restore" : "Move to Trash", systemImage: session.isTrashed ? "arrow.uturn.backward" : "trash")
                }
                .help(session.isTrashed ? "Restore" : "Move to trash")
            }
            // Writes text to order at the caret, with the Mac's own language model.
            if model.writesWithAI { WriteWithAI(session: session) }
            Button { showStyle.toggle() } label: { Label("Note Style", systemImage: "paintpalette") }
                .help("Note style: scroll direction, paper colour and templates")
                .disabled(!session.canEdit)
                .popover(isPresented: $showStyle, arrowEdge: .bottom) {
                    NoteStylePanel(session: session, page: min(currentPage, max(session.visiblePages - 1, 0)), scroll: $scroll, dark: scheme == .dark)
                }
            Button { session.finding.toggle() } label: { Label("Find", systemImage: "magnifyingglass") }
                .help("Find in this note (⌘F)")
                .disabled(session.note == nil || session.isLocked)
            Button { withAnimation(.easeOut(duration: 0.18)) { showPages.toggle() } } label: { Label(showPages ? "Hide Pages" : "Show Pages", systemImage: "sidebar.squares.left") }
                .help(showPages ? "Hide the pages" : "Show the pages: go to one, add, move and delete pages")
                .disabled(session.note == nil || session.isLocked)
            if let item, session.note != nil {
                // Locking, as the Windows client's menu has it; a locked note that is open here can have its lock taken off.
                Button { model.askToLock([noteID], !item.record.isLocked) } label: { Label(item.record.isLocked ? "Unlock Note" : "Lock Note", systemImage: item.record.isLocked ? "lock.open" : "lock") }
                    .help(item.record.isLocked ? "Take the lock off this note" : "Lock this note: it then asks for Touch ID here, and for your notes password in Samsung Notes")
                    .disabled(session.isLocked || session.isTrashed)
            }
            Menu {
                Button("Export as PDF…", systemImage: "arrow.down.doc") { session.flush(); NoteExport.export([noteID], in: model) }
                Button("Export as Pictures…", systemImage: "photo.on.rectangle") { session.flush(); NoteFiles.exportPictures(noteID, in: model) }
                Button("Export as Text…", systemImage: "doc.plaintext") { session.flush(); NoteFiles.exportText(noteID, in: model) }
                Divider()
                Button("Share…", systemImage: "square.and.arrow.up") { session.flush(); NoteExport.share([noteID], in: model) }
                Button("Print…", systemImage: "printer") { session.flush(); NoteExport.print([noteID], in: model) }
            } label: { Label("Share and Export", systemImage: "square.and.arrow.up") }
                // A locked note stays on this Mac: it is not exported, shared or printed.
                .help(item?.record.isLocked == true ? "Locked notes cannot be exported, shared or printed" : "Share, export or print")
                .disabled(session.note == nil || item?.record.isLocked == true)
            Button { showInfo.toggle() } label: { Label("Info", systemImage: "info.circle") }
                .help("Note details")
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { info(item) }
        }
    }

    private func info(_ item: NoteItem?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                LabeledContent("Created", value: Format.stamp(item.record.createdAt))
                LabeledContent("Modified", value: Format.stamp(item.date))
                if !item.record.deviceName.isEmpty { LabeledContent("Last edited on", value: item.record.deviceName) }
                if let note = session.note {
                    LabeledContent("Pages", value: "\(session.visiblePages)")
                    if session.hiddenPages > 0 {
                        Text(session.hiddenPages == 1 ? "An empty page is kept at the end, as Samsung Notes does, and is not shown."
                             : "\(session.hiddenPages) empty pages are kept at the end, as Samsung Notes does, and are not shown.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 260, alignment: .leading)
                    }
                    if !note.strokes.isEmpty { LabeledContent("Pen strokes", value: "\(note.strokes.count)") }
                }
                LabeledContent("Size", value: Format.bytes(item.record.bytes))
                if item.record.isLocked { Label("Locked on your Galaxy devices", systemImage: "lock.fill").foregroundStyle(.secondary) }
                if item.record.pending != nil { Label("Waiting to be sent to Samsung Cloud", systemImage: "arrow.up.circle").foregroundStyle(.secondary) }
                if session.isTrashed { Label("In the Trash: restore it to make changes", systemImage: "trash").foregroundStyle(.secondary) }
            }
        }
        .padding(16)
        .frame(minWidth: 260)
    }
}

/// A locked note: shown after Touch ID, or the Mac's password where Touch ID is not to be had.
private struct LockGate: View {
    let session: NoteSession
    @State private var failed: String?

    var body: some View {
        ContentUnavailableView {
            Label("This note is locked", systemImage: "lock.fill")
        } description: {
            Text(failed ?? "Unlock it with Touch ID or your Mac's password.")
        } actions: {
            Button("Unlock") { unlock() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    private func unlock() {
        guard LockPrompt.canUseTouchID() else {
            failed = "This Mac has no password or Touch ID to check with, so locked notes stay closed."
            return
        }
        LockPrompt.touchID("open a locked note") { ok in
            if ok { session.unlocked = true } else { failed = "The note stays locked." }
        }
    }
}

/// The number at the foot of a page, with what can be done to the page.
private struct PageBadge: View {
    let session: NoteSession
    let index: Int
    let count: Int

    var body: some View {
        Menu {
            if session.canEdit {
                Button("Add Page After", systemImage: "plus.rectangle.on.rectangle") { session.addPage(after: index) }
                Button("Move Page Up", systemImage: "arrow.up") { session.movePage(index, to: index - 1) }.disabled(index == 0)
                Button("Move Page Down", systemImage: "arrow.down") { session.movePage(index, to: index + 1) }.disabled(index >= count - 1)
                Divider()
                Button("Delete Page", systemImage: "trash", role: .destructive) { session.removePage(index) }.disabled(count <= 1)
            }
        } label: {
            Text("\(index + 1)/\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(8)
        .accessibilityLabel("Page \(index + 1) of \(count)")
        .help("Page \(index + 1) of \(count)")
    }
}

/// One page, drawn off the main thread at the screen's resolution and drawn again when it
/// changes or its size does. `text` is false where a text view shows the note's text itself.
struct PageView: View {
    let note: LoadedNote
    let images: NoteImages
    let index: Int
    let width: Double
    let dark: Bool
    /// Moves when this page changed: it is drawn again at once.
    var revision: Int = 0
    var text = true
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var drawnPixels = 0
    /// How many times this view has drawn its page: only a redraw for a new size waits a moment.
    @State private var draws = 0

    init(note: LoadedNote, images: NoteImages, index: Int, width: Double, dark: Bool, revision: Int = 0, text: Bool = true) {
        self.note = note; self.images = images; self.index = index; self.width = width; self.dark = dark; self.revision = revision; self.text = text
        // The page as it was last drawn, at about this size: shown at once, while it is drawn anew if need be.
        let kept = PageView.kept.object(forKey: PageView.key(note, index, dark: dark, revision: revision, text: text, small: width < 300))
        _image = State(initialValue: kept?.image)
        _drawnPixels = State(initialValue: kept?.pixels ?? 0)
    }

    final class Kept {
        let image: CGImage
        let pixels: Int
        init(_ image: CGImage, pixels: Int) { self.image = image; self.pixels = pixels }
    }
    static let kept: NSCache<NSString, Kept> = {
        let cache = NSCache<NSString, Kept>()
        cache.countLimit = 80
        return cache
    }()

    static func key(_ note: LoadedNote, _ index: Int, dark: Bool, revision: Int, text: Bool, small: Bool) -> NSString {
        "\(note.directory.path)|\(index)|\(dark)|\(revision)|\(text)|\(small)" as NSString
    }

    /// Draws a note's first pages ahead of showing it, so that they are there in its first frame.
    static func drawAhead(_ note: LoadedNote, images: NoteImages, pages: Range<Int>, revisions: [Int], pixels: Int, dark: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for index in pages {
                let revision = revisions[safe: index] ?? 0
                group.addTask {
                    guard let drawn = NoteRenderer.pageImage(note, page: index, pixelWidth: pixels, dark: dark, body: false, images: { images.image($0) }) else { return }
                    await MainActor.run { PageView.kept.setObject(Kept(drawn, pixels: pixels), forKey: PageView.key(note, index, dark: dark, revision: revision, text: false, small: false)) }
                }
            }
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color(cgColor: NoteRenderer.pageColor(index < note.document.pages.count ? note.document.pages[index] : nil, dark: dark)))
            if let image {
                Image(decorative: image, scale: displayScale).resizable().interpolation(.high)
            }
        }
        .clipShape(.rect(cornerRadius: 3))
        .shadow(color: .black.opacity(dark ? 0.5 : 0.14), radius: 10, y: 3)
        .task(id: "\(Int(width))|\(dark)|\(displayScale)|\(revision)|\(text)") {
            let pixels = Int(width * displayScale)
            // Already drawn at this size: nothing to do.
            if image != nil, drawnPixels == pixels { return }
            // A short pause, so that dragging the window's edge does not redraw for every size on the way.
            if image != nil, draws > 0 { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            let note = note, images = images, index = index, dark = dark, text = text
            let rendered = await Task.detached(priority: .userInitiated) {
                NoteRenderer.pageImage(note, page: index, pixelWidth: pixels, dark: dark, body: text) { images.image($0) }
            }.value
            if !Task.isCancelled, let rendered {
                image = rendered
                drawnPixels = pixels
                draws += 1
                PageView.kept.setObject(Kept(rendered, pixels: pixels), forKey: PageView.key(note, index, dark: dark, revision: revision, text: text, small: width < 300))
            }
        }
    }
}

/// The frame and handles of a picture: eight to resize by, one above it to turn it by, a button
/// to delete, and the picture itself to move by. Everything is in points of the pages' space;
/// `frame` is the picture's own frame and `angle` how far it is turned about its middle.
private struct PictureHandles: View {
    let frame: CGRect
    let angle: Double
    let image: CGImage?
    let picked: Bool
    /// Without the handles to resize and turn by: for what is only moved and deleted.
    var plain = false
    /// One click opens it, as a double click does anything else.
    var clickOpens = false
    /// A text box: any handle gives it a size freely, and there is none to turn it by.
    var box = false
    let pick: () -> Void
    /// The frame it was dropped at.
    let moved: (CGRect) -> Void
    /// The frame it was given by a handle.
    let resized: (CGRect) -> Void
    /// The angle it was turned to.
    let turned: (Double) -> Void
    let delete: () -> Void
    var menu: ((NSView) -> NSMenu?)?
    var open: (() -> Void)?

    /// The picture as it is being changed, while the pointer is down.
    private struct Live: Equatable {
        var frame: CGRect
        var angle: Double
    }

    @State private var live: Live?

    private static let smallest: CGFloat = 28

    fileprivate static func turn(_ vector: CGSize, by degrees: Double) -> CGSize {
        let radians = degrees * .pi / 180
        return CGSize(width: vector.width * cos(radians) - vector.height * sin(radians), height: vector.width * sin(radians) + vector.height * cos(radians))
    }

    /// The frame after a handle was pulled: measured along the picture's own sides, the side
    /// opposite the handle stays where it is, and corners keep the picture's proportions.
    private func resizedFrame(_ index: Int, _ translation: CGSize) -> CGRect {
        let handle = PictureGripView.handles[index]
        let pull = PictureHandles.turn(translation, by: -angle)
        var width = frame.width + CGFloat(handle.x) * pull.width
        var height = frame.height + CGFloat(handle.y) * pull.height
        let ratio = frame.height > 0 ? frame.width / frame.height : 1
        if handle.x != 0, handle.y != 0, !box {
            // Whichever way the pointer went further decides the size.
            if abs(width / frame.width - 1) >= abs(height / frame.height - 1) { height = width / ratio } else { width = height * ratio }
            let least = PictureHandles.smallest
            if width < least || height < least {
                let grow = max(least / max(width, 0.01), least / max(height, 0.01))
                if width > 0, height > 0 { width *= grow; height *= grow } else { width = least * max(ratio, 1); height = least * max(1 / ratio, 1) }
            }
        } else {
            if handle.x == 0 { width = frame.width } else { width = max(width, PictureHandles.smallest) }
            if handle.y == 0 { height = frame.height } else { height = max(height, PictureHandles.smallest) }
        }
        // The middle moves by half of what was added, towards the handle, along the picture's own sides.
        let shift = PictureHandles.turn(CGSize(width: CGFloat(handle.x) * (width - frame.width) / 2, height: CGFloat(handle.y) * (height - frame.height) / 2), by: angle)
        return CGRect(x: frame.midX + shift.width - width / 2, y: frame.midY + shift.height - height / 2, width: width, height: height)
    }

    /// The angle after the turning handle was pulled: the handle follows the pointer round the
    /// picture's middle. Near a quarter turn it settles on it; with Shift it goes in steps of 15.
    private func turnedAngle(_ translation: CGSize, steps: Bool) -> Double {
        let arm = PictureHandles.turn(CGSize(width: 0, height: -(frame.height / 2 + PictureGripView.turnReach)), by: angle)
        let pointer = CGSize(width: arm.width + translation.width, height: arm.height + translation.height)
        guard hypot(pointer.width, pointer.height) > 4 else { return angle }
        var degrees = atan2(pointer.height, pointer.width) * 180 / .pi + 90
        if steps {
            degrees = (degrees / 15).rounded() * 15
        } else {
            let quarter = (degrees / 90).rounded() * 90
            if abs(degrees - quarter) < 4 { degrees = quarter }
        }
        if degrees > 180 { degrees -= 360 }
        if degrees <= -180 { degrees += 360 }
        return degrees
    }

    private func change(_ part: PictureGripView.Part, _ translation: CGSize, _ steps: Bool) -> Live {
        switch part {
        case .body: return Live(frame: frame.offsetBy(dx: translation.width, dy: translation.height), angle: angle)
        case .handle(let index): return Live(frame: resizedFrame(index, translation), angle: angle)
        case .turn: return Live(frame: frame, angle: turnedAngle(translation, steps: steps))
        case .delete: return Live(frame: frame, angle: angle)
        }
    }

    var body: some View {
        let shown = live ?? Live(frame: frame, angle: angle)
        ZStack(alignment: .topLeading) {
            // Everything drawn here is for the eye only. The pointer is taken by the grip below,
            // an AppKit view: gestures laid over the text view do not get the pointer.
            if live != nil, let image {
                // What it will be, over what it is.
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: shown.frame.width, height: shown.frame.height)
                    .rotationEffect(.degrees(shown.angle))
                    .opacity(0.6)
                    .offset(x: shown.frame.minX, y: shown.frame.minY)
            }
            if picked {
                let width = shown.frame.width, height = shown.frame.height
                ZStack(alignment: .topLeading) {
                    // A white line under the blue one: it is seen on a picture of any colour.
                    Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 3.5).frame(width: width, height: height)
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5).frame(width: width, height: height)
                    if !plain {
                    if !box {
                    // The stem and the handle to turn it by, above the top edge.
                    Rectangle().fill(Color.accentColor).frame(width: 1.5, height: PictureGripView.turnReach - 7)
                        .offset(x: width / 2 - 0.75, y: -(PictureGripView.turnReach - 7))
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(-shown.angle))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18, height: 18)
                        .background(Color.white, in: Circle())
                        .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 1.5) }
                        .offset(x: width / 2 - 9, y: -PictureGripView.turnReach - 9)
                    }
                    ForEach(PictureGripView.handles.indices, id: \.self) { index in
                        let handle = PictureGripView.handles[index]
                        Circle()
                            .fill(Color.white)
                            .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 1.5) }
                            .frame(width: 12, height: 12)
                            .offset(x: (handle.x < 0 ? 0 : (handle.x > 0 ? width : width / 2)) - 6, y: (handle.y < 0 ? 0 : (handle.y > 0 ? height : height / 2)) - 6)
                    }
                    }
                    // The signs stay upright however the picture is turned.
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(-shown.angle))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.red, in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
                        .offset(x: width - 30, y: 8)
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .rotationEffect(.degrees(shown.angle))
                .offset(x: shown.frame.minX, y: shown.frame.minY)
            }
        }
        .allowsHitTesting(false)
        .overlay(alignment: .topLeading) {
            // The grip covers the picture as it stands, and when picked the handles around it.
            let room = NoteObject.turned(frame.size, by: angle)
            let pad = picked ? PictureGripView.turnReach + 22 : 0
            PictureGrip(picked: picked, size: frame.size, angle: angle, plain: plain, clickOpens: clickOpens, box: box,
                        press: { pick() },
                        change: { part, translation, steps in
                            let next = change(part, translation, steps)
                            if live != next { live = next }
                        },
                        end: { part, translation, moved, steps in
                            let final = change(part, translation, steps)
                            live = nil
                            switch part {
                            case .body: if moved { self.moved(final.frame) }
                            case .handle: if moved { resized(final.frame) }
                            case .turn: if moved { turned(final.angle) }
                            case .delete: delete()
                            }
                        },
                        menu: menu, open: open)
                .frame(width: room.width + pad * 2, height: room.height + pad * 2)
                .offset(x: frame.midX - room.width / 2 - pad, y: frame.midY - room.height / 2 - pad)
        }
    }
}

/// Takes the pointer over one picture: a press picks it, a drag moves it or, from a handle,
/// resizes or turns it. An AppKit view, because gestures laid over the text view do not get the
/// pointer. Its middle is the picture's middle.
private struct PictureGrip: NSViewRepresentable {
    let picked: Bool
    let size: CGSize
    let angle: Double
    var plain = false
    var clickOpens = false
    var box = false
    let press: () -> Void
    let change: (PictureGripView.Part, CGSize, Bool) -> Void
    let end: (PictureGripView.Part, CGSize, Bool, Bool) -> Void
    /// The menu of a right click on the picture, made when it is asked for.
    var menu: ((NSView) -> NSMenu?)?
    /// A double click on the picture.
    var open: (() -> Void)?

    func makeNSView(context: Context) -> PictureGripView { PictureGripView() }

    func updateNSView(_ view: PictureGripView, context: Context) {
        view.picked = picked
        view.size = size
        view.angle = angle
        view.plain = plain
        view.clickOpens = clickOpens
        view.box = box
        if box {
            view.setAccessibilityRole(.group)
            view.setAccessibilityLabel("Text box")
            view.setAccessibilityHelp("Press to pick it, then drag to move it or a handle to give it a size. A double click opens it to write in. Delete removes it.")
        }
        if clickOpens {
            view.setAccessibilityRole(.button)
            view.setAccessibilityLabel("Sticky note")
            view.setAccessibilityHelp("Click to open it and read or write on it; drag to move it.")
        }
        view.press = press
        view.change = change
        view.end = end
        view.makeMenu = menu
        view.open = open
    }
}

final class PictureGripView: NSView {
    enum Part: Equatable { case body, handle(Int), turn, delete }

    var picked = false
    /// The picture's own size, and the angle it is turned by about the view's middle.
    var size = CGSize.zero
    var angle = 0.0
    /// Without handles to resize and turn by.
    var plain = false
    /// A click that does not move it opens it.
    var clickOpens = false
    /// A text box: without the handle to turn it by.
    var box = false
    var press: (() -> Void)?
    var change: ((Part, CGSize, Bool) -> Void)?
    var end: ((Part, CGSize, Bool, Bool) -> Void)?
    var makeMenu: ((NSView) -> NSMenu?)?
    var open: (() -> Void)?

    private var held: Part?
    private var tracking: NSTrackingArea?
    private var start = CGPoint.zero
    private var travelled = false

    /// The handles' places around the picture: the corners and the middles of the sides, row by row.
    static let handles: [(x: Int, y: Int)] = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
    /// How far above the picture's top edge the handle to turn it by stands.
    static let turnReach: CGFloat = 30

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// What VoiceOver can do with it besides pressing it: delete it, and open it (to write in it or crop it).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = [NSAccessibilityCustomAction(name: "Delete") { [weak self] in
            self?.press?()
            self?.end?(.delete, .zero, true, false)
            return true
        }]
        if let open { actions.append(NSAccessibilityCustomAction(name: clickOpens || box ? "Open" : "Edit") { open(); return true }) }
        return actions
    }

    /// Pressed with VoiceOver: picked, as a click picks it; one that a click opens is opened.
    override func accessibilityPerformPress() -> Bool {
        if clickOpens, let open { open() } else { press?() }
        return true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Picture")
        setAccessibilityHelp("Press to pick it, then drag to move it, drag a handle to resize it or the handle above it to turn it. Delete removes it.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A point of the view along the picture's own sides, from its top left corner.
    func own(_ point: CGPoint) -> CGPoint {
        let radians = -angle * .pi / 180
        let dx = point.x - bounds.midX, dy = point.y - bounds.midY
        return CGPoint(x: dx * cos(radians) - dy * sin(radians) + size.width / 2, y: dx * sin(radians) + dy * cos(radians) + size.height / 2)
    }

    /// The point of the view where a place given along the picture's own sides lies.
    func place(_ own: CGPoint) -> CGPoint {
        let radians = angle * .pi / 180
        let dx = own.x - size.width / 2, dy = own.y - size.height / 2
        return CGPoint(x: bounds.midX + dx * cos(radians) - dy * sin(radians), y: bounds.midY + dx * sin(radians) + dy * cos(radians))
    }

    /// What of the picture lies at a point of the view: its delete button, the handle to turn
    /// it by, a handle to resize it by, or the picture itself.
    func part(at point: CGPoint) -> Part? {
        let at = own(point)
        if picked {
            if hypot(at.x - (size.width - 19), at.y - 19) <= 13 { return .delete }
            if !plain, !box, hypot(at.x - size.width / 2, at.y + PictureGripView.turnReach) <= 13 { return .turn }
            for (index, handle) in PictureGripView.handles.enumerated() where !plain {
                let x = handle.x < 0 ? 0 : (handle.x > 0 ? size.width : size.width / 2), y = handle.y < 0 ? 0 : (handle.y > 0 ? size.height : size.height / 2)
                if hypot(at.x - x, at.y - y) <= 11 { return .handle(index) }
            }
        }
        return CGRect(origin: .zero, size: size).contains(at) ? .body : nil
    }

    // Only the picture and its handles take the pointer: around them it goes to what lies beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return part(at: convert(point, from: superview)) == nil ? nil : self
    }

    // The pointer's shape says what a press would do. It is set as the pointer moves, not with
    // cursor rectangles: those are laid out again whenever the picture changes, which made the
    // pointer flicker while a picture was dragged.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// The turning handle's pointer: two arrows round a circle.
    private static let turnCursor: NSCursor = {
        let side: CGFloat = 22
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return .crosshair }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let at = NSRect(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
            // White under black, so that it shows on any picture.
            for (color, grow) in [(NSColor.white, 1.6), (NSColor.black, 0.0)] {
                let tinted = NSImage(size: symbol.size, flipped: false) { inner in
                    symbol.draw(in: inner)
                    color.set()
                    inner.fill(using: .sourceAtop)
                    return true
                }
                if grow > 0 {
                    for (dx, dy) in [(-grow, 0.0), (grow, 0.0), (0.0, -grow), (0.0, grow), (-grow, -grow), (grow, grow), (-grow, grow), (grow, -grow)] { tinted.draw(in: at.offsetBy(dx: dx, dy: dy)) }
                } else {
                    tinted.draw(in: at)
                }
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()

    /// The pointer for a part of the picture; `pressed` while the button is down on it.
    func cursor(for part: Part, pressed: Bool) -> NSCursor {
        switch part {
        case .body: return pressed ? .closedHand : (clickOpens ? .pointingHand : .openHand)
        case .delete: return .pointingHand
        case .turn: return PictureGripView.turnCursor
        case .handle(let index):
            // The way the handle pulls, on screen: the picture may be turned.
            let handle = PictureGripView.handles[index]
            let radians = angle * .pi / 180
            let x = Double(handle.x) * cos(radians) - Double(handle.y) * sin(radians), y = Double(handle.x) * sin(radians) + Double(handle.y) * cos(radians)
            let octant = Int((atan2(y, x) / (.pi / 4)).rounded())
            // From pointing right, clockwise on screen (y down), in eighths of a turn.
            let positions: [NSCursor.FrameResizePosition] = [.right, .bottomRight, .bottom, .bottomLeft, .left, .topLeft, .top, .topRight]
            return NSCursor.frameResize(position: positions[((octant % 8) + 8) % 8], directions: .all)
        }
    }

    private func showCursor(_ event: NSEvent) {
        if let held { cursor(for: held, pressed: true).set(); return }
        guard let part = part(at: convert(event.locationInWindow, from: nil)) else { return }
        // Not through a picture or a panel that lies over this one.
        guard window?.contentView?.superview?.hitTest(event.locationInWindow) === self || window?.contentView?.hitTest(event.locationInWindow) === self else { return }
        cursor(for: part, pressed: false).set()
    }

    override func mouseMoved(with event: NSEvent) { showCursor(event) }
    override func mouseEntered(with event: NSEvent) { showCursor(event) }
    override func cursorUpdate(with event: NSEvent) { showCursor(event) }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard part(at: convert(event.locationInWindow, from: nil)) != nil else { return nil }
        press?()
        return makeMenu?(self)
    }

    private func translation(_ event: NSEvent) -> CGSize {
        // The window's y points up, the pages' down.
        CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard let part = part(at: convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount == 2, part == .body, let open {
            held = nil
            open()
            return
        }
        held = part
        start = event.locationInWindow
        travelled = false
        if part != .delete { press?() }
        cursor(for: part, pressed: true).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let held, held != .delete else { return }
        // Whatever redraws under the pointer meanwhile, it keeps the shape of what it holds.
        cursor(for: held, pressed: true).set()
        let moved = translation(event)
        if !travelled, hypot(moved.width, moved.height) < 3 { return }
        travelled = true
        change?(held, moved, event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        guard let part = held else { return }
        held = nil
        showCursor(event)
        if part == .delete {
            // Let go on the button it was pressed on.
            if self.part(at: convert(event.locationInWindow, from: nil)) == .delete { end?(.delete, .zero, false, false) }
            return
        }
        end?(part, translation(event), travelled, event.modifierFlags.contains(.shift))
        if clickOpens, part == .body, !travelled { open?() }
    }
}


/// What the scripted checks ask of the tools, passed on to the note's own state.
private struct RemoteTools: ViewModifier {
    @Binding var tool: InkTool
    @Binding var pen: PenChoice
    @Binding var eraser: EraserChoice
    @Binding var picking: SelectChoice
    @Binding var styling: Bool
    @Binding var panel: Bool
    @Binding var pad: Bool
    @Binding var pointing: Bool
    @Binding var drawing: Bool
    let canEdit: Bool
    let box: (EditorRemote.BoxAction) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: EditorRemote.shared.pointing) { if let asked = EditorRemote.shared.pointing { pointing = asked; if asked { tool = .select; drawing = true } } }
            .onChange(of: EditorRemote.shared.boxStep) { if let asked = EditorRemote.shared.boxAction { box(asked) } }
            .onChange(of: EditorRemote.shared.tool) { if let asked = EditorRemote.shared.tool { tool = asked; drawing = true } }
            .onChange(of: EditorRemote.shared.pen) { if let asked = EditorRemote.shared.pen { pen = asked } }
            .onChange(of: EditorRemote.shared.eraser) { if let asked = EditorRemote.shared.eraser { eraser = asked } }
            .onChange(of: EditorRemote.shared.picking) { if let asked = EditorRemote.shared.picking { picking = asked } }
            .onChange(of: EditorRemote.shared.styling) { if let asked = EditorRemote.shared.styling { styling = asked } }
            .onChange(of: EditorRemote.shared.panel) { if let asked = EditorRemote.shared.panel { panel = asked } }
            .onChange(of: EditorRemote.shared.pad) { if let asked = EditorRemote.shared.pad { pad = asked; if asked { tool = .pen; drawing = true } } }
            .onChange(of: EditorRemote.shared.drawing) { if let asked = EditorRemote.shared.drawing { drawing = asked && canEdit } }
    }
}

/// Where the window's top edge is among the note's pages, in their points. A plain object: it
/// changes with every step of scrolling, and nothing is drawn anew for it.
final class Viewport {
    var top = 0.0
}
