import AppKit
import SamsungNotesKit

/// Picking notes as on the Mac: a click picks one, ⌘ adds or removes, ⇧ extends, the arrows move.
extension AppModel {
    func clearSelection() {
        if !selection.isEmpty { selection = [] }
        selectionAnchor = nil
        selectionCursor = nil
        if renamingNote != nil { renamingNote = nil }
    }

    func select(_ id: String) {
        selection = [id]
        selectionAnchor = id
        selectionCursor = id
    }

    func selectAll(_ items: [NoteItem]) {
        selection = Set(items.map(\.id))
        selectionAnchor = items.first?.id
        selectionCursor = items.last?.id
    }

    /// The picked notes in the order the list shows them.
    func ordered(_ ids: Set<String>) -> [String] {
        guard ids.count > 1, let section else { return Array(ids) }
        let shown = items(in: section).map(\.id).filter(ids.contains)
        return shown.count == ids.count ? shown : shown + ids.subtracting(shown)
    }

    func click(_ id: String, in items: [NoteItem], modifiers: NSEvent.ModifierFlags) {
        if renamingNote != nil, renamingNote != id { renamingNote = nil }
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
            selectionCursor = id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor ?? selection.first,
                  let from = items.firstIndex(where: { $0.id == anchor }), let to = items.firstIndex(where: { $0.id == id }) {
            selection = Set(items[min(from, to)...max(from, to)].map(\.id))
            selectionAnchor = anchor
            selectionCursor = id
        } else {
            select(id)
        }
    }

    /// Moves the selection with the arrow keys. Returns the note to bring into view.
    @discardableResult
    func moveSelection(by step: Int, in items: [NoteItem], extending: Bool) -> String? {
        guard !items.isEmpty else { return nil }
        let visible = selection.intersection(items.map(\.id))
        guard !visible.isEmpty, let cursor = selectionCursor.flatMap({ id in items.firstIndex { $0.id == id } }) ?? items.firstIndex(where: { visible.contains($0.id) }) else {
            let start = step < 0 ? items.count - 1 : 0
            select(items[start].id)
            return items[start].id
        }
        var target = cursor + step
        if target < 0 || target >= items.count {
            // A step of a whole row past the end goes to the end; a step past the start stays.
            guard abs(step) > 1, step > 0, cursor / abs(step) < (items.count - 1) / abs(step) else { return items[cursor].id }
            target = items.count - 1
        }
        let id = items[target].id
        if extending, let anchor = selectionAnchor.flatMap({ id in items.firstIndex { $0.id == id } }) ?? Optional(cursor) {
            selection = Set(items[min(anchor, target)...max(anchor, target)].map(\.id))
            selectionAnchor = items[anchor].id
            selectionCursor = id
        } else {
            select(id)
        }
        return id
    }

    /// The name to start from when a note is renamed: its own, not one made up from its date.
    func editableTitle(_ item: NoteItem) -> String {
        if !item.record.title.isEmpty { return item.record.title }
        return item.node?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Starts typing a note's name in place when it is on screen, otherwise asks for it.
    func beginRename(_ id: String) {
        guard let record = library.notes[id], !record.isLocked else { return }
        if path.isEmpty, let section, items(in: section).contains(where: { $0.id == id }) {
            select(id)
            renamingNote = id
        } else if let name = Dialogs.askName(title: String(localized: "Rename note"), value: item(id).map(editableTitle) ?? record.title, placeholder: String(localized: "Title"), action: String(localized: "Rename")) {
            rename(id, to: name)
        }
    }

    // MARK: Dragging

    /// What is dragged when a drag starts on this note: the whole selection when the note is part of it.
    func dragPayload(for id: String) -> String {
        DragPayload.notes(selection.contains(id) ? ordered(selection) : [id])
    }

    /// Something dropped on a row of the sidebar.
    func drop(_ strings: [String], on target: SidebarSection) -> Bool {
        let dropped = DragPayload.parse(strings)
        let notes = dropped.notes.filter { library.notes[$0] != nil }
        let folders = dropped.folders.filter { library.nodes[$0]?.kind == .folder && !$0.contains(":") }
        guard !notes.isEmpty || !folders.isEmpty else { return false }
        switch target {
        case .all:
            setTrashed(notes.filter(isTrashed), false)
            move(notes, to: TreeNode.rootID)
            for folder in folders { moveFolder(folder, to: TreeNode.rootID) }
        case .favorites:
            guard !notes.isEmpty else { return false }
            setFavorite(Array(notes), true)
        case .trash:
            setTrashed(notes, true)
            if let folder = folders.first { confirmDeleteFolder(folder) }
        case .folder(let id):
            setTrashed(notes.filter(isTrashed), false)
            move(notes, to: id)
            for folder in folders { moveFolder(folder, to: id) }
        }
        return true
    }
}

/// Notes and folders travel between the list and the sidebar as text with a prefix of their own.
enum DragPayload {
    private static let notePrefix = "snotes-notes:"
    private static let folderPrefix = "snotes-folder:"

    static func notes(_ ids: [String]) -> String { notePrefix + ids.joined(separator: ",") }
    static func folder(_ id: String) -> String { folderPrefix + id }

    static func parse(_ strings: [String]) -> (notes: Set<String>, folders: [String]) {
        var notes: Set<String> = []
        var folders: [String] = []
        for string in strings {
            if string.hasPrefix(notePrefix) {
                notes.formUnion(string.dropFirst(notePrefix.count).split(separator: ",").map(String.init))
            } else if string.hasPrefix(folderPrefix) {
                folders.append(String(string.dropFirst(folderPrefix.count)))
            }
        }
        return (notes, folders)
    }
}
