import AppKit
import SamsungNotesKit
import SwiftUI

/// Sticky notes of Samsung's own kind: a small folded square on a page that opens into a
/// note of its own. Every client shows them and can write on them.
extension NoteSession {
    /// A sticky note of the note, and the page it is stuck on.
    func stickyObject(_ id: String) -> (object: NoteObject, page: Int)? {
        for (index, page) in (note?.document.pages ?? []).enumerated() {
            if let found = page.objects.first(where: { $0.kind == .sticky && $0.id == id }) { return (found, index) }
        }
        return nil
    }

    var stickyIDs: [String] { (note?.document.pages ?? []).flatMap { $0.objects.filter { $0.kind == .sticky }.map(\.id) } }

    /// Sticks a new, empty sticky note on a page: down its right margin, under those already
    /// there. Returns its id; it is in the note a moment later.
    @discardableResult
    func addSticky(page: Int, text: String = "", paper: UInt32 = StickyDocument.papers[0]) -> String? {
        guard canEdit, let document = note?.document, let sheet = document.pages[safe: page] else { return nil }
        let density = sheet.width / 360
        let side = LocalEdits.stickySide(pageWidth: sheet.width)
        let others = sheet.objects.filter { $0.kind == .sticky }
        var origin = CGPoint(x: sheet.width - side - 12 * density, y: 14 * density)
        // The first free place going down the margin.
        while others.contains(where: { abs($0.rect.minY - origin.y) < side * 0.8 && abs($0.rect.minX - origin.x) < side * 0.8 }), origin.y + side * 2.6 < sheet.height { origin.y += side * 1.3 }
        let id = UUID().uuidString.lowercased()
        let noteID = noteID
        write("The sticky note could not be added.", { edits in
            if try edits.addSticky(noteID, page: page, origin: origin, text: text, paper: paper, id: id) == nil { throw CocoaError(.fileWriteUnknown) }
        }, then: { [weak self] in self.map { session in Task { await session.load(text: false) } } })
        return id
    }

    private func changeStickyInMemory(_ id: String, _ change: (inout NoteObject) -> Void) -> Bool {
        guard var note else { return false }
        for page in note.document.pages.indices {
            guard let index = note.document.pages[page].objects.firstIndex(where: { $0.kind == .sticky && $0.id == id }) else { continue }
            change(&note.document.pages[page].objects[index])
            self.note = note
            bump(page)
            return true
        }
        return false
    }

    /// Gives a sticky note what it now says and the paper it is now on.
    func changeSticky(_ id: String, text: String, paper: UInt32) {
        guard canEdit, let found = stickyObject(id)?.object, found.stickyIsExact, let document = found.sticky else { return }
        guard document.text != text || (found.paper ?? document.paper) != paper else { return }
        let oldText = document.text, oldPaper = found.paper ?? document.paper
        undoManager?.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.changeSticky(id, text: oldText, paper: oldPaper) } }
        undoManager?.setActionName("Edit Sticky Note")
        _ = changeStickyInMemory(id) { object in
            object.sticky = document.with(text: text, paper: paper)
            object.paper = paper
        }
        let noteID = noteID
        write("The sticky note could not be changed.", { edits in
            _ = try edits.setSticky(noteID, id: id, text: text, paper: paper)
        }, then: { [weak self] in self.map { session in Task { await session.load(text: false) } } })
    }

    /// Moves a sticky note's square, to another page when it was dropped on one.
    func moveSticky(_ id: String, to rect: CGRect, page: Int) {
        guard canEdit, var note, let found = stickyObject(id), note.document.pages.indices.contains(page) else { return }
        let sheet = note.document.pages[page]
        var placed = rect
        placed.origin.x = min(max(placed.minX, 0), max(sheet.width - placed.width, 0))
        placed.origin.y = min(max(placed.minY, 0), max(sheet.height - placed.height, 0))
        guard placed != found.object.rect || page != found.page else { return }
        var object = found.object
        object.rect = placed
        note.document.pages[found.page].objects.removeAll { $0.kind == .sticky && $0.id == id }
        note.document.pages[page].objects.append(object)
        self.note = note
        bump(found.page); bump(page)
        let noteID = noteID, old = found.object.rect, oldPage = found.page
        write("The sticky note could not be moved.") { edits in try edits.moveSticky(noteID, id: id, to: placed, page: page) }
        undoManager?.registerUndo(withTarget: self) { session in MainActor.assumeIsolated { session.moveSticky(id, to: old, page: oldPage) } }
        undoManager?.setActionName("Move Sticky Note")
    }

    /// The paper of Samsung's own nearest to a colour.
    static func nearestPaper(_ argb: UInt32) -> UInt32 {
        func distance(_ other: UInt32) -> Int {
            [16, 8, 0].reduce(0) { sum, shift in
                let gap = Int((argb >> UInt32(shift)) & 0xFF) - Int((other >> UInt32(shift)) & 0xFF)
                return sum + gap * gap
            }
        }
        return StickyDocument.papers.min { distance($0) < distance($1) } ?? StickyDocument.papers[0]
    }

    /// Makes a sticky note or a table that an earlier build of this app kept as a picture into
    /// one of Samsung's own kind, in the picture's place and saying the same. Returns the new
    /// one's id; it is in the note a moment later.
    func convert(_ picture: String, from content: SmartPicture) -> String? {
        guard canEdit, let object = pictureObject(picture) else { return nil }
        // The text on disk must be the text on screen before it is changed there.
        saveNow()
        let id = UUID().uuidString.lowercased()
        let noteID = noteID
        switch content {
        case .sticky(let sticky):
            let paper = NoteSession.nearestPaper(sticky.color)
            write("The sticky note could not be converted.", { edits in
                if try edits.replaceWithSticky(noteID, picture: picture, text: sticky.text, paper: paper, id: id) == nil { throw CocoaError(.fileWriteUnknown) }
            }, then: { [weak self] in
                guard let self else { return }
                if object.inText { self.text.forgetUndo() }
                Task { await self.load(text: object.inText) }
            })
        case .table(let table):
            let texts = table.cells
            // A heading row was drawn in bold.
            let bold = table.header ? texts.indices.map { row in texts[row].map { _ in row == 0 } } : nil
            let offset = object.inText ? text.offset(afterObject: picture).map { $0 - 1 } : nil
            write("The table could not be converted.", { edits in
                if try edits.replaceWithTable(noteID, picture: picture, texts: texts, bold: bold, id: id) == nil { throw CocoaError(.fileWriteUnknown) }
            }, then: { [weak self] in
                guard let self else { return }
                Task {
                    await self.load(text: offset == nil)
                    self.text.forgetPictures()
                }
            })
            if let offset {
                // The same change in the text on screen, so that what is typed next is saved with it.
                let density = note?.document.density ?? 1
                arriving[id] = (nil, CGSize(width: (note.map { TextColumn($0.document).width } ?? 300) / density, height: Double(max(texts.count, 1)) * (15 * 1.35 + 8) + 20))
                text.removeObject(picture)
                text.insertObject(id, at: min(max(offset, 0), text.text.length), tail: "3,2", name: "Convert Table")
                text.forgetUndo()
            } else {
                text.forgetUndo()
            }
        }
        return id
    }

    func removeSticky(_ id: String) {
        guard canEdit, var note, let found = stickyObject(id) else { return }
        note.document.pages[found.page].objects.removeAll { $0.kind == .sticky && $0.id == id }
        self.note = note
        bump(found.page)
        let noteID = noteID
        write("The sticky note could not be removed.", { edits in try edits.removeSticky(noteID, id: id) },
              then: { [weak self] in self.map { session in Task { await session.load(text: false) } } })
    }
}

/// A sticky note lying open on its page: its paper, a strip along the top to change its
/// paper, delete it or fold it up again, and under it what it says, written in place.
struct StickyOpen: View {
    @Binding var text: String
    @Binding var paper: UInt32
    let side: CGFloat
    /// The size of its text, in points: that of the note's own text on screen.
    let fontSize: CGFloat
    /// False for one this Mac can only show (handwriting on it, or text set in ways it does not write).
    let editable: Bool
    let delete: () -> Void
    let close: () -> Void
    @FocusState private var typing: Bool

    private var strip: CGFloat { 30 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                if editable {
                    ForEach(StickyDocument.papers, id: \.self) { value in
                        Button { paper = value } label: {
                            Circle().fill(PenChoice.color(value)).frame(width: 17, height: 17)
                                .overlay { Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.75) }
                                .overlay { if paper == value { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.black.opacity(0.7)) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(["Yellow paper", "Green paper", "Red paper", "Blue paper"][safe: StickyDocument.papers.firstIndex(of: value) ?? 0] ?? "Paper")
                        .help(["Yellow", "Green", "Red", "Blue"][safe: StickyDocument.papers.firstIndex(of: value) ?? 0] ?? "")
                        .accessibilityAddTraits(paper == value ? .isSelected : [])
                    }
                } else {
                    Label("Read only", systemImage: "lock").font(.caption).foregroundStyle(Color.black.opacity(0.55))
                        .help("This sticky note holds handwriting or formatting this Mac cannot write, so it is only shown here.")
                }
                Spacer(minLength: 4)
                Button(action: delete) { Image(systemName: "trash").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22).contentShape(.rect) }
                    .buttonStyle(.plain).hoverHighlight(radius: 6).help("Delete this sticky note").accessibilityLabel("Delete sticky note")
                Button(action: close) { Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22).contentShape(.rect) }
                    .buttonStyle(.plain).hoverHighlight(radius: 6).help("Fold the sticky note up (Esc)").accessibilityLabel("Close sticky note")
            }
            .foregroundStyle(Color.black.opacity(0.65))
            .padding(.horizontal, 9)
            .frame(height: strip)
            .background(Color.black.opacity(0.08))
            Group {
                if editable {
                    TextEditor(text: $text)
                        .focused($typing)
                } else {
                    ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                }
            }
            .font(.system(size: fontSize))
            .foregroundStyle(Color(white: 0.13))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .accessibilityLabel("Sticky note text")
        }
        .frame(width: side, height: side)
        .background(PenChoice.color(paper))
        .clipShape(.rect(cornerRadius: 4))
        .shadow(color: .black.opacity(0.28), radius: 9, y: 4)
        // A strip of tape over its top edge, in the colour Samsung's clients give this paper's clip.
        .overlay(alignment: .top) {
            let clip = StickyDocument.clips[safe: StickyDocument.papers.firstIndex(of: paper) ?? 0] ?? StickyDocument.clips[0]
            RoundedRectangle(cornerRadius: 2.5)
                .fill(PenChoice.color(clip).opacity(0.92))
                .frame(width: 62, height: 20)
                .rotationEffect(.degrees(-7))
                .offset(y: -12)
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                .allowsHitTesting(false)
        }
        .colorScheme(.light)
        .onAppear { typing = editable }
    }
}
