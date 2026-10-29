import AppKit
import SamsungNotesKit
import SwiftUI

/// The options of the tool in hand, in a panel beside the strip of tools, as the Windows
/// client lays them out: what the keyboard writes, the pens and highlighters with their
/// sizes and colours, how the eraser rubs out, how the selection picks.

/// A slider as the Windows client draws its sizes: minus, a track of growing dots with the
/// number in the knob, plus.
struct LevelSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 1...100
    let label: String
    /// The knob's colour and what lies under it, for the slider of how see-through a pen is.
    var knob: Color = .white
    var tint: Color?

    private func set(_ new: Double) { value = min(max(new.rounded(), range.lowerBound), range.upperBound) }

    private func step(_ symbol: String, _ by: Double, _ name: String) -> some View {
        Button { set(value + by) } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 22, height: 26).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(name).accessibilityLabel(name)
    }

    var body: some View {
        HStack(spacing: 6) {
            step("minus", -1, "Less")
            GeometryReader { geometry in
                let side = 28.0, run = max(geometry.size.width - side, 1)
                let share = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)
                ZStack(alignment: .leading) {
                    track.frame(height: 20).clipShape(.capsule)
                    Circle().fill(knob).shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                        .overlay { Text("\(Int(value))").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(tint == nil ? Color.black : .black.opacity(0.75)) }
                        .frame(width: side, height: side)
                        .offset(x: share * run)
                }
                .frame(height: side)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    set(range.lowerBound + (drag.location.x - side / 2) / run * (range.upperBound - range.lowerBound))
                })
            }
            .frame(height: 28)
            step("plus", 1, "More")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { direction in set(value + (direction == .increment ? 1 : -1)) }
    }

    @ViewBuilder private var track: some View {
        if let tint {
            // From nothing to the colour, over the squares that show through it.
            ZStack {
                Canvas { context, size in
                    let cell = 5.0
                    for row in 0..<Int(size.height / cell + 1) {
                        for column in 0..<Int(size.width / cell + 1) where (row + column) % 2 == 0 {
                            context.fill(Path(CGRect(x: Double(column) * cell, y: Double(row) * cell, width: cell, height: cell)), with: .color(.black.opacity(0.55)))
                        }
                    }
                }
                .background(.white)
                LinearGradient(colors: [tint.opacity(0), tint], startPoint: .leading, endPoint: .trailing)
            }
        } else {
            ZStack {
                Capsule().fill(.quaternary.opacity(0.7))
                HStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { index in
                        Circle().fill(.secondary.opacity(0.55)).frame(width: 1.5 + Double(index) * 0.6, height: 1.5 + Double(index) * 0.6).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

/// The colours to choose from, as the Windows client shows them: four rows of eight, and
/// under them the colours last made, the dropper that takes one from the screen, and any colour.
struct Palette: View {
    /// Given for a palette of its own (the colours behind text); else the colour sets that are ticked.
    var colors: [UInt32]?
    let chosen: UInt32?
    /// The colours last picked that are not in the palette; nil leaves the row out.
    var recents: [UInt32]?
    /// For a colour that can be taken away (the colour behind text): the first place is "none".
    var clear: (() -> Void)?
    /// Any colour at all is offered at the end of the colours (the panels of text have it in their heading).
    var offersAny = true
    let pick: (UInt32) -> Void

    static let side = 22.0
    private var columns: [GridItem] { Array(repeating: GridItem(.fixed(Palette.side), spacing: 8), count: 8) }

    private func tick(on argb: UInt32) -> Color { NoteRenderer.luminance(argb) > 0.72 ? .black.opacity(0.7) : .white }

    private func dot(_ value: UInt32) -> some View {
        Button { pick(value) } label: {
            Circle().fill(PenChoice.color(value)).frame(width: Palette.side, height: Palette.side)
                .overlay { Circle().strokeBorder(.primary.opacity(0.1)) }
                .overlay { if chosen.map({ $0 | 0xFF00_0000 }) == value { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(tick(on: value)) } }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(Palette.name(value)).accessibilityLabel(Palette.name(value))
        .accessibilityAddTraits(chosen == value ? .isSelected : [])
    }

    static func name(_ argb: UInt32) -> String { String(format: "Colour #%06X", argb & 0x00FF_FFFF) }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            if let clear {
                Button(action: clear) {
                    Circle().fill(.white).frame(width: Palette.side, height: Palette.side)
                        .overlay { Circle().strokeBorder(.primary.opacity(0.18)) }
                        .overlay { if chosen == nil { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.7)) } }
                }
                .buttonStyle(.plain).help("None").accessibilityLabel("None")
            }
            ForEach(colors ?? ColorSets.shared.colors, id: \.self) { dot($0) }
            if let recents {
                ForEach(0..<5, id: \.self) { index in
                    if let value = recents[safe: index] {
                        dot(value)
                    } else {
                        // A place a colour of one's own will take.
                        Circle().fill(.quaternary.opacity(0.5)).frame(width: Palette.side, height: Palette.side)
                            .overlay { Image(systemName: "line.diagonal").font(.system(size: 11)).foregroundStyle(.tertiary) }
                            .accessibilityHidden(true)
                    }
                }
                Button { NSColorSampler().show { if let found = $0 { pick(PenChoice.argb(found)) } } } label: {
                    Circle().fill(.quaternary.opacity(0.5)).frame(width: Palette.side, height: Palette.side)
                        .overlay { Image(systemName: "eyedropper").font(.system(size: 11, weight: .medium)) }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain).help("Pick a colour from the screen").accessibilityLabel("Pick a colour from the screen")
                ColorSetsButton()
            }
            if offersAny { AnyColor(chosen: chosen, pick: pick) }
        }
    }
}

/// Any colour at all, from the system's colour panel: the round rainbow of the Windows client's palettes.
struct AnyColor: View {
    let chosen: UInt32?
    let pick: (UInt32) -> Void

    var body: some View {
        Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
            .overlay { Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: 9)) }
            .frame(width: Palette.side, height: Palette.side)
            .overlay {
                ColorPicker("Any colour", selection: Binding(get: { PenChoice.color(chosen ?? 0xFF25_2525) }, set: { pick(PenChoice.argb(NSColor($0))) }), supportsOpacity: false)
                    .labelsHidden().opacity(0.02)
            }
            .help("Any colour").accessibilityLabel("Any colour")
    }
}

/// A pen as the Windows client pictures it in its row of pens: the one in hand stands taller.
struct PenFigure: View {
    let kind: Pen.Kind
    let argb: UInt32
    let chosen: Bool

    var body: some View {
        Canvas { context, size in
            let ink = PenChoice.color(argb)
            let middle = size.width / 2
            let dark = Color(white: 0.2), pale = Color(white: 0.96), metal = Color(white: 0.78)
            func body(_ width: Double, from top: Double, _ color: Color, radius: Double = 3) {
                context.fill(Path(roundedRect: CGRect(x: middle - width / 2, y: top, width: width, height: size.height - top + 8), cornerRadius: radius), with: .color(color))
            }
            func cone(_ width: Double, tip: Double, base: Double, _ color: Color, blunt: Double = 0) {
                var path = Path()
                path.move(to: CGPoint(x: middle - blunt / 2, y: tip)); path.addLine(to: CGPoint(x: middle + blunt / 2, y: tip))
                path.addLine(to: CGPoint(x: middle + width / 2, y: base)); path.addLine(to: CGPoint(x: middle - width / 2, y: base)); path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            switch kind {
            case .fountain, .calligraphy:
                // A nib over a grip: pointed for the fountain pen, cut across for the calligraphy pen.
                cone(11, tip: 6, base: 30, metal, blunt: kind == .calligraphy ? 5 : 0)
                context.stroke(Path { $0.move(to: CGPoint(x: middle, y: 12)); $0.addLine(to: CGPoint(x: middle, y: 28)) }, with: .color(dark.opacity(0.7)), lineWidth: 0.8)
                body(13, from: 29, pale, radius: 2)
                body(14, from: 40, chosen ? ink : dark)
            case .ballpoint:
                cone(9, tip: 8, base: 24, ink, blunt: 1.5)
                body(12, from: 24, pale, radius: 2)
                context.fill(Path(CGRect(x: middle - 6, y: 40, width: 12, height: 9)), with: .color(ink))
            case .pencil:
                cone(12, tip: 6, base: 26, Color(red: 0.93, green: 0.83, blue: 0.7), blunt: 2)
                cone(4.5, tip: 6, base: 12, ink, blunt: 2)
                body(12, from: 26, ink, radius: 1)
                context.fill(Path(CGRect(x: middle - 6, y: 34, width: 12, height: 3)), with: .color(.white.opacity(0.75)))
            case .brush:
                // A brush's hair: a leaf from its point down to its foot, paler toward the foot.
                var hair = Path()
                hair.move(to: CGPoint(x: middle + 1, y: 4))
                hair.addQuadCurve(to: CGPoint(x: middle + 7, y: 40), control: CGPoint(x: middle + 9, y: 20))
                hair.addLine(to: CGPoint(x: middle - 7, y: 40))
                hair.addQuadCurve(to: CGPoint(x: middle + 1, y: 4), control: CGPoint(x: middle - 8, y: 22))
                context.fill(hair, with: .linearGradient(Gradient(colors: [ink, ink.opacity(0.35)]), startPoint: CGPoint(x: middle, y: 4), endPoint: CGPoint(x: middle, y: 40)))
                body(14, from: 40, ink.opacity(0.85))
            case .highlighter, .marker:
                // A felt tip cut aslant, in a dark collar, on a barrel of the colour.
                var tip = Path()
                let top = kind == .marker ? 12.0 : 8.0
                tip.move(to: CGPoint(x: middle - 4, y: top + 4)); tip.addLine(to: CGPoint(x: middle + 4, y: top)); tip.addLine(to: CGPoint(x: middle + 4, y: top + 12)); tip.addLine(to: CGPoint(x: middle - 4, y: top + 12)); tip.closeSubpath()
                context.fill(tip, with: .color(ink))
                context.fill(Path(roundedRect: CGRect(x: middle - 6, y: top + 11, width: 12, height: 13), cornerRadius: 2), with: .color(Color(white: 0.33)))
                body(kind == .marker ? 12 : 14, from: top + 23, ink.opacity(0.75))
            case .tape:
                context.fill(Path(roundedRect: CGRect(x: middle - 11, y: 22, width: 22, height: 30), cornerRadius: 3), with: .color(ink))
            }
        }
        .frame(width: 34, height: chosen ? 70 : 54)
        .frame(height: 70, alignment: .bottom)
        .opacity(chosen ? 1 : 0.92)
    }
}

/// How a pen's line is laid down, for the pens that offer it.
enum PenLine: Int, CaseIterable, Identifiable {
    /// As the pen writes: thinning where the hand moved fast. (What the Windows client keeps as 0.)
    case natural = 0
    case even, dashed, dotted

    var id: Int { rawValue }
    /// In the order of the panel's four buttons.
    static let shown: [PenLine] = [.even, .natural, .dashed, .dotted]
    var title: String {
        switch self {
        case .natural: return "Thins toward its end"
        case .even: return "Even line"
        case .dashed: return "Dashed line"
        case .dotted: return "Dotted line"
        }
    }
}

/// The pens (or the highlighters) with the size, colour and manner of the one in hand, and
/// the pens put by for quick access.
struct PenPanel: View {
    @Binding var pen: PenChoice

    private var row: [Pen] { pen.marking ? Pen.markers : Pen.pens }

    var body: some View {
        let kind = pen.active
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: pen.marking ? 14 : 6) {
                ForEach(row, id: \.kind) { candidate in
                    Button { pen.active = candidate.kind } label: { PenFigure(kind: candidate.kind, argb: pen.setting(of: candidate.kind).argb, chosen: candidate.kind == kind).contentShape(.rect) }
                        .buttonStyle(.plain)
                        .named(PenChoice.title(candidate.kind), above: true)
                        .accessibilityAddTraits(candidate.kind == kind ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { Divider() }

            LevelSlider(value: $pen.setting.level, label: "Size")
            if pen.setting.opacity != nil {
                LevelSlider(value: Binding(get: { pen.setting.opacity ?? 100 }, set: { pen.setting.opacity = $0 }), label: "How see-through", knob: pen.color, tint: pen.color)
            }
            if kind == .ballpoint || kind == .pencil {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 8) {
                    ForEach(PenLine.shown) { line in
                        Button { pen.setting.line = line.rawValue } label: { LinePreview(line: line, soft: kind == .pencil) }
                            .buttonStyle(.plain)
                            .background((pen.setting.line ?? 0) == line.rawValue ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .capsule)
                            .overlay { Capsule().strokeBorder(.secondary.opacity(0.45)) }
                            .help(line.title).accessibilityLabel(line.title)
                            .accessibilityAddTraits((pen.setting.line ?? 0) == line.rawValue ? .isSelected : [])
                    }
                }
            }
            Toggle("Straighten lines", isOn: Binding(get: { pen.setting.straight ?? false }, set: { pen.setting.straight = $0 })).toggleStyle(.switch).controlSize(.small).font(.callout.weight(.medium))
            if pen.marking {
                Toggle("Adjust thickness to text", isOn: Binding(get: { pen.setting.fit ?? false }, set: { pen.setting.fit = $0 })).toggleStyle(.switch).controlSize(.small).font(.callout.weight(.medium))
            }
            Palette(chosen: pen.setting.argb, recents: pen.recents) { pen.pick($0) }
            favourites
        }
    }

    /// Pens put by with all they were set to; one press takes one up again.
    private var favourites: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    let kept = PenChoice.Favourite(kind: pen.active, setting: pen.setting)
                    if !pen.favourites.contains(where: { $0.kind == kept.kind && $0.setting == kept.setting }) { pen.favourites.append(kept) }
                } label: { Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, minHeight: 28).contentShape(.capsule) }
                    .buttonStyle(.plain).overlay { Capsule().strokeBorder(.secondary.opacity(0.5), lineWidth: 1.2) }
                    .help("Add this pen to your favourites").accessibilityLabel("Add this pen to your favourites")
                Button {
                    pen.favourites.removeAll { $0.kind == pen.active && $0.setting == pen.setting }
                } label: { Image(systemName: "trash").font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 28).contentShape(.capsule) }
                    .buttonStyle(.plain).overlay { Capsule().strokeBorder(.secondary.opacity(0.3), lineWidth: 1.2) }
                    .disabled(!pen.favourites.contains { $0.kind == pen.active && $0.setting == pen.setting })
                    .help("Remove this pen from your favourites").accessibilityLabel("Remove this pen from your favourites")
            }
            let mine = pen.favourites.filter { $0.kind.isMarker == pen.marking }
            if mine.isEmpty {
                Text("Add your favorite pens here for quick access.").font(.callout.weight(.medium)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6), alignment: .leading, spacing: 4) {
                    ForEach(mine) { kept in
                        Button { pen.active = kept.kind; pen.setting = kept.setting } label: {
                            PenFigure(kind: kept.kind, argb: kept.setting.argb, chosen: kept.kind == pen.active && kept.setting == pen.setting).scaleEffect(0.7).frame(width: 34, height: 50)
                        }
                        .buttonStyle(.plain)
                        .help("\(PenChoice.title(kept.kind)), size \(Int(kept.setting.level))")
                        .accessibilityLabel("\(PenChoice.title(kept.kind)), size \(Int(kept.setting.level))")
                    }
                }
            }
        }
        .padding(.top, 6)
    }
}

/// One of the four kinds of line, drawn small.
private struct LinePreview: View {
    let line: PenLine
    let soft: Bool

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2, from = 14.0, to = size.width - 14
            let ink = GraphicsContext.Shading.color(.primary.opacity(soft ? 0.75 : 1))
            switch line {
            case .even:
                context.stroke(Path { $0.move(to: CGPoint(x: from, y: y)); $0.addLine(to: CGPoint(x: to, y: y)) }, with: ink, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            case .natural:
                var shape = Path()
                shape.move(to: CGPoint(x: from, y: y - 1.9)); shape.addLine(to: CGPoint(x: to, y: y - 0.3)); shape.addLine(to: CGPoint(x: to, y: y + 0.3)); shape.addLine(to: CGPoint(x: from, y: y + 1.9)); shape.closeSubpath()
                context.fill(shape, with: ink)
            case .dashed:
                context.stroke(Path { $0.move(to: CGPoint(x: from, y: y)); $0.addLine(to: CGPoint(x: to, y: y)) }, with: ink, style: StrokeStyle(lineWidth: 3.2, lineCap: .round, dash: [14, 8]))
            case .dotted:
                context.stroke(Path { $0.move(to: CGPoint(x: from, y: y)); $0.addLine(to: CGPoint(x: to, y: y)) }, with: ink, style: StrokeStyle(lineWidth: 3.2, lineCap: .round, dash: [0.1, 9]))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
        .contentShape(.capsule)
    }
}

/// A choice of two, as the Windows client draws them: a ring that fills.
private struct RadioRow: View {
    let title: String
    var symbol: String?
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().strokeBorder(on ? Color.accentColor : .secondary, lineWidth: 1.3).frame(width: 20, height: 20)
                    .overlay { if on { Circle().fill(Color.accentColor).frame(width: 11, height: 11) } }
                if let symbol { Image(systemName: symbol).font(.system(size: 15)).frame(width: 22) }
                Text(title).font(.callout)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// How the eraser rubs out.
struct EraserPanel: View {
    @Binding var eraser: EraserChoice
    let eraseAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RadioRow(title: "Stroke eraser", on: !eraser.area) { eraser.area = false }
            RadioRow(title: "Area eraser", on: eraser.area) { eraser.area = true }
            if eraser.area { LevelSlider(value: $eraser.level, range: 1...10, label: "Eraser size") }
            Toggle("Erase highlighter only", isOn: Binding(get: { eraser.highlighterOnly }, set: { eraser.highlighterOnly = $0; if $0 { eraser.tapeOnly = false } })).toggleStyle(.switch).controlSize(.small).font(.callout.weight(.medium))
            Toggle("Erase tape only", isOn: Binding(get: { eraser.tapeOnly }, set: { eraser.tapeOnly = $0; if $0 { eraser.highlighterOnly = false } })).toggleStyle(.switch).controlSize(.small).font(.callout.weight(.medium))
            if eraser.area {
                // How much the eraser takes, on a page shown about as wide as the window shows it.
                Circle().fill(.background).overlay { Circle().strokeBorder(.secondary) }
                    .frame(width: eraser.radius(pageWidth: 720) * 2, height: eraser.radius(pageWidth: 720) * 2)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .accessibilityHidden(true)
            }
            Divider()
            Button("Erase all handwriting", action: eraseAll).buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
        }
    }
}

/// How the selection tool picks.
struct SelectPanel: View {
    @Binding var picking: SelectChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RadioRow(title: "Lasso", symbol: "lasso", on: !picking.rectangle) { picking.rectangle = false }
            RadioRow(title: "Rectangle", symbol: "rectangle.dashed", on: picking.rectangle) { picking.rectangle = true }
            Toggle("Include partially selected objects", isOn: $picking.partial).toggleStyle(.switch).controlSize(.small).font(.callout.weight(.medium)).padding(.top, 8)
        }
    }
}

/// "Change style": another size, another colour for the handwriting that is picked.
struct StylePanel: View {
    let hasSelection: Bool
    let restyle: (UInt32?, Double?) -> Void
    @State private var level = 30.0
    @State private var argb: UInt32?
    @State private var recents: [UInt32] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change style").font(.headline)
            if !hasSelection {
                Text("Draw around some handwriting to pick it, then give it another size or colour here.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Size").font(.subheadline.weight(.semibold))
            LevelSlider(value: Binding(get: { level }, set: { level = $0; restyle(nil, $0) }), label: "Size")
            Text("Color").font(.subheadline.weight(.semibold)).padding(.top, 4)
            Palette(chosen: argb, recents: recents) { value in
                argb = value
                if !PenChoice.palette.contains(value) { recents = Array(([value] + recents.filter { $0 != value }).prefix(5)) }
                restyle(value, nil)
            }
        }
        .disabled(false)
    }
}

/// What the keyboard writes: the size and style of the letters, their colour and the colour
/// behind them, lists, and how the lines are set.
struct TextPanel: View {
    let text: TextController
    var addBox: () -> Void = {}

    static let sizes: [Double] = [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 22, 24, 26, 28, 32, 36, 40, 48, 54, 64]

    private func act(_ change: () -> Void) { change(); text.focus() }

    private func mark(_ symbol: String, _ help: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button { act(action) } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 40, height: 34)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
                .contentShape(.rect)
        }
        .buttonStyle(.plain).hoverHighlight(radius: 10).help(help).accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    var body: some View {
        let state = text.state
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "textformat.size").font(.system(size: 16, weight: .medium)).accessibilityHidden(true)
                Picker("Text size", selection: Binding(get: { state.size }, set: { size in act { text.setSize(size) } })) {
                    if !TextPanel.sizes.contains(state.size) { Text(String(format: "%g", state.size)).tag(state.size) }
                    ForEach(TextPanel.sizes, id: \.self) { Text("\(Int($0))").tag($0) }
                }
                .labelsHidden().frame(width: 96)
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                mark("bold", "Bold (⌘B)", state.bold) { text.toggle(NoteText.bold) }
                Spacer(minLength: 0)
                mark("italic", "Italic (⌘I)", state.italic) { text.toggle(NoteText.italic) }
                Spacer(minLength: 0)
                mark("underline", "Underline (⌘U)", state.underline) { text.toggle(NoteText.underline) }
                Spacer(minLength: 0)
                mark("strikethrough", "Strikethrough", state.strikethrough) { text.toggle(NoteText.strikethrough) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "character").font(.system(size: 15, weight: .semibold))
                        .overlay(alignment: .bottom) { Capsule().fill(PenChoice.color(state.color)).frame(width: 18, height: 2.5).offset(y: 5) }
                        .padding(.bottom, 4).help("Text colour").accessibilityLabel("Text colour")
                    Spacer()
                    ColorSetsButton()
                    AnyColor(chosen: state.color) { value in act { text.setColor(value) } }
                }
                Palette(chosen: state.color, offersAny: false) { value in act { text.setColor(value) } }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "character.textbox").font(.system(size: 16, weight: .medium)).help("Colour behind the text").accessibilityLabel("Colour behind the text")
                    Spacer()
                    AnyColor(chosen: state.highlight >> 24 == 0 ? nil : state.highlight) { value in act { text.setHighlight(value) } }
                }
                Palette(colors: PenChoice.backgrounds, chosen: state.highlight >> 24 == 0 ? nil : state.highlight, clear: { act { text.setHighlight(0) } }, offersAny: false) { value in act { text.setHighlight(value) } }
            }
            HStack(spacing: 0) {
                mark("checklist", "Checklist (⇧⌘L)", { if case .checkbox = state.mark { return true }; return false }()) { text.setMark(.checkbox(checked: false)) }
                Spacer(minLength: 0)
                mark("list.bullet", "Bulleted list", state.mark == .dot) { text.setMark(.dot) }
                Spacer(minLength: 0)
                mark("list.number", "Numbered list", state.mark == .number) { text.setMark(.number) }
            }
            HStack(spacing: 0) {
                mark("text.alignleft", "Align left", state.alignment == 0) { text.setAlignment(0) }
                Spacer(minLength: 0)
                mark("text.aligncenter", "Centre", state.alignment == 2) { text.setAlignment(2) }
                Spacer(minLength: 0)
                mark("text.alignright", "Align right", state.alignment == 1) { text.setAlignment(1) }
                Spacer(minLength: 0)
                mark("increase.indent", "Increase indent (Tab)", false) { text.indent(by: 1) }
                Spacer(minLength: 0)
                mark("decrease.indent", "Decrease indent (⇧Tab)", false) { text.indent(by: -1) }.disabled(state.indent == 0)
            }
            Divider()
            // A frame of text of its own, set down anywhere on the page, as the Windows client's keyboard has it.
            Button(action: addBox) {
                Label("Text box", systemImage: "character.textbox").font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 34).contentShape(.rect)
            }
            .buttonStyle(.plain).hoverHighlight(radius: 10)
            .help("Add a text box to the page").accessibilityLabel("Add text box")
        }
    }
}

/// What the pointer does: there is nothing to set, only what to do with it.
struct PointerPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Pointer", systemImage: "cursorarrow").font(.headline)
            Text("Click handwriting to pick the whole block it belongs to, or a text box or a picture, and drag to move it. Drag on an empty place to pick everything a rectangle holds, handwriting, text boxes and pictures together. Delete removes what is picked; a corner handle resizes it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The shapes the shape tool draws. (Samsung's clients have no such tool: its options are kept short.)
struct ShapePanel: View {
    @Binding var pen: PenChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(ShapeKind.allCases) { kind in
                    Button { pen.shape = kind.rawValue } label: {
                        Image(systemName: kind.symbol).font(.system(size: 16, weight: .medium)).frame(width: 44, height: 36)
                            .foregroundStyle(pen.shapeKind == kind ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background(pen.shapeKind == kind ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain).help(kind.title).accessibilityLabel(kind.title)
                    .accessibilityAddTraits(pen.shapeKind == kind ? .isSelected : [])
                }
            }
            Text("Drawn with the pen in hand, in its colour and size. Hold ⇧ for a straight line or a square.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// A tape as a small picture: a band in its colour or its pattern.
struct TapeSwatch: View {
    /// A pattern from 1 to 9, or nil for one colour.
    let pattern: Int?
    let argb: UInt32
    var wavy = false

    var body: some View {
        Canvas { context, size in
            var band = Path()
            if wavy {
                band.move(to: CGPoint(x: 0, y: size.height * 0.3))
                band.addQuadCurve(to: CGPoint(x: size.width, y: size.height * 0.25), control: CGPoint(x: size.width / 2, y: size.height * 0.55))
                band.addLine(to: CGPoint(x: size.width, y: size.height * 0.75))
                band.addQuadCurve(to: CGPoint(x: 0, y: size.height * 0.8), control: CGPoint(x: size.width / 2, y: size.height * 1.05))
                band.closeSubpath()
            } else {
                band = Path(CGRect(origin: .zero, size: size))
            }
            context.clip(to: band)
            let box = CGRect(origin: .zero, size: size)
            if let pattern, let found = Pen.tapePatterns[safe: pattern - 1] {
                context.fill(Path(box), with: .color(PenChoice.color(found.paper)))
                context.withCGContext { raw in
                    InkRenderer.drawPattern(found, in: box, cell: size.height * (wavy ? 0.22 : 0.42), ink: PenChoice.nsColor(found.ink).cgColor, context: raw)
                }
            } else {
                context.fill(Path(box), with: .color(PenChoice.color(argb)))
            }
        }
    }
}

/// The tape: how wide, straight or as drawn, and its colour or one of the nine patterns.
struct TapePanel: View {
    @Binding var pen: PenChoice
    /// Whether the note's tapes are all open; nil when it has none.
    let tapesOpen: Bool?
    let setTapes: (Bool) -> Void
    @State private var showsPatterns = true

    var body: some View {
        let setting = pen.setting(of: .tape)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tape").font(.headline)
                Spacer()
                Button { if let tapesOpen { setTapes(!tapesOpen) } } label: {
                    Image(systemName: tapesOpen == true ? "eye.slash" : "eye").font(.system(size: 14, weight: .medium)).frame(width: 30, height: 26).contentShape(.rect)
                }
                .buttonStyle(.plain).hoverHighlight().disabled(tapesOpen == nil)
                .help(tapesOpen == true ? "Cover everything under the tapes again" : "Show what is under every tape")
                .accessibilityLabel(tapesOpen == true ? "Cover everything under the tapes again" : "Show what is under every tape")
            }
            TapeSwatch(pattern: setting.pattern, argb: setting.argb, wavy: true)
                .frame(height: 40 + setting.level * 0.3)
                .frame(maxWidth: .infinity, minHeight: 76)
                .padding(.horizontal, 26)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            LevelSlider(value: Binding(get: { pen.setting(of: .tape).level }, set: { var changed = pen.setting(of: .tape); changed.level = $0; pen.settings[Pen.Kind.tape.rawValue] = changed }), label: "Tape width")
            Toggle("Straighten lines", isOn: bind(\.straight)).toggleStyle(.switch).controlSize(.small).font(.callout.weight(.medium))
            Toggle("Adjust thickness to text", isOn: bind(\.fit)).toggleStyle(.switch).controlSize(.small).font(.callout.weight(.medium))
            Divider()
            Picker("Tape look", selection: $showsPatterns) {
                Text("Color").tag(false)
                Text("Pattern").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            if showsPatterns {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(1...Pen.tapePatterns.count, id: \.self) { number in
                        Button { change { $0.pattern = number } } label: {
                            TapeSwatch(pattern: number, argb: 0).frame(height: 28).clipShape(.rect(cornerRadius: 6))
                                .overlay { if setting.pattern == number { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary, lineWidth: 2) } }
                        }
                        .buttonStyle(.plain)
                        .help("Pattern \(number)").accessibilityLabel("Pattern \(number)")
                        .accessibilityAddTraits(setting.pattern == number ? .isSelected : [])
                    }
                }
            } else {
                Palette(chosen: setting.pattern == nil ? setting.argb : nil, recents: pen.recents) { value in
                    change { $0.pattern = nil; $0.argb = value | 0xFF00_0000 }
                    if !PenChoice.palette.contains(value | 0xFF00_0000) { pen.recents = Array(([value | 0xFF00_0000] + pen.recents.filter { $0 != value | 0xFF00_0000 }).prefix(5)) }
                }
            }
        }
        .onAppear { showsPatterns = pen.setting(of: .tape).pattern != nil }
    }

    private func change(_ work: (inout PenChoice.Setting) -> Void) {
        var changed = pen.setting(of: .tape)
        work(&changed)
        pen.settings[Pen.Kind.tape.rawValue] = changed
    }

    private func bind(_ path: WritableKeyPath<PenChoice.Setting, Bool?>) -> Binding<Bool> {
        Binding(get: { pen.setting(of: .tape)[keyPath: path] ?? false }, set: { on in change { $0[keyPath: path] = on } })
    }
}
