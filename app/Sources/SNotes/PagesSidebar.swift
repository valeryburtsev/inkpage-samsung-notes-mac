import AppKit
import SamsungNotesKit
import SwiftUI

/// The pages of a note down the side of its window, small: press one to go to it, drag one to
/// another place, and add or delete pages. Like the page list of Samsung Notes and Preview.
struct PagesSidebar: View {
    let session: NoteSession
    let dark: Bool
    /// The page the note is scrolled to.
    let current: Int
    let open: (Int) -> Void
    /// The gap a page being dragged would go into: before the page of this number (the count of
    /// pages for after the last). And the page being dragged.
    @State private var gap: Int?
    @State private var dragging: Int?
    /// How high each page's tile stands, to tell its upper half from its lower.
    @State private var heights: [Int: CGFloat] = [:]
    @FocusState private var focused: Bool

    static let width: CGFloat = 172
    private let thumb: CGFloat = 112

    var body: some View {
        VStack(spacing: 0) {
            if let note = session.note, let images = session.images {
                let layout = NoteLayout(note.document, shown: session.visiblePages)
                header(count: layout.pageCount)
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(0..<layout.pageCount, id: \.self) { index in
                                page(index, note: note, images: images, layout: layout)
                            }
                            if session.canEdit, session.hasPages { addTile(layout) }
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: current) { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(current, anchor: .center) } }
                }
            } else {
                Spacer()
            }
        }
        .frame(width: PagesSidebar.width)
        .frame(maxHeight: .infinity)
        // A bar of its own grey beside the lighter table the pages lie on; under the toolbar, not
        // up into it, where it ended halfway across the title bar.
        .background(dark ? Color(white: 0.155) : Color(white: 0.9), ignoresSafeAreaEdges: [])
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onDeleteCommand { if session.canEdit { delete(current) } }
        .onMoveCommand { direction in
            if direction == .up { open(max(current - 1, 0)) }
            if direction == .down { open(min(current + 1, session.visiblePages - 1)) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pages")
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 5) {
            Text("\(min(current, count - 1) + 1)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.quaternary, in: .rect(cornerRadius: 5))
            Text("/ \(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if session.canEdit, session.hasPages {
                Button { add(after: current) } label: { Image(systemName: "plus").frame(width: 24, height: 22).contentShape(.rect) }
                    .buttonStyle(.plain)
                    .hoverHighlight(radius: 6)
                    .help("Add a page after page \(current + 1)")
                    .accessibilityLabel("Add a page after this one")
                Button { delete(current) } label: { Image(systemName: "trash").frame(width: 24, height: 22).contentShape(.rect) }
                    .buttonStyle(.plain)
                    .hoverHighlight(radius: 6)
                    .disabled(count <= 1)
                    .help(count <= 1 ? "A note keeps at least one page" : "Delete page \(current + 1)")
                    .accessibilityLabel("Delete this page")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    private func page(_ index: Int, note: LoadedNote, images: NoteImages, layout: NoteLayout) -> some View {
        let height = thumb * layout.height(index) / layout.pageWidth
        let chosen = index == current
        return VStack(spacing: 5) {
            PageView(note: note, images: images, index: index, width: thumb, dark: dark, revision: session.pageRevisions[safe: index] ?? 0, text: true)
                .frame(width: thumb, height: height)
                .overlay(alignment: .bottomTrailing) {
                    if session.canEdit {
                        Menu { actions(index, count: layout.pageCount) } label: {
                            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                                .frame(width: 22, height: 26).contentShape(.rect)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("What can be done with page \(index + 1)")
                        .accessibilityLabel("Page \(index + 1) actions")
                    }
                }
            Text("\(index + 1)").font(.caption.monospacedDigit().weight(chosen ? .semibold : .regular)).foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
        // The page the note is at stands on a tinted tile, as in Preview.
        .background(chosen ? AnyShapeStyle(Color.accentColor.opacity(dark ? 0.75 : 0.6)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
        // The gap between two tiles belongs to them both, half each: a drag over it is over one of them.
        .padding(.vertical, PagesSidebar.halfGap)
        .contentShape(.rect)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[index] = $0 }
        // Where the page being dragged would go: a line in the middle of the gap, above this tile or below it.
        .overlay(alignment: .top) { if gap == index { dropLine.offset(y: -1.5) } }
        .overlay(alignment: .bottom) { if gap == index + 1, index == layout.pageCount - 1 { dropLine.offset(y: 1.5) } }
        .onTapGesture { focused = true; open(index) }
        .contextMenu { if session.canEdit { actions(index, count: layout.pageCount) } }
        .onDrag {
            dragging = index
            return NSItemProvider(object: (PagesSidebar.token + String(index)) as NSString)
        }
        .onDrop(of: [.plainText, .text], delegate: PageDrop(index: index, count: layout.pageCount, height: heights[index] ?? 1, dragging: $dragging, gap: $gap) { from, to in
            guard session.canEdit else { return }
            session.movePage(from, to: to)
            open(to)
        })
        .id(index)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(index + 1)")
        .accessibilityAction { focused = true; open(index) }
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private static let token = "snotes-page:"
    private static let halfGap: CGFloat = 2

    private var dropLine: some View {
        Capsule().fill(Color.accentColor).frame(width: thumb + 16, height: 3).allowsHitTesting(false)
    }

    @ViewBuilder private func actions(_ index: Int, count: Int) -> some View {
        Button("Add Page Above", systemImage: "rectangle.stack.badge.plus") { session.addPage(after: index - 1); open(index) }
        Button("Add Page Below", systemImage: "rectangle.stack.badge.plus") { add(after: index) }
        Divider()
        Button("Move Up", systemImage: "arrow.up") { session.movePage(index, to: index - 1); open(index - 1) }.disabled(index == 0)
        Button("Move Down", systemImage: "arrow.down") { session.movePage(index, to: index + 1); open(index + 1) }.disabled(index >= count - 1)
        Divider()
        Button("Delete Page", systemImage: "trash", role: .destructive) { delete(index) }.disabled(count <= 1)
    }

    private func addTile(_ layout: NoteLayout) -> some View {
        Button { add(after: layout.pageCount - 1) } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(dark ? Color(white: 0.16) : Color.white)
                .frame(width: thumb, height: thumb * layout.pageHeight / layout.pageWidth)
                .overlay { Image(systemName: "plus").font(.system(size: 26, weight: .light)).foregroundStyle(Color.accentColor) }
                .shadow(color: .black.opacity(dark ? 0.4 : 0.1), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .help("Add a page at the end")
        .accessibilityLabel("Add a page at the end")
    }

    private func add(after index: Int) {
        session.addPage(after: index)
        open(index + 1)
    }

    /// Deletes a page. What is drawn or placed on it goes with it and cannot be brought back,
    /// so a page that holds something is asked about first.
    private func delete(_ index: Int) {
        guard session.visiblePages > 1 else { return }
        if session.pageHoldsSomething(index) {
            let alert = NSAlert()
            alert.messageText = "Delete page \(index + 1)?"
            alert.informativeText = "What is drawn and placed on this page is deleted with it. The note's text stays: it flows on over the pages that are left. This cannot be undone."
            alert.addButton(withTitle: "Delete Page").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        session.removePage(index)
        open(min(index, session.visiblePages - 2))
    }
}

/// A drag of a page over another page's tile: over its upper half the page would go before it,
/// over its lower half after it. Dropped, it is moved there.
private struct PageDrop: DropDelegate {
    let index: Int
    let count: Int
    let height: CGFloat
    @Binding var dragging: Int?
    @Binding var gap: Int?
    let move: (_ from: Int, _ to: Int) -> Void

    /// The gap under the pointer: before this page or after it.
    private func gap(_ info: DropInfo) -> Int { info.location.y < height / 2 ? index : index + 1 }

    /// A gap right before or right after the page being dragged leaves it where it is.
    private func moves(to gap: Int) -> Bool {
        guard let from = dragging else { return false }
        return gap != from && gap != from + 1
    }

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) { dropUpdated(info: info).map { _ in () } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let at = gap(info)
        let shown = moves(to: at) ? at : nil
        if gap != shown { gap = shown }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if gap == index || gap == index + 1 { gap = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let at = gap(info)
        defer { gap = nil; dragging = nil }
        guard let from = dragging, moves(to: at) else { return false }
        // The page's new number, once it is out of its old place.
        move(from, from < at ? at - 1 : at)
        return true
    }
}
