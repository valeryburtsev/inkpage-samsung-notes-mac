import AppKit
import SamsungNotesKit
import SwiftUI

/// A label that appears beside a control once the pointer has rested on it, saying what it is.
/// (The system's own tooltip is set as well; this one is drawn in the window, so it is there
/// at once and is not lost behind the glass.)
private struct HoverLabel: ViewModifier {
    let text: String
    let above: Bool
    @State private var visible = false
    @State private var waiting: Task<Void, Never>?

    private var label: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    @Environment(\.toolsOnLeft) private var onLeft

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                waiting?.cancel()
                if inside {
                    waiting = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { visible = true } }
                    }
                } else {
                    visible = false
                }
            }
            // To the left of the control, or above it: hung on a point of zero size at the control's
            // left or top edge, so that no alignment is guessed at.
            // With the tools on the left the labels stand to their right, where the window has room.
            .overlay(alignment: above ? .top : onLeft ? .trailing : .leading) {
                if visible || EditorRemote.shared.showLabels {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .overlay(alignment: above ? .bottom : onLeft ? .leading : .trailing) {
                            label
                                .fixedSize()
                                .offset(x: above ? 0 : onLeft ? 10 : -10, y: above ? -8 : 0)
                        }
                }
            }
            .help(text)
    }
}

private struct ToolsOnLeftKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The strip of tools stands at the left edge of the note, not the right.
    var toolsOnLeft: Bool {
        get { self[ToolsOnLeftKey.self] }
        set { self[ToolsOnLeftKey.self] = newValue }
    }
}

extension View {
    /// Names a control: a tooltip, a label drawn beside it (to its left, or above it) and the
    /// accessibility label.
    func named(_ text: String, above: Bool = false) -> some View {
        modifier(HoverLabel(text: text, above: above)).accessibilityLabel(text)
    }
}

/// What can be put into a note from the Insert menu, as in the original.
enum InsertKind: String, CaseIterable, Identifiable {
    case pdf, voice, image, audio, drawing, sticky, table

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pdf: return "PDF…"
        case .voice: return "Voice Recording"
        case .image: return "Image…"
        case .audio: return "Audio File…"
        case .drawing: return "Drawing…"
        case .sticky: return "Sticky Note"
        case .table: return "Table"
        }
    }
    var symbol: String {
        switch self {
        case .pdf: return "doc.badge.plus"
        case .voice: return "mic"
        case .image: return "photo"
        case .audio: return "music.note"
        case .drawing: return "paintpalette"
        case .sticky: return "note.text"
        case .table: return "tablecells"
        }
    }
}

/// The strip of tools down the side of a note, in the order of the Windows client's: collapse,
/// keyboard, pen, highlighter, eraser, selection, undo, redo, change style; then the two this
/// client adds, shapes and the things to insert. Beside it, the options of the tool in hand.
struct ToolStrip: View {
    @Binding var drawing: Bool
    @Binding var tool: InkTool
    @Binding var pen: PenChoice
    @Binding var eraser: EraserChoice
    @Binding var picking: SelectChoice
    /// The selection tool is in hand to change the style of what it picks.
    @Binding var styling: Bool
    /// The panel of options beside the strip is open.
    @Binding var panel: Bool
    /// The strip stands at the left edge; and how high the panel may be.
    @Binding var onLeft: Bool
    var room: Double = 620
    /// The note has pages of a PDF: the keyboard's tip says how the PDF's text is picked.
    var hasPDF = false
    let text: TextController
    let hasSelection: Bool
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
    let insert: (InsertKind) -> Void
    let restyle: (UInt32?, Double?) -> Void
    let eraseAll: () -> Void
    /// Whether the note's tapes are all open; nil when it has none. And the way to open or close them all.
    var tapesOpen: Bool?
    var setTapes: (Bool) -> Void = { _ in }

    private enum Hand { case keyboard, pen, highlighter, eraser, select, tape, style, pad, shape, pointer }

    /// The Easy writing pad is open at the foot of the note.
    @Binding var pad: Bool
    /// The pointer is in hand: a click picks the block of handwriting under it.
    @Binding var pointing: Bool
    /// Sets a new text box down on the page: the button at the foot of the keyboard's options.
    var addBox: () -> Void = {}

    private var hand: Hand {
        guard drawing else { return .keyboard }
        if pad, tool == .pen { return .pad }
        switch tool {
        case .pen: return pen.taping ? .tape : pen.marking ? .highlighter : .pen
        case .eraser: return .eraser
        case .select: return styling ? .style : pointing ? .pointer : .select
        case .shape: return .shape
        }
    }

    /// Takes a tool up; pressed again while in hand, shows or hides its options.
    private func take(_ wanted: Hand) {
        if hand == wanted { withAnimation(.easeOut(duration: 0.15)) { panel.toggle() }; return }
        styling = wanted == .style
        pointing = wanted == .pointer
        pad = wanted == .pad
        switch wanted {
        case .pad: if pen.group == .tape { pen.group = .pens }; tool = .pen; drawing = true
        case .keyboard: drawing = false
        case .pen: pen.group = .pens; tool = .pen; drawing = true
        case .highlighter: pen.group = .markers; tool = .pen; drawing = true
        case .tape: pen.group = .tape; tool = .pen; drawing = true
        case .eraser: tool = .eraser; drawing = true
        case .select, .style, .pointer: tool = .select; drawing = true
        case .shape: tool = .shape; drawing = true
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if onLeft { strip }
            if panel {
                // As high as its options; in a low window they scroll.
                ViewThatFits(in: .vertical) {
                    options.padding(16)
                    ScrollView(.vertical) { options.padding(16) }
                }
                    .frame(width: 264)
                    .frame(maxHeight: max(room, 200))
                    .fixedSize(horizontal: false, vertical: true)
                    .floatingBar()
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .transition(.opacity.combined(with: .move(edge: onLeft ? .leading : .trailing)))
            }
            if !onLeft { strip }
        }
        .environment(\.toolsOnLeft, onLeft)
    }

    /// The grip at the head of the strip: dragged across the window, it takes the tools to the other side.
    private var grip: some View {
        Image(systemName: "circle.grid.2x2.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            .frame(width: 36, height: 18)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 30).onEnded { drag in
                if drag.translation.width < -120 { withAnimation { onLeft = true } } else if drag.translation.width > 120 { withAnimation { onLeft = false } }
            })
            // For VoiceOver and the keyboard: a button that does what the drag does.
            .accessibilityElement()
            .accessibilityLabel(onLeft ? "Move tools to the right" : "Move tools to the left")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation { onLeft.toggle() } }
            .contextMenu {
                Button(onLeft ? "Move Tools to the Right" : "Move Tools to the Left") { withAnimation { onLeft.toggle() } }
            }
            .named("Drag across to move the tools to the other side")
    }

    @ViewBuilder private var options: some View {
        switch hand {
        case .keyboard: TextPanel(text: text, addBox: addBox)
        case .pen, .highlighter, .pad: PenPanel(pen: $pen)
        case .tape: TapePanel(pen: $pen, tapesOpen: tapesOpen, setTapes: setTapes)
        case .eraser: EraserPanel(eraser: $eraser, eraseAll: eraseAll)
        case .select: SelectPanel(picking: $picking)
        case .pointer: PointerPanel()
        case .style: StylePanel(hasSelection: hasSelection, restyle: restyle)
        case .shape: ShapePanel(pen: $pen)
        }
    }

    private var strip: some View {
        VStack(spacing: 4) {
            grip
            button(panel != onLeft ? "chevron.right" : "chevron.left", panel ? "Collapse" : "Show the tool's options", active: false) { withAnimation(.easeOut(duration: 0.15)) { panel.toggle() } }
            button("cursorarrow", "Pointer: click handwriting to pick the block it belongs to, or a text box or a picture, and drag it", active: hand == .pointer) { take(.pointer) }
            button("keyboard", hasPDF ? "Type with the keyboard. Hold ⌥ and drag to select text in the PDF" : "Type with the keyboard", active: hand == .keyboard) { take(.keyboard) }
            button(PenChoice.symbol(pen.kind), "Pen: \(PenChoice.title(pen.kind))", active: hand == .pen) { take(.pen) }
                .overlay(alignment: .bottomTrailing) { dot(pen.setting(of: pen.kind).argb) }
            button("highlighter", PenChoice.title(pen.markerKind), active: hand == .highlighter) { take(.highlighter) }
                .overlay(alignment: .bottomTrailing) { dot(pen.setting(of: pen.markerKind).argb) }
            button("eraser", eraser.area ? "Area eraser: rubs out what it passes over" : "Stroke eraser: erases a whole stroke", active: hand == .eraser) { take(.eraser) }
            button(picking.rectangle ? "rectangle.dashed" : "lasso", "Select: draw around handwriting, then move, resize or delete it", active: hand == .select) { take(.select) }
            Divider().frame(width: 22).padding(.vertical, 3)
            button("arrow.uturn.backward", "Undo (⌘Z)", active: false, action: undo).disabled(!canUndo)
            button("arrow.uturn.forward", "Redo (⇧⌘Z)", active: false, action: redo).disabled(!canRedo)
            button("bandage", "Tape: covers what is written until it is tapped", active: hand == .tape) { take(.tape) }
            button("textformat.alt", "Change style: another size or colour for handwriting", active: hand == .style) { take(.style) }
            button(PadGlyph(), "Easy writing pad: write large below, and it is laid in neat lines on the page", active: hand == .pad) { take(.pad) }
            Divider().frame(width: 22).padding(.vertical, 3)
            button(pen.shapeKind.symbol, "Shape: \(pen.shapeKind.title)", active: hand == .shape) { take(.shape) }
            Menu {
                ForEach([InsertKind.pdf, .voice]) { kind in Button(kind.title, systemImage: kind.symbol) { insert(kind) } }
                Divider()
                ForEach([InsertKind.image, .audio, .drawing, .sticky, .table]) { kind in Button(kind.title, systemImage: kind.symbol) { insert(kind) } }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 34)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverHighlight(radius: 12)
            .named("Insert a picture, a PDF, a drawing, a recording, a sticky note or a table")
        }
        .padding(6)
        .floatingBar()
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    /// The colour a pen is set to, at the corner of its button.
    private func dot(_ argb: UInt32) -> some View {
        Circle().fill(PenChoice.color(argb)).frame(width: 8, height: 8).overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 0.5) }.padding(5).allowsHitTesting(false)
    }

    private func button(_ symbol: String, _ help: String, active: Bool, action: @escaping () -> Void) -> some View {
        button(Image(systemName: symbol).font(.system(size: 16, weight: .medium)), help, active: active, action: action)
    }

    private func button(_ label: some View, _ help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .frame(width: 36, height: 34)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(radius: 12)
        .named(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A row of colours to pick one from.
struct Swatches: View {
    let colors: [UInt32]
    let chosen: UInt32?
    var clear: (() -> Void)?
    let pick: (UInt32) -> Void

    static func name(_ argb: UInt32) -> String {
        switch argb & 0x00FF_FFFF {
        case 0x252525: return "Black"
        case 0xFF3636: return "Red"
        case 0xFF9500: return "Orange"
        case 0xFFCB30: return "Yellow"
        case 0x22B573, 0x37D366: return "Green"
        case 0x1447FF: return "Blue"
        case 0x5AC8FA: return "Light blue"
        case 0x8E44D6, 0xB78CFF: return "Purple"
        case 0xFF6FA5: return "Pink"
        case 0x8A8A8E: return "Grey"
        default: return "Colour"
        }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6), spacing: 8) {
            if let clear {
                Button(action: clear) {
                    Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 24, height: 24)
                        .overlay { Image(systemName: "line.diagonal").font(.caption).foregroundStyle(.secondary) }
                }
                .buttonStyle(.plain).help("None").accessibilityLabel("None")
            }
            ForEach(colors, id: \.self) { value in
                Button { pick(value) } label: {
                    Circle().fill(PenChoice.color(value)).frame(width: 24, height: 24)
                        .overlay { if chosen == value { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white).shadow(radius: 1) } }
                        .overlay { Circle().strokeBorder(.primary.opacity(0.12)) }
                }
                .buttonStyle(.plain)
                .help(Swatches.name(value))
                .accessibilityLabel(Swatches.name(value))
                .accessibilityAddTraits(chosen == value ? .isSelected : [])
            }
        }
    }
}

/// The bar for formatting text, as in the original: character styles, colours, size, lists,
/// alignment and indent.
struct FormatBar: View {
    let text: TextController
    @State private var showColor = false
    @State private var showHighlight = false

    static let sizes: [Double] = [8, 10, 12, 14, 17, 20, 24, 30, 40, 54]
    static let highlights: [UInt32] = [0xFFFF_F27A, 0xFFB9_F5C4, 0xFFBF_E3FF, 0xFFFF_C9DD, 0xFFFF_D9A8, 0xFFE0_D0FF]

    var body: some View {
        let state = text.state
        HStack(spacing: 2) {
            toggle("bold", "Bold (⌘B)", state.bold) { text.toggle(NoteText.bold) }
            toggle("italic", "Italic (⌘I)", state.italic) { text.toggle(NoteText.italic) }
            toggle("underline", "Underline (⌘U)", state.underline) { text.toggle(NoteText.underline) }
            toggle("strikethrough", "Strikethrough", state.strikethrough) { text.toggle(NoteText.strikethrough) }
            separator
            Button { showColor.toggle() } label: {
                Image(systemName: "character").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 20)
                    .overlay(alignment: .bottom) { Capsule().fill(PenChoice.color(state.color)).frame(width: 16, height: 3).offset(y: 4) }
                    .frame(width: 32, height: 30).contentShape(.rect)
            }
            .buttonStyle(.plain).hoverHighlight().named("Text colour", above: true)
            .popover(isPresented: $showColor, arrowEdge: .top) {
                Swatches(colors: PenChoice.colors, chosen: state.color) { text.setColor($0); showColor = false; text.focus() }.padding(14)
            }
            Button { showHighlight.toggle() } label: {
                Image(systemName: "highlighter").font(.system(size: 14, weight: .medium)).frame(width: 30, height: 20)
                    .overlay(alignment: .bottom) { Capsule().fill(state.highlight >> 24 == 0 ? Color.secondary.opacity(0.3) : PenChoice.color(state.highlight)).frame(width: 16, height: 3).offset(y: 4) }
                    .frame(width: 32, height: 30).contentShape(.rect)
            }
            .buttonStyle(.plain).hoverHighlight().named("Highlight colour", above: true)
            .popover(isPresented: $showHighlight, arrowEdge: .top) {
                Swatches(colors: FormatBar.highlights, chosen: state.highlight >> 24 == 0 ? nil : state.highlight, clear: { text.setHighlight(0); showHighlight = false; text.focus() }) { text.setHighlight($0); showHighlight = false; text.focus() }.padding(14)
            }
            Menu {
                ForEach(FormatBar.sizes, id: \.self) { size in
                    Button { text.setSize(size); text.focus() } label: { if state.size == size { Label("\(Int(size))", systemImage: "checkmark") } else { Text("\(Int(size))") } }
                }
            } label: {
                Text(state.size == state.size.rounded() ? "\(Int(state.size))" : String(format: "%.1f", state.size)).font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary).frame(width: 32, height: 30).contentShape(.rect)
            }
            // A plain button of the bar's own size, like its neighbours: the borderless kind shrinks to its text.
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().hoverHighlight().named("Text size: \(Int(state.size))", above: true)
            separator
            toggle("checklist", "Checklist (⇧⌘L)", { if case .checkbox = state.mark { return true }; return false }()) { text.setMark(.checkbox(checked: false)) }
            toggle("list.bullet", "Bulleted list", state.mark == .dot) { text.setMark(.dot) }
            toggle("list.number", "Numbered list", state.mark == .number) { text.setMark(.number) }
            separator
            Menu {
                Button("Left", systemImage: "text.alignleft") { text.setAlignment(0); text.focus() }
                Button("Centre", systemImage: "text.aligncenter") { text.setAlignment(2); text.focus() }
                Button("Right", systemImage: "text.alignright") { text.setAlignment(1); text.focus() }
                Button("Justified", systemImage: "text.justify") { text.setAlignment(3); text.focus() }
            } label: {
                Image(systemName: ["text.alignleft", "text.alignright", "text.aligncenter", "text.justify"][min(max(state.alignment, 0), 3)]).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary).frame(width: 32, height: 30).contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().hoverHighlight().named("Alignment: left, centre, right or justified", above: true)
            toggle("decrease.indent", "Decrease indent (⇧Tab)", false) { text.indent(by: -1) }.disabled(state.indent == 0)
            toggle("increase.indent", "Increase indent (Tab)", false) { text.indent(by: 1) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .floatingBar()
        .glassEffect(.regular, in: .capsule)
    }

    private var separator: some View { Divider().frame(height: 18).padding(.horizontal, 5) }

    private func toggle(_ symbol: String, _ help: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); text.focus() } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 30)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 9))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .named(help, above: true)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The Easy writing pad's sign, as the Windows client draws it: a letter between two lines, with
/// an arrow up and down beside it (writing that is made larger and smaller). No system symbol says this.
struct PadGlyph: View {
    var body: some View {
        VStack(spacing: 2.5) {
            Capsule().frame(width: 19, height: 1.6)
            HStack(spacing: 1) {
                Text("a").font(.system(size: 14, weight: .semibold, design: .rounded)).baselineOffset(1)
                Image(systemName: "arrow.up.and.down").font(.system(size: 9.5, weight: .bold))
            }
            .frame(height: 13)
            Capsule().frame(width: 19, height: 1.6)
        }
        .accessibilityHidden(true)
    }
}
