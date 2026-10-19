import AppKit
import SamsungNotesKit
import SwiftUI

/// The notes of one section as cards or as a list, with selection as on the Mac.
struct NotesGridView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var windowActive
    let section: SidebarSection
    @FocusState private var focused: Bool
    @FocusState private var searching: Bool
    @State private var viewport = CGSize(width: 900, height: 600)
    /// The rectangle being dragged out over the notes, and what was selected when the drag began.
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<String> = []

    /// As many cards across as fit. Counted here rather than left to the grid, so that the
    /// up and down arrows know how far a row is.
    private var columns: Int { max(1, Int((viewport.width - 64 + 30) / (168 + 30))) }

    var body: some View {
        @Bindable var model = model
        let items = model.items(in: section)
        let chosen = model.selection
        let shownChosen = chosen.isEmpty ? 0 : items.reduce(0) { $0 + (chosen.contains($1.id) ? 1 : 0) }
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = model.lastError { banner(error) }
                    if items.isEmpty {
                        empty
                    } else if model.gridStyle == .grid {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 120, maximum: 210), spacing: 30, alignment: .top), count: columns), alignment: .leading, spacing: 26) {
                            ForEach(items) { item in
                                entry(item, items: items) { NoteCard(item: item, selected: chosen.contains(item.id), emphasized: focused && windowActive) }
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 14)
                        .padding(.bottom, 90)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                entry(item, items: items) { NoteRow(item: item, selected: chosen.contains(item.id), emphasized: focused && windowActive) }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 90)
                    }
                }
                // The whole of the visible area takes a click: one beside the notes deselects them.
                .frame(maxWidth: .infinity, minHeight: max(viewport.height - 60, 100), alignment: .topLeading)
                .background {
                    Color.clear.contentShape(.rect)
                        .onTapGesture {
                            model.clearSelection()
                            focused = true
                        }
                        .gesture(rubberBand)
                        // As in the Finder, the first click on a window in the background already counts.
                        .allowsWindowActivationEvents(true)
                }
                .overlayPreferenceValue(NoteFrames.self) { frames in
                    // The rectangle, and the notes under it: worked out here, where the cards' places are known.
                    GeometryReader { proxy in
                        if let marquee {
                            Rectangle().fill(Color.accentColor.opacity(0.12))
                                .overlay { Rectangle().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1) }
                                .frame(width: marquee.width, height: marquee.height)
                                .offset(x: marquee.minX, y: marquee.minY)
                                .onChange(of: marquee, initial: true) {
                                    let under = frames.filter { proxy[$0.value].intersects(marquee) }.map(\.key)
                                    let picked = marqueeBase.union(under)
                                    if picked != model.selection { model.selection = picked }
                                }
                        }
                    }
                    .allowsHitTesting(false)
                }
                .coordinateSpace(.named("notes"))
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
            // Pictures, PDFs and text files dropped on the notes become notes.
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter { $0.isFileURL && NoteFiles.canImport($0) }
                guard !files.isEmpty, section != .trash else { return false }
                NoteFiles.importFiles(files, in: model)
                return true
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: [.down, .repeat]) { key($0, items: items, scroller: scroller) }
            .onCommand(#selector(NSText.selectAll(_:))) { model.selectAll(items) }
            .accessibilityLabel(model.sectionTitle(section))
        }
        .background(.background)
        .overlay(alignment: .bottom) { if shownChosen >= 2 { SelectionBar(ids: chosen, inTrash: section == .trash).padding(.bottom, 18) } }
        .navigationTitle(model.sectionTitle(section))
        .navigationSubtitle(subtitle(items.count, chosen: shownChosen))
        .searchable(text: $model.search, placement: .toolbar, prompt: Text("Search"))
        .searchFocused($searching)
        .onChange(of: model.searchRequests) { searching = true }
        .onChange(of: model.renamingNote) { if model.renamingNote == nil { focused = true } }
        .onAppear { focused = true }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Text Note", systemImage: "keyboard") { model.createNote() }
                    Button("Handwritten Note", systemImage: "pencil.tip") { model.createNote(handwritten: true) }
                } label: {
                    Label("Create note", systemImage: "square.and.pencil").labelStyle(.titleAndIcon)
                } primaryAction: {
                    model.createNote()
                }
                .help("Create a note")
            }
            if section != .trash {
                ToolbarItem(placement: .primaryAction) {
                    Button { NoteFiles.chooseAndImportPDF(in: model) } label: { Label("Import PDF", systemImage: "doc.badge.plus").labelStyle(.titleAndIcon) }
                        .help("Make a note of a PDF: its pages become the note's pages (⌥⌘I)")
                }
            }
            if section == .trash {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.confirmEmptyTrash() } label: { Label("Empty Trash", systemImage: "trash.slash").labelStyle(.titleAndIcon) }
                        .help("Delete every note in the Trash for good")
                        .disabled(model.count(.trash) == 0)
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ViewOptions(model: model, shortcuts: false)
                } label: {
                    Label("View and Sort", systemImage: model.gridStyle.symbol)
                }
                .help("View and sort")
                .accessibilityLabel("View and sort")
            }
        }
    }

    /// Dragging from beside the notes draws a rectangle that selects what it touches; with ⌘ or ⇧
    /// it adds to what is selected already.
    private var rubberBand: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("notes"))
            .onChanged { drag in
                if marquee == nil {
                    let adding = !NSEvent.modifierFlags.isDisjoint(with: [.command, .shift])
                    marqueeBase = adding ? model.selection : []
                    model.renamingNote = nil
                    focused = true
                }
                marquee = CGRect(x: min(drag.startLocation.x, drag.location.x), y: min(drag.startLocation.y, drag.location.y),
                                 width: abs(drag.location.x - drag.startLocation.x), height: abs(drag.location.y - drag.startLocation.y))
            }
            .onEnded { _ in
                marquee = nil
                marqueeBase = []
                model.selectionAnchor = nil
                model.selectionCursor = nil
            }
    }

    private func subtitle(_ count: Int, chosen: Int) -> String {
        return chosen > 0 ? String(localized: "\(chosen) of \(Format.notes(count)) selected") : Format.notes(count)
    }

    // MARK: Cards and rows

    /// A card or row with everything a note answers to: clicks, the keyboard's target, dragging, its menu.
    private func entry<Content: View>(_ item: NoteItem, items: [NoteItem], @ViewBuilder content: () -> Content) -> some View {
        let selected = model.selection.contains(item.id)
        return content()
            .contentShape(.rect)
            .onTapGesture { clicked(item, items: items) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { opened(item) })
            .draggable(model.dragPayload(for: item.id)) { DragBadge(item: item, count: selected ? model.selection.count : 1) }
            .contextMenu { NoteActions(model: model, ids: selected ? model.selection : [item.id], context: true) }
            .anchorPreference(key: NoteFrames.self, value: .bounds) { [item.id: $0] }
            .id(item.id)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityValue(spoken(item))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.open(item.id) }
            .accessibilityAction(named: Text("Select")) { model.select(item.id) }
    }

    /// What VoiceOver says after a note's title: its date and what marks it carries.
    private func spoken(_ item: NoteItem) -> String {
        var parts = [Format.spokenDate(item.date)]
        if item.record.isFavorite { parts.append(String(localized: "Favorite")) }
        if item.record.isLocked { parts.append(String(localized: "Locked")) }
        if item.record.pending != nil { parts.append(String(localized: "Waiting to upload")) }
        return parts.joined(separator: ", ")
    }

    private func clicked(_ item: NoteItem, items: [NoteItem]) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        focused = true
        if (event?.clickCount ?? 1) >= 2, !flags.contains(.command), !flags.contains(.shift) { return opened(item) }
        model.click(item.id, in: items, modifiers: flags)
    }

    /// A double-click opens the note; with ⌥ in a window of its own.
    private func opened(_ item: NoteItem) {
        if NSEvent.modifierFlags.contains(.option) {
            openWindow(id: "note", value: item.id)
        } else {
            model.open(item.id)
        }
    }

    // MARK: Keyboard

    private func key(_ press: KeyPress, items: [NoteItem], scroller: ScrollViewProxy) -> KeyPress.Result {
        guard model.renamingNote == nil else { return .ignored }
        let extending = press.modifiers.contains(.shift)
        let row = model.gridStyle == .grid ? columns : 1
        func move(_ step: Int) -> KeyPress.Result {
            if let id = model.moveSelection(by: step, in: items, extending: extending) { withAnimation(.snappy(duration: 0.15)) { scroller.scrollTo(id) } }
            return .handled
        }
        switch press.key {
        case .upArrow: return move(-row)
        case .downArrow: return move(row)
        case .leftArrow: return model.gridStyle == .grid ? move(-1) : .ignored
        case .rightArrow: return model.gridStyle == .grid ? move(1) : .ignored
        case .escape:
            guard !model.selection.isEmpty else { return .ignored }
            model.clearSelection()
            return .handled
        default: break
        }
        guard press.phase == .down else { return .ignored }
        let chosen = model.ordered(model.selection.intersection(items.map(\.id)))
        // The Delete key arrives as the character it types (U+007F), not as the key equivalent of a menu.
        if press.key == .delete || press.key == .deleteForward || ["\u{7F}", "\u{8}", "\u{F728}"].contains(press.characters) {
            guard !chosen.isEmpty, press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
            if section == .trash { model.confirmDeleteForever(Set(chosen)) } else { model.setTrashed(Set(chosen), true) }
            return .handled
        }
        switch press.key {
        case .return:
            guard let first = chosen.first else { return .ignored }
            if press.modifiers.contains(.option) { for id in chosen.prefix(8) { openWindow(id: "note", value: id) } } else { model.open(first) }
            return .handled
        case .space:
            guard !chosen.isEmpty || QuickLook.shared.isVisible else { return .ignored }
            QuickLook.shared.toggle(chosen, in: model)
            return .handled
        default:
            if press.characters == "a", press.modifiers == .command {
                model.selectAll(items)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: When there is nothing to list

    private func banner(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 8)
            Button { model.lastError = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 28)
        .padding(.top, 8)
    }

    private var empty: some View {
        let searching = !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let symbol: String
        let text: String
        if searching {
            symbol = "magnifyingglass"
            text = String(localized: "No results")
        } else {
            switch section {
            case .trash: symbol = "trash"; text = String(localized: "Trash is empty")
            case .favorites: symbol = "star"; text = String(localized: "No favorites yet")
            default: symbol = "note.text"; text = model.isSyncing ? String(localized: "Getting your notes…") : String(localized: "No notes yet")
            }
        }
        return VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 46, weight: .light)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(text).font(.title3).foregroundStyle(.secondary)
            if searching {
                Button("Clear Search") { model.search = "" }.buttonStyle(.link)
            } else if section == .favorites {
                Text("Notes you mark with a star are gathered here.").font(.callout).foregroundStyle(.secondary)
            } else if section != .trash, !model.isSyncing {
                Button("Create a Note") { model.createNote() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
                if !model.signedIn, model.library.notes.isEmpty {
                    Text("Notes are kept on this Mac. To see the ones in your Samsung account and keep them in sync, turn on sync in Settings.")
                        .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button("Turn On Sync…") { model.showSyncSettings() }.buttonStyle(.link)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 130)
    }
}

/// Where each card or row on screen is, for the selection rectangle.
private struct NoteFrames: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - View and sort

/// Grid or list, and the order: the same choices in the toolbar and in the View menu.
struct ViewOptions: View {
    @Bindable var model: AppModel
    let shortcuts: Bool

    var body: some View {
        if shortcuts {
            Toggle(GridStyle.grid.title, systemImage: GridStyle.grid.symbol, isOn: style(.grid)).keyboardShortcut("1", modifiers: .command)
            Toggle(GridStyle.list.title, systemImage: GridStyle.list.symbol, isOn: style(.list)).keyboardShortcut("2", modifiers: .command)
            Divider()
            Menu("Sort By") { sorting }
        } else {
            Toggle(GridStyle.grid.title, systemImage: GridStyle.grid.symbol, isOn: style(.grid))
            Toggle(GridStyle.list.title, systemImage: GridStyle.list.symbol, isOn: style(.list))
            Divider()
            Section("Sort By") { sorting }
        }
    }

    @ViewBuilder private var sorting: some View {
        Picker("Sort By", selection: $model.sort) {
            ForEach(SortKey.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Picker("Order", selection: $model.ascending) {
            Text(model.sort == .title ? String(localized: "A to Z") : String(localized: "Oldest First")).tag(true)
            Text(model.sort == .title ? String(localized: "Z to A") : String(localized: "Newest First")).tag(false)
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private func style(_ style: GridStyle) -> Binding<Bool> {
        Binding(get: { model.gridStyle == style }, set: { if $0 { model.gridStyle = style } })
    }
}

// MARK: - What can be done with notes

/// The actions on one or several notes: in the context menu of a card, and in the Note menu.
struct NoteActions: View {
    let model: AppModel
    let ids: Set<String>
    /// The context menu lists only what applies; the menu bar lists everything and disables.
    var context = false
    /// True when the notes are shown in a window of their own, where "Open" has nothing to do.
    var ownWindow = false
    @Environment(\.openWindow) private var openWindow

    private var ordered: [String] { model.ordered(ids) }

    var body: some View {
        let records = ids.compactMap { model.library.notes[$0] }
        let any = !records.isEmpty
        let trashed = any && ids.allSatisfy { model.isTrashed($0) }
        let normal = any && !ids.contains { model.isTrashed($0) }
        let single = records.count == 1 ? records.first : nil
        let allFavorite = any && records.allSatisfy(\.isFavorite)
        let alreadyOpen = ownWindow || !model.path.isEmpty

        if !context || !trashed {
            Button("Open", systemImage: "doc.text") { if let id = ordered.first { model.showMainWindow?(); model.open(id) } }
                .keyboardShortcut(context ? nil : KeyboardShortcut("o", modifiers: .command))
                .disabled(single == nil || alreadyOpen)
            Button("Open in New Window", systemImage: "macwindow.badge.plus") { for id in ordered.prefix(8) { openWindow(id: "note", value: id) } }
                .keyboardShortcut(context ? nil : KeyboardShortcut("o", modifiers: [.command, .option]))
                .disabled(!any || ownWindow)
        }
        Button("Quick Look", systemImage: "eye") { QuickLook.shared.toggle(ordered, in: model) }
            .keyboardShortcut(context ? nil : KeyboardShortcut("y", modifiers: .command))
            .disabled(!any)
        Divider()
        if !context || !trashed {
            Button("Rename…", systemImage: "pencil") { if let single { model.beginRename(single.id) } }
                .disabled(single == nil || single?.isLocked == true || !normal)
            Button(allFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: allFavorite ? "star.slash" : "star") { model.setFavorite(ordered, !allFavorite) }
                .keyboardShortcut(context ? nil : KeyboardShortcut("f", modifiers: [.command, .shift]))
                .disabled(!normal)
            let allLocked = !records.isEmpty && records.allSatisfy(\.isLocked)
            Button(allLocked ? "Unlock" : "Lock", systemImage: allLocked ? "lock.open" : "lock") { model.askToLock(ordered, !allLocked) }
                .disabled(!normal || !any)
            Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(ordered) }
                .keyboardShortcut(context ? nil : KeyboardShortcut("d", modifiers: .command))
                .disabled(!normal || records.contains(where: \.isLocked))
            Menu("Move To", systemImage: "folder") {
                Button("Notes (No Folder)") { model.move(ids, to: TreeNode.rootID) }
                FolderChoices(model: model, parent: TreeNode.rootID, depth: 0) { model.move(ids, to: $0) }
            }
            .disabled(!normal)
            Divider()
        }
        if context {
            Button("Export as PDF…", systemImage: "arrow.down.doc") { NoteExport.export(ordered, in: model) }
            Button("Share…", systemImage: "square.and.arrow.up") { NoteExport.share(ordered, in: model) }
            Button("Print…", systemImage: "printer") { NoteExport.print(ordered, in: model) }
            Divider()
        }
        if !context || !trashed {
            Button("Move to Trash", systemImage: "trash", role: .destructive) { NoteActions.trash(ids, in: model) }
                .keyboardShortcut(context ? nil : KeyboardShortcut(.delete, modifiers: .command))
                .disabled(!any || trashed)
        }
        if !context || trashed {
            Button("Restore", systemImage: "arrow.uturn.backward") { model.setTrashed(ids, false) }
                .disabled(!trashed)
            Button("Delete Forever…", systemImage: "trash.slash", role: .destructive) { model.confirmDeleteForever(ids) }
                .disabled(!trashed)
        }
    }

    /// ⌘⌫ belongs to the text being typed when there is any: there it deletes to the start of the line.
    static func trash(_ ids: Set<String>, in model: AppModel) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, NSApp.currentEvent?.type == .keyDown {
            text.deleteToBeginningOfLine(nil)
            return
        }
        model.setTrashed(ids.filter { !model.isTrashed($0) }, true)
    }
}

/// The folders as menu items, indented by depth.
struct FolderChoices: View {
    let model: AppModel
    let parent: String
    let depth: Int
    let choose: (String) -> Void

    var body: some View {
        ForEach(model.folders(in: parent)) { folder in
            Button(String(repeating: "\u{2003}", count: depth) + (folder.name.isEmpty ? String(localized: "Folder") : folder.name)) { choose(folder.id) }
            if depth < 8 { FolderChoices(model: model, parent: folder.id, depth: depth + 1, choose: choose) }
        }
    }
}

/// The floating summary of a selection of several notes.
private struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let ids: Set<String>
    let inTrash: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(ids.count) selected").font(.callout.weight(.medium)).monospacedDigit().padding(.leading, 6)
            Divider().frame(height: 18)
            if inTrash {
                Button { model.setTrashed(ids, false) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                Button(role: .destructive) { model.confirmDeleteForever(ids) } label: { Label("Delete…", systemImage: "trash.slash") }
            } else {
                Menu {
                    Button("Notes (No Folder)") { model.move(ids, to: TreeNode.rootID) }
                    FolderChoices(model: model, parent: TreeNode.rootID, depth: 0) { model.move(ids, to: $0) }
                } label: { Label("Move", systemImage: "folder") }
                .fixedSize()
                Button { model.setTrashed(ids, true) } label: { Label("Move to Trash", systemImage: "trash") }
            }
            Button { model.clearSelection() } label: { Image(systemName: "xmark") }
                .help("Deselect all")
                .accessibilityLabel("Deselect all")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.glass)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
    }
}

/// What follows the pointer while notes are dragged.
private struct DragBadge: View {
    let item: NoteItem
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: count > 1 ? "square.stack" : "note.text")
            Text(count > 1 ? Format.notes(count) : item.title).lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
    }
}

// MARK: - Pieces of a card

struct NoteThumbnail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let record: NoteRecord
    var corner: CGFloat = 22
    @State private var image: NSImage?
    @State private var imageKey = ""

    var body: some View {
        let dark = scheme == .dark
        let key = ThumbnailCache.key(record, dark: dark)
        // A locked note keeps its content to itself, on the card as on the phone.
        let shown = record.isLocked ? nil : (imageKey == key ? image : model.thumbnails.cached(record, dark: dark) ?? image)
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(dark ? Color(white: 0.11) : Color(white: 0.99))
            if let shown {
                Image(nsImage: shown).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            }
            if record.isLocked {
                Image(systemName: "lock.fill").font(.title2).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.primary.opacity(dark ? 0.14 : 0.06)) }
        .shadow(color: .black.opacity(dark ? 0.35 : 0.10), radius: 9, y: 3)
        .task(id: key) {
            guard !record.isLocked else { return }
            let loaded = await model.thumbnails.image(for: record, dark: dark, store: model.store)
            guard !Task.isCancelled else { return }
            image = loaded
            imageKey = key
        }
        .accessibilityHidden(true)
    }
}

/// The colour of a selection: the accent while the list has the keyboard, grey otherwise.
private func selectionTint(_ emphasized: Bool) -> Color {
    emphasized ? Color(nsColor: .selectedContentBackgroundColor) : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
}

/// A name typed in place: Return keeps it, Escape leaves it as it was.
struct RenameField: View {
    let initial: String
    let placeholder: String
    var alignment: TextAlignment = .leading
    /// Called once, with the new name or with nil when the change is given up.
    let finish: (String?) -> Void
    @State private var text = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2) }
            .focused($focused)
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { end(text) }
            .onExitCommand { end(nil) }
            .onChange(of: focused) { if !focused { end(text) } }
            .accessibilityLabel(placeholder)
    }

    private func end(_ value: String?) {
        guard !done else { return }
        done = true
        finish(value)
    }
}

struct NoteCard: View {
    @Environment(AppModel.self) private var model
    let item: NoteItem
    let selected: Bool
    let emphasized: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            NoteThumbnail(record: item.record)
                .overlay(alignment: .topTrailing) {
                    if item.record.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).padding(10) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if item.record.pending != nil { Image(systemName: "arrow.up.circle.fill").foregroundStyle(.secondary).padding(9).help("Waiting to be sent to Samsung Cloud") }
                }
                .scaleEffect(hovering && !selected ? 1.02 : 1)
                .animation(.snappy(duration: 0.18), value: hovering)
                .padding(5)
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(selectionTint(emphasized), lineWidth: 3) }
                }
            VStack(spacing: 2) {
                if model.renamingNote == item.id {
                    RenameField(initial: model.editableTitle(item), placeholder: String(localized: "Title"), alignment: .center) { name in
                        if let name { model.rename(item.id, to: name) }
                        model.renamingNote = nil
                    }
                    .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
                        .foregroundStyle(selected && emphasized ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background { if selected { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selectionTint(emphasized)) } }
                }
                Text(Format.cardDate(item.date)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .onHover { hovering = $0 }
    }
}

struct NoteRow: View {
    @Environment(AppModel.self) private var model
    let item: NoteItem
    let selected: Bool
    let emphasized: Bool

    /// The line under the title: the start of the text, or what kind of note it is. A locked note says only that.
    static func summary(_ record: NoteRecord) -> String {
        if record.isLocked { return String(localized: "Locked") }
        if !record.preview.isEmpty { return record.preview.replacingOccurrences(of: "\n", with: " ") }
        return record.hasInk ? String(localized: "Handwriting") : String(localized: "No text")
    }

    var body: some View {
        let bright = selected && emphasized
        HStack(spacing: 14) {
            NoteThumbnail(record: item.record, corner: 10).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                if model.renamingNote == item.id {
                    RenameField(initial: model.editableTitle(item), placeholder: String(localized: "Title")) { name in
                        if let name { model.rename(item.id, to: name) }
                        model.renamingNote = nil
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: 360)
                } else {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }
                Text(NoteRow.summary(item.record))
                    .font(.callout).foregroundStyle(bright ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)).lineLimit(1)
            }
            Spacer(minLength: 12)
            if item.record.pending != nil { Image(systemName: "arrow.up.circle.fill").foregroundStyle(bright ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)).help("Waiting to be sent to Samsung Cloud") }
            if item.record.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            Text(Format.cardDate(item.date)).font(.callout).monospacedDigit().foregroundStyle(bright ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
        }
        .foregroundStyle(bright ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.primary))
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background { if selected { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selectionTint(emphasized)) } }
        .overlay(alignment: .bottom) { if !selected { Divider().padding(.leading, 76) } }
    }
}
