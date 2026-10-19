import AppKit
import SamsungNotesKit
import SwiftUI

/// A view that chooses the pointer's shape itself: what lies beneath it leaves the pointer alone.
@MainActor protocol PointerOwner: NSView {}

/// A table of Samsung's own kind that is open to be written in, with what is picked in it.
/// One object that the editor, its panels and its bar all change in place: a copy handed
/// around would be written back stale by whichever of them spoke last.
@MainActor @Observable
final class TableLive {
    enum Pick: Equatable { case row(Int), column(Int) }
    enum Panel: Equatable { case menu, cellStyle, tableStyle }

    let id: String
    var table: SamsungTable
    /// As it was when it was opened: nothing is stored when nothing changed.
    let original: SamsungTable

    init(id: String, table: SamsungTable) {
        self.id = id
        self.table = table
        original = table
    }
    /// The cell the caret is in, or was in last.
    var row = 0
    var column = 0
    var pick: Pick?
    var panel: Panel?
    /// The table before a style panel was opened, for its Cancel.
    var beforePanel: SamsungTable?

    /// The cells a style is given to: the picked row or column, else the cell the caret is in.
    func isTarget(_ row: Int, _ column: Int) -> Bool {
        switch pick {
        case .row(let picked): return row == picked
        case .column(let picked): return column == picked
        case nil: return row == self.row && column == self.column
        }
    }

    /// The first of those cells: what the style panel shows as set.
    var model: SamsungTable.Cell? {
        switch pick {
        case .row(let picked): return table.rows[safe: picked]?.first
        case .column(let picked): return table.rows.first?[safe: picked]
        case nil: return table.rows[safe: row]?[safe: column]
        }
    }
}

/// Takes the pointer for a small handle that lies over the note: a click, or a drag reported
/// by how far the pointer has gone. An AppKit view, because gestures laid over the text view
/// do not get the pointer.
struct PointerGrip: NSViewRepresentable {
    var cursor: NSCursor = .pointingHand
    var label: String
    var click: (() -> Void)?
    var drag: ((CGSize) -> Void)?
    var end: (() -> Void)?

    final class Grip: NSView, PointerOwner {
        var cursor = NSCursor.pointingHand
        var click: (() -> Void)?
        var drag: ((CGSize) -> Void)?
        var end: (() -> Void)?
        private var start: CGPoint?
        private var travelled = false
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        private func show(_ event: NSEvent) {
            if start != nil { cursor.set(); return }
            // Not through something that lies over this.
            guard PointerOver.view(event, in: window) === self else { return }
            cursor.set()
        }

        override func mouseMoved(with event: NSEvent) { show(event) }
        override func mouseEntered(with event: NSEvent) { show(event) }
        override func cursorUpdate(with event: NSEvent) { show(event) }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            travelled = false
            cursor.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, drag != nil else { return }
            cursor.set()
            // The window's y points up, the note's down.
            let moved = CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y)
            if !travelled, hypot(moved.width, moved.height) < 2 { return }
            travelled = true
            drag?(moved)
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            if travelled { end?() } else { click?() }
        }
    }

    func makeNSView(context: Context) -> Grip {
        let view = Grip()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        return view
    }

    func updateNSView(_ view: Grip, context: Context) {
        view.cursor = cursor
        view.click = click
        view.drag = drag
        view.end = end
        view.setAccessibilityLabel(label)
    }
}

/// A table being written in where it stands in the note, as the Windows client shows one: the
/// cells are typed into; above each line between columns a grip widens and narrows the column;
/// a handle above the caret's column and one beside its row pick the column or row, and picked,
/// open a menu to add or delete, cut, copy and paste, and set the cells' or the table's style.
struct TableEditor: View {
    let live: TableLive
    /// Points on screen per page unit.
    let scale: CGFloat
    let paper: Color
    let dark: Bool
    /// The size the table is drawn at beneath this, which this covers.
    let covers: CGSize

    @FocusState private var focus: Int?
    /// The width a column had when its grip was taken.
    @State private var gripWidth: Float?

    /// The room kept above and to the left of the table for its handles.
    static let margin: CGFloat = 38

    private var table: SamsungTable { live.table }
    private var density: CGFloat { CGFloat(table.pageWidth > 0 ? table.pageWidth : 848) / 360 * scale }
    private func tag(_ row: Int, _ column: Int) -> Int { row * 64 + column }

    private func rects() -> [[CGRect]] {
        table.cellRects.map { $0.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) } }
    }

    var body: some View {
        let rects = rects()
        let size = CGSize(width: table.rect.width * scale, height: table.rect.height * scale)
        let margin = TableEditor.margin
        let ink = dark ? Color(white: 0.93) : nil
        ZStack(alignment: .topLeading) {
            // The paper under the table: it covers the table as it is drawn beneath, and takes
            // the presses that fall between the cells.
            Rectangle().fill(paper)
                .frame(width: max(size.width, covers.width) + 2, height: max(size.height, covers.height) + 2)
                .background { PointerShield() }
                .offset(x: margin - 1, y: margin - 1)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { row, cells in
                ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                    if let rect = rects[safe: row]?[safe: column] {
                        let own = table.paper(row: row, column: column)
                        if own >> 24 != 0 {
                            Rectangle().fill(PenChoice.color(own)).frame(width: rect.width, height: rect.height).offset(x: margin + rect.minX, y: margin + rect.minY)
                                .allowsHitTesting(false)
                        }
                        field(row, column, cell, rect, ink: ink)
                    }
                }
            }
            // Where the table has no lines of its own, faint ones show where the cells are while it is open.
            if table.lines != .rounded && table.lines != .grid {
                TableLines(rects: rects, size: size, corner: 0, kind: .grid)
                    .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                    .frame(width: size.width, height: size.height)
                    .offset(x: margin, y: margin)
                    .allowsHitTesting(false)
            }
            TableLines(rects: rects, size: size, corner: 3.65 * density, kind: table.lines)
                .stroke(PenChoice.color(dark ? 0xFF8A_8780 : table.lineColor), lineWidth: max(0.3 * density, 0.75))
                .frame(width: size.width, height: size.height)
                .offset(x: margin, y: margin)
                .allowsHitTesting(false)
            if let picked = pickedRect(rects, size) {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: picked.width + 4, height: picked.height + 4)
                    .offset(x: margin + picked.minX - 2, y: margin + picked.minY - 2)
                    .allowsHitTesting(false)
            }
            handles(rects, size)
        }
        .frame(width: max(size.width, covers.width) + margin + 24, height: max(size.height, covers.height) + margin + 24, alignment: .topLeading)
        .onAppear { focus = tag(live.row, live.column) }
        .onChange(of: focus) {
            guard let focus else { return }
            let row = focus / 64, column = focus % 64
            if row != live.row || column != live.column { live.row = row; live.column = column }
        }
    }

    private func field(_ row: Int, _ column: Int, _ cell: SamsungTable.Cell, _ rect: CGRect, ink: Color?) -> some View {
        let size = max(CGFloat(cell.fontSize) * density, 6)
        return TextField("", text: Binding(get: { live.table.rows[safe: row]?[safe: column]?.text ?? "" }, set: { new in
            guard live.table.rows.indices.contains(row), live.table.rows[row].indices.contains(column), live.table.rows[row][column].text != new else { return }
            live.table.rows[row][column].text = new
            live.table.settle()
        }), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: cell.bold ? .bold : .regular))
            .italic(cell.italic)
            .underline(cell.underline)
            .strikethrough(cell.strikethrough)
            .foregroundStyle(ink ?? PenChoice.color(cell.color))
            .multilineTextAlignment(cell.alignment == 2 ? .center : (cell.alignment == 1 ? .trailing : .leading))
            .focused($focus, equals: tag(row, column))
            // Return goes down a row, as in a spreadsheet.
            .onSubmit { focus = tag(min(row + 1, table.rows.count - 1), column) }
            .frame(width: max(rect.width - 16 * density, 8), height: max(rect.height - 8 * density, size * 1.2), alignment: cell.alignment == 2 ? .top : (cell.alignment == 1 ? .topTrailing : .topLeading))
            .offset(x: TableEditor.margin + rect.minX + 8 * density, y: TableEditor.margin + rect.minY + 4 * density)
            .accessibilityLabel("Row \(row + 1), column \(column + 1)")
    }

    private func pickedRect(_ rects: [[CGRect]], _ size: CGSize) -> CGRect? {
        switch live.pick {
        case .row(let row): return rects[safe: row]?.first.map { CGRect(x: 0, y: $0.minY, width: size.width, height: $0.height) }
        case .column(let column): return rects.first?[safe: column].map { CGRect(x: $0.minX, y: 0, width: $0.width, height: size.height) }
        case nil: return nil
        }
    }

    private func pill(picked: Bool, upright: Bool) -> some View {
        let long: CGFloat = picked ? 44 : 30, short: CGFloat = picked ? 18 : 8
        return Capsule()
            .fill(picked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(white: dark ? 0.5 : 0.72)))
            .frame(width: upright ? short : long, height: upright ? long : short)
            .overlay {
                if picked {
                    let dots = ForEach(0..<3, id: \.self) { _ in Circle().fill(.white).frame(width: 5, height: 5) }
                    if upright { VStack(spacing: 5) { dots } } else { HStack(spacing: 5) { dots } }
                }
            }
    }

    @ViewBuilder private func handles(_ rects: [[CGRect]], _ size: CGSize) -> some View {
        let margin = TableEditor.margin
        // The table's own sign, at its corner: its style.
        Button { open(.tableStyle, pick: nil) } label: {
            Image(systemName: "tablecells").font(.system(size: 15)).foregroundStyle(Color(white: dark ? 0.6 : 0.55)).frame(width: 24, height: 24).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(radius: 6)
        .help("Table style")
        .accessibilityLabel("Table style")
        .popover(isPresented: panelShown(when: live.pick == nil), arrowEdge: .bottom) { TablePanel(live: live) }
        .offset(x: margin - 30, y: margin - 30)

        // Above every line between two columns, and the table's right edge: a grip to move it by.
        if let top = rects.first {
            ForEach(Array(top.enumerated()), id: \.offset) { column, rect in
                RoundedRectangle(cornerRadius: 4).fill(Color(white: dark ? 0.45 : 0.78))
                    .frame(width: 30, height: 15)
                    .overlay { Image(systemName: "chevron.left.chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) }
                    .overlay {
                        PointerGrip(cursor: .resizeLeftRight, label: "Width of column \(column + 1)", drag: { moved in
                            if gripWidth == nil { gripWidth = live.table.columnWidths[safe: column] }
                            guard let from = gripWidth else { return }
                            live.table.setWidth(from + Float(moved.width / scale), ofColumn: column)
                        }, end: { gripWidth = nil })
                    }
                    .offset(x: margin + rect.maxX - 15, y: margin - 26)
            }
        }

        // Above the caret's column and beside its row: a handle that picks it, and picked, opens its menu.
        let column = { if case .column(let picked) = live.pick { return picked }; return live.column }()
        let row = { if case .row(let picked) = live.pick { return picked }; return live.row }()
        if let rect = rects.first?[safe: column] {
            let picked = live.pick == .column(column)
            pill(picked: picked, upright: false)
                .overlay { PointerGrip(label: picked ? "Column \(column + 1): menu" : "Pick column \(column + 1)", click: { picked ? open(.menu, pick: .column(column)) : pick(.column(column)) }) }
                .popover(isPresented: panelShown(when: picked), arrowEdge: .bottom) { TablePanel(live: live) }
                .offset(x: margin + rect.midX - (picked ? 22 : 15), y: margin - (picked ? 31 : 22))
        }
        if let rect = rects[safe: row]?.first {
            let picked = live.pick == .row(row)
            pill(picked: picked, upright: true)
                .overlay { PointerGrip(label: picked ? "Row \(row + 1): menu" : "Pick row \(row + 1)", click: { picked ? open(.menu, pick: .row(row)) : pick(.row(row)) }) }
                .popover(isPresented: panelShown(when: picked), arrowEdge: .trailing) { TablePanel(live: live) }
                .offset(x: margin - (picked ? 26 : 16), y: margin + rect.midY - (picked ? 22 : 15))
        }
    }

    /// Whether a panel is shown from one of the three places panels hang on.
    private func panelShown(when here: Bool) -> Binding<Bool> {
        Binding(get: { live.panel != nil && here && (live.pick != nil || live.panel == .tableStyle) }, set: { shown in if !shown, live.panel != nil { live.panel = nil } })
    }

    private func pick(_ pick: TableLive.Pick) {
        live.panel = nil
        live.pick = pick
    }

    private func open(_ panel: TableLive.Panel, pick: TableLive.Pick?) {
        live.pick = pick
        live.beforePanel = panel == .menu ? nil : live.table
        live.panel = panel
    }
}

/// The lines of a table: its rounded outer edge and the lines between its rows and columns.
private struct TableLines: Shape {
    let rects: [[CGRect]]
    let size: CGSize
    let corner: CGFloat
    var kind = SamsungTable.Lines.rounded

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func across(_ y: CGFloat) { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) }
        if kind == .rounded || kind == .grid || kind == .horizontal {
            for row in rects.dropFirst() { if let first = row.first { across(first.minY) } }
        }
        if kind == .rounded || kind == .grid {
            let radius = kind == .rounded ? min(corner, size.width / 2, size.height / 2) : 0
            path.addRoundedRect(in: CGRect(origin: .zero, size: size), cornerSize: CGSize(width: radius, height: radius))
            for cell in (rects.first ?? []).dropFirst() { path.move(to: CGPoint(x: cell.minX, y: 0)); path.addLine(to: CGPoint(x: cell.minX, y: size.height)) }
        }
        if kind == .horizontal || kind == .topAndBottom { across(0); across(size.height) }
        return path
    }
}

/// What hangs on a picked row or column, as the Windows client has it: a menu, and from it
/// the style of the cells or of the whole table.
struct TablePanel: View {
    let live: TableLive
    @State private var showInk = false

    /// The papers a cell is given, as the Windows client offers them.
    static let papers = SamsungTable.papers
    static let paperNames = ["Light yellow", "Light orange", "Light red", "Light purple", "Light blue", "Light green"]
    static let sizes: [Float] = [8, 10, 12, 14, 15, 17, 20, 24, 30, 40]

    var body: some View {
        Group {
            switch live.panel {
            case .menu, nil: menu
            case .cellStyle: style(table: false)
            case .tableStyle: style(table: true)
            }
        }
        .padding(18)
        .frame(width: live.panel == .menu ? 250 : 380)
    }

    private var isRow: Bool { if case .row = live.pick { return true }; return false }
    private var index: Int {
        switch live.pick {
        case .row(let row): return row
        case .column(let column): return column
        case nil: return 0
        }
    }

    // MARK: The menu

    private var menu: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                icon("scissors", "Cut") { copy(); change { $0.text = "" }; live.panel = nil }
                icon("doc.on.doc", "Copy") { copy(); live.panel = nil }
                icon("doc.on.clipboard", "Paste") { paste(); live.panel = nil }.disabled(NSPasteboard.general.string(forType: .string) == nil)
                Divider().frame(height: 22)
                icon("arrow.left.and.line.vertical.and.arrow.right", "Fit to the page's width, all columns alike") { live.table.fitToWidth(); live.panel = nil }.disabled(!live.table.canFit)
            }
            dashes
            item(isRow ? "Add row" : "Add column", "plus.rectangle") {
                if isRow { live.table.insertRow(at: index + 1) } else { live.table.insertColumn(at: index + 1) }
                live.panel = nil
            }
            .disabled(isRow ? live.table.rows.count >= SamsungTable.most : live.table.columns >= SamsungTable.most)
            item(isRow ? "Delete row" : "Delete column", "minus.rectangle") {
                if isRow { live.table.removeRow(at: index) } else { live.table.removeColumn(at: index) }
                live.pick = nil
                live.row = min(live.row, live.table.rows.count - 1)
                live.column = min(live.column, live.table.columns - 1)
                live.panel = nil
            }
            .disabled(isRow ? live.table.rows.count <= 1 : live.table.columns <= 1)
            dashes
            item("Cell style", "paintbrush") { live.beforePanel = live.table; live.panel = .cellStyle }
            item("Table style", "tablecells") { live.beforePanel = live.table; live.panel = .tableStyle }
        }
    }

    private var dashes: some View {
        Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4])).foregroundStyle(.quaternary).frame(height: 1).padding(.vertical, 8)
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16)).frame(width: 40, height: 34).contentShape(.rect) }
            .buttonStyle(.plain).hoverHighlight().help(help).accessibilityLabel(help)
    }

    private func item(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 24)
                Text(title).font(.system(size: 14))
                Spacer()
            }
            .padding(.vertical, 7).padding(.horizontal, 6).contentShape(.rect)
        }
        .buttonStyle(.plain).hoverHighlight()
    }

    /// The picked cells' texts, tab between columns and a line for each row.
    private func copy() {
        var lines: [String] = []
        for (row, cells) in live.table.rows.enumerated() {
            let picked = cells.enumerated().filter { live.isTarget(row, $0.offset) }.map(\.element.text)
            if !picked.isEmpty { lines.append(picked.joined(separator: "\t")) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// What is on the clipboard goes into the picked cells in their order, a cell for every tab and line.
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        var values = text.split(omittingEmptySubsequences: false) { $0 == "\t" || $0.isNewline }.map(String.init)
        if values.last == "" { values.removeLast() }
        var next = 0
        change { cell in
            if next < values.count { cell.text = values[next] }
            next += 1
        }
    }

    private func change(all: Bool = false, _ change: (inout SamsungTable.Cell) -> Void) {
        // Which cells, said before the table is touched.
        let picked = live.table.rows.indices.map { row in live.table.rows[row].indices.map { all || live.isTarget(row, $0) } }
        live.table.change(where: { row, column in picked[safe: row]?[safe: column] ?? false }, change)
    }

    // MARK: Styles

    private func style(table whole: Bool) -> some View {
        let model = whole ? live.table.rows.first?.first : live.model
        return VStack(alignment: .leading, spacing: 14) {
            Text(whole ? "Table style" : "Cell style").font(.headline)
            if whole { TableLooks(live: live); dashes.padding(.vertical, -6) }
            HStack(spacing: 10) {
                swatch(0, chosen: (model?.background ?? 0) >> 24 == 0, name: "No fill") { paper(0, whole) }
                ForEach(Array(TablePanel.papers.enumerated()), id: \.offset) { index, value in
                    swatch(value, chosen: model?.background == value, name: TablePanel.paperNames[safe: index] ?? "Colour") { paper(value, whole) }
                }
                ColorPicker("", selection: Binding(get: { PenChoice.color((model?.background ?? 0) >> 24 == 0 ? 0xFFFF_FFFF : model?.background ?? 0xFFFF_FFFF) },
                                                   set: { new in paper(TablePanel.argb(new), whole) }), supportsOpacity: false)
                    .labelsHidden().help("Another colour").accessibilityLabel("Another cell colour")
            }
            dashes.padding(.vertical, -6)
            HStack(spacing: 10) {
                Menu {
                    ForEach(TablePanel.sizes, id: \.self) { size in
                        Button { change(all: whole) { $0.fontSize = size } } label: { if model?.fontSize == size { Label("\(Int(size))", systemImage: "checkmark") } else { Text("\(Int(size))") } }
                    }
                } label: {
                    Text("\(Int(model?.fontSize ?? 15))").font(.system(size: 14, weight: .medium).monospacedDigit()).frame(width: 30)
                }
                .menuStyle(.button).fixedSize().help("Text size").accessibilityLabel("Text size")
                HStack(spacing: 2) {
                    toggle("bold", "Bold", model?.bold == true) { let on = !(model?.bold ?? false); change(all: whole) { $0.bold = on } }
                    toggle("italic", "Italic", model?.italic == true) { let on = !(model?.italic ?? false); change(all: whole) { $0.italic = on } }
                    toggle("underline", "Underline", model?.underline == true) { let on = !(model?.underline ?? false); change(all: whole) { $0.underline = on } }
                    toggle("strikethrough", "Strikethrough", model?.strikethrough == true) { let on = !(model?.strikethrough ?? false); change(all: whole) { $0.strikethrough = on } }
                    Button { showInk.toggle() } label: {
                        Image(systemName: "character").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 20)
                            .overlay(alignment: .bottom) { Capsule().fill(PenChoice.color(model?.color ?? 0xFF25_2525)).frame(width: 16, height: 3).offset(y: 4) }
                            .frame(width: 34, height: 30).contentShape(.rect)
                    }
                    .buttonStyle(.plain).hoverHighlight().help("Text colour").accessibilityLabel("Text colour")
                    .popover(isPresented: $showInk, arrowEdge: .bottom) {
                        Swatches(colors: PenChoice.colors, chosen: model?.color) { value in change(all: whole) { $0.color = value }; showInk = false }.padding(14)
                    }
                }
                .padding(3)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
                Menu {
                    Button("Left", systemImage: "text.alignleft") { change(all: whole) { $0.alignment = 0 } }
                    Button("Centre", systemImage: "text.aligncenter") { change(all: whole) { $0.alignment = 2 } }
                    Button("Right", systemImage: "text.alignright") { change(all: whole) { $0.alignment = 1 } }
                } label: {
                    Image(systemName: ["text.alignleft", "text.alignright", "text.aligncenter", "text.justify"][min(max(model?.alignment ?? 0, 0), 3)]).frame(width: 22)
                }
                .menuStyle(.button).fixedSize().help("Alignment").accessibilityLabel("Alignment")
            }
            HStack {
                Button("Cancel") { if let before = live.beforePanel { live.table = before }; live.beforePanel = nil; live.panel = nil }
                    .keyboardShortcut(.cancelAction).frame(maxWidth: .infinity)
                Divider().frame(height: 20)
                Button("Done") { live.beforePanel = nil; live.panel = nil }.keyboardShortcut(.defaultAction).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .padding(.top, 4)
        }
    }

    /// A paper for the picked cells, or for the whole table, whose heading then takes the paper that goes with it.
    private func paper(_ value: UInt32, _ whole: Bool) {
        if whole { live.table.setPaper(value) } else { change { $0.background = value; $0.ownsBackground = true } }
    }

    private func swatch(_ value: UInt32, chosen: Bool, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(value == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(PenChoice.color(value))).frame(width: 30, height: 30)
                .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.75) }
                .overlay { if chosen { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black.opacity(0.65)) } }
        }
        .buttonStyle(.plain).help(name).accessibilityLabel(name).accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func toggle(_ symbol: String, _ name: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 34, height: 30)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain).hoverHighlight(radius: 8).help(name).accessibilityLabel(name).accessibilityAddTraits(on ? .isSelected : [])
    }

    static func argb(_ color: Color) -> UInt32 {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return 0xFFFF_FFFF }
        func part(_ value: CGFloat) -> UInt32 { UInt32(min(max(value * 255, 0), 255).rounded()) }
        return 0xFF00_0000 | part(rgb.redComponent) << 16 | part(rgb.greenComponent) << 8 | part(rgb.blueComponent)
    }
}

/// The looks of a whole table: its heading row and first column, and its lines.
struct TableLooks: View {
    let live: TableLive

    private static let kinds: [(SamsungTable.Lines, String, String)] = [
        (.rounded, "tablecells", "All lines, rounded corners"), (.grid, "squareshape.split.3x3", "All lines, square corners"),
        (.horizontal, "line.3.horizontal", "Lines between rows only"), (.topAndBottom, "equal", "A line above and one below"), (.none, "square.dashed", "No lines"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { live.table.headingRow }, set: { live.table.setHeading(row: $0) })) {
                Label("Highlight header row", systemImage: "rectangle.tophalf.inset.filled")
            }
            Toggle(isOn: Binding(get: { live.table.headingColumn }, set: { live.table.setHeading(column: $0) })) {
                Label("Highlight first column", systemImage: "rectangle.leadinghalf.inset.filled")
            }
            HStack(spacing: 4) {
                ForEach(TableLooks.kinds, id: \.0) { kind, symbol, name in
                    let on = live.table.lines == kind
                    Button { live.table.setLines(kind) } label: {
                        // The mark of the chosen one and the light under the pointer are the same circle.
                        Image(systemName: symbol).font(.system(size: 16)).frame(width: 34, height: 34)
                            .background(on ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear), in: .circle)
                            .hoverHighlight(radius: 17)
                            .frame(maxWidth: .infinity)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain).help(name).accessibilityLabel(name).accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
        }
        .toggleStyle(.switch)
    }
}

/// The bar shown while a table is open: its rows and columns at its end, and the way out.
struct TableBar: View {
    let live: TableLive
    let done: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tablecells").foregroundStyle(.secondary)
            counter("Rows", live.table.rows.count, less: live.table.rows.count > 1, more: live.table.rows.count < SamsungTable.most) { step in
                if step > 0 { live.table.insertRow(at: live.table.rows.count) } else { live.table.removeRow(at: live.table.rows.count - 1) }
                live.row = min(live.row, live.table.rows.count - 1)
                live.pick = nil
            }
            counter("Columns", live.table.columns, less: live.table.columns > 1, more: live.table.columns < SamsungTable.most) { step in
                if step > 0 { live.table.insertColumn(at: live.table.columns) } else { live.table.removeColumn(at: live.table.columns - 1) }
                live.column = min(live.column, live.table.columns - 1)
                live.pick = nil
            }
            Button("Done", action: done).buttonStyle(.glassProminent).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .floatingBar()
        .glassEffect(.regular, in: .capsule)
    }

    private func counter(_ name: String, _ count: Int, less: Bool, more: Bool, change: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text("\(name): \(count)").font(.callout.monospacedDigit()).fixedSize()
            Button { change(-1) } label: { Image(systemName: "minus").frame(width: 22, height: 22).contentShape(.rect) }
                .disabled(!less).hoverHighlight(radius: 7).help("Take the last of the \(name.lowercased()) away").accessibilityLabel("Fewer \(name.lowercased())")
            Button { change(1) } label: { Image(systemName: "plus").frame(width: 22, height: 22).contentShape(.rect) }
                .disabled(!more).hoverHighlight(radius: 7).help("Add to the \(name.lowercased())").accessibilityLabel("More \(name.lowercased())")
        }
        .buttonStyle(.plain)
    }
}
