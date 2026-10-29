import AppKit
import SamsungNotesKit
import SwiftUI

/// The menu bar. Items act on the note of the window in front when it shows one note, otherwise
/// on the open note or the selection of the main window.
struct AppCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowNote) private var windowNote

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .help) {
            Button("\(LocalStore.appName) Privacy Policy") { model.showPrivacyPolicy?() }
            Button("\(LocalStore.appName) Terms of Use") { model.showTermsOfUse?() }
        }

        CommandGroup(replacing: .newItem) { FileNewItems(model: model) }
        CommandGroup(replacing: .importExport) {
            Button("Import PDF…") {
                model.showMainWindow?()
                NoteFiles.chooseAndImportPDF(in: model)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Import…") {
                model.showMainWindow?()
                NoteFiles.chooseAndImport(in: model)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            FileNoteItems(model: model, windowNote: windowNote, printing: false)
        }
        CommandGroup(replacing: .printItem) { FileNoteItems(model: model, windowNote: windowNote, printing: true) }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                if let id = windowNote ?? model.path.last { NoteSession.live.object(forKey: id as NSString)?.saveNow() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(windowNote == nil && model.path.isEmpty)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find in Note") {
                // The note of the window in front, or the one open in the main window.
                if let id = windowNote ?? model.path.last { NoteSession.live.object(forKey: id as NSString)?.finding = true }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(windowNote == nil && model.path.isEmpty)
            Button("Write with AI…") {
                // At the caret of the note in front.
                if let id = windowNote ?? model.path.last, let session = NoteSession.live.object(forKey: id as NSString) { session.text.focus(); session.writerOpen = true }
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled((windowNote == nil && model.path.isEmpty) || !model.writesWithAI)
            Button("Search All Notes") {
                model.showMainWindow?()
                model.showList()
                model.searchRequests += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
        }

        CommandGroup(before: .sidebar) {
            ViewOptions(model: model, shortcuts: true)
            Divider()
        }

        CommandMenu("Note") {
            NoteMenuItems(model: model, windowNote: windowNote)
        }

        CommandMenu("Go") {
            GoItems(model: model)
        }
    }
}

private struct FileNewItems: View {
    let model: AppModel

    var body: some View {
        Button("New Text Note") { model.createNote() }
            .keyboardShortcut("n", modifiers: .command)
        Button("New Handwritten Note") { model.createNote(handwritten: true) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        Button("New Folder") {
            var parent = TreeNode.rootID
            if case .folder(let id) = model.section, !id.contains(":") { parent = id; model.collapsedFolders.remove(id) }
            model.newFolder(in: parent)
        }
        .keyboardShortcut("n", modifiers: [.command, .option])
    }
}

/// Export, Share, Empty Trash and Sync; or, in its own group, Print.
private struct FileNoteItems: View {
    let model: AppModel
    let windowNote: String?
    let printing: Bool

    private var targets: [String] { windowNote.map { [$0] } ?? model.targetIDs }

    var body: some View {
        let targets = targets
        if printing {
            Button("Print…") { NoteExport.print(targets, in: model) }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(targets.isEmpty)
        } else {
            Button("Export as PDF…") { NoteExport.export(targets, in: model) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(targets.isEmpty)
            Button("Share…") { NoteExport.share(targets, in: model) }
                .disabled(targets.isEmpty)
            Divider()
            Button("Empty Trash…") { model.confirmEmptyTrash() }
                .disabled(model.count(.trash) == 0)
            Divider()
            Button("Sync Now") { model.syncNow() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.signedIn || model.isSyncing || model.isDemo || model.signingOut)
        }
    }
}

private struct NoteMenuItems: View {
    let model: AppModel
    let windowNote: String?

    var body: some View {
        NoteActions(model: model, ids: Set(windowNote.map { [$0] } ?? model.targetIDs), ownWindow: windowNote != nil)
    }
}

private struct GoItems: View {
    let model: AppModel

    var body: some View {
        Button("Back to Notes") { model.showList() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(model.path.isEmpty)
        Divider()
        Button("All Notes") { go(.all) }.keyboardShortcut("1", modifiers: [.command, .option])
        Button("Favorites") { go(.favorites) }.keyboardShortcut("2", modifiers: [.command, .option])
        Button("Trash") { go(.trash) }.keyboardShortcut("3", modifiers: [.command, .option])
        let folders = model.folders(in: TreeNode.rootID)
        if !folders.isEmpty {
            Divider()
            FolderChoices(model: model, parent: TreeNode.rootID, depth: 0) { go(.folder($0)) }
        }
    }

    private func go(_ section: SidebarSection) {
        model.showMainWindow?()
        model.showList()
        model.section = section
    }
}
