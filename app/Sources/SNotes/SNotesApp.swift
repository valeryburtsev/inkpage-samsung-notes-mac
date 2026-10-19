import AppKit
import Quartz
import SamsungNotesKit
import SwiftUI

@main
struct SNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // Options are written --name=value: a bare path among the arguments is taken by AppKit
        // for a document to open, and the app then starts without its window.
        let root = Launch.value("--store").map { URL(fileURLWithPath: $0) }
        let model = AppModel(storeRoot: root, demo: Launch.flag("--demo"))
        _model = State(initialValue: model)
        // Started from the command line rather than as a bundle, the app still wants a Dock icon and a menu bar.
        NSApplication.shared.setActivationPolicy(.regular)
        NotePDF.removeScratch()
        if let folder = Launch.value("--window-snapshot") {
            WindowSnapshots.run(model: model, to: URL(fileURLWithPath: folder))
        }
        if let folder = Launch.value("--editor-check") { EditorChecks.run(model: model, to: URL(fileURLWithPath: folder)) }
    }

    var body: some Scene {
        // One library, one main window; notes can have windows of their own beside it.
        Window("Notes", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(model.appearance.scheme)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands { AppCommands(model: model) }

        WindowGroup("Note", id: "note", for: String.self) { $noteID in
            NoteWindow(noteID: noteID)
                .environment(model)
                .preferredColorScheme(model.appearance.scheme)
                .frame(minWidth: 560, minHeight: 420)
        }
        .defaultSize(width: 900, height: 780)

        Window("Privacy Policy", id: "privacy-policy") {
            PrivacyPolicyView()
                .preferredColorScheme(model.appearance.scheme)
        }
        .defaultSize(width: 720, height: 760)
        .windowResizability(.contentMinSize)

        Window("Terms of Use", id: "terms-of-use") {
            PrivacyPolicyView(title: "\(LocalStore.appName) Terms of Use", effective: TermsOfUse.effective, sections: TermsOfUse.sections)
                .preferredColorScheme(model.appearance.scheme)
        }
        .defaultSize(width: 720, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.appearance.scheme)
        }
    }
}

/// The parts of the app's life that SwiftUI leaves to AppKit: quitting, and Quick Look's panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// What was typed a moment ago is written before the process ends.
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.current?.flushAll()
        NotePDF.removeScratch()
    }

    /// With every window closed, a click on the Dock icon brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppModel.current?.showMainWindow?() }
        return true
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.end(panel) }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    /// The folders at the side make way for a note that is opened, and come back with the list
    /// of notes if they were there before.
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var columnsBeforeNote: NavigationSplitViewVisibility?
    /// Whether the folders were put away beside the list of notes.
    @AppStorage("foldersHiddenInList") private var foldersHidden = false
    private var listColumns: NavigationSplitViewVisibility { foldersHidden && Launch.value("--window-snapshot") == nil && Launch.value("--editor-check") == nil ? .detailOnly : .all }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            NavigationStack(path: $model.path) {
                NotesGridView(section: model.section ?? .all)
                    .navigationDestination(for: String.self) { NoteView(noteID: $0) }
            }
        }
        .sheet(isPresented: $model.showSignIn) { SignInView() }
        .sheet(isPresented: $model.showConflicts) { ConflictSheet() }
        .modifier(WindowUndo())
        .onChange(of: model.path.isEmpty, initial: true) {
            if !model.path.isEmpty {
                if columnsBeforeNote == nil { columnsBeforeNote = listColumns }
                withAnimation(.easeOut(duration: 0.2)) { columns = .detailOnly }
            } else {
                // With the list of notes the folders are there, unless they were put away by
                // hand: never left hidden just because the app was last quit inside a note.
                columnsBeforeNote = nil
                withAnimation(.easeOut(duration: 0.2)) { columns = listColumns }
            }
        }
        .onChange(of: columns) {
            // Showing or hiding the folders beside the list is remembered; beside a note it is for that note only.
            guard model.path.isEmpty, columnsBeforeNote == nil, columns != .automatic else { return }
            foldersHidden = columns == .detailOnly
        }
        .onAppear {
            model.showSettingsWindow = { openSettings() }
            model.showNoteWindow = { openWindow(id: "note", value: $0) }
            model.showMainWindow = { openWindow(id: "main") }
            model.showPrivacyPolicy = { openWindow(id: "privacy-policy") }
            model.showTermsOfUse = { openWindow(id: "terms-of-use") }
        }
    }
}

/// A note in a window of its own.
struct NoteWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let noteID: String?

    var body: some View {
        let present = noteID.map { model.library.notes[$0] != nil } ?? false
        NavigationStack {
            if let noteID, present {
                NoteView(noteID: noteID)
            } else {
                ContentUnavailableView("This note is no longer here", systemImage: "note.text", description: Text("It was deleted, or the account was signed out."))
            }
        }
        .focusedSceneValue(\.windowNote, present ? noteID : nil)
        .modifier(WindowUndo())
        // A note's window can be the first one on screen when the system brings windows back.
        .onAppear { model.start() }
        // A window for a note that is gone closes itself, also one the system brought back at launch.
        .onChange(of: present, initial: true) { if !present { dismiss() } }
    }
}

/// Hands the model the undo manager of the window in front, so that what is done there is undone there.
struct WindowUndo: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.appearsActive) private var active

    func body(content: Content) -> some View {
        content
            .onAppear { if active || model.undoManager == nil { model.undoManager = undoManager } }
            .onChange(of: active) { if active { model.undoManager = undoManager } }
            .onChange(of: undoManager) { if active || model.undoManager == nil { model.undoManager = undoManager } }
    }
}

struct WindowNoteKey: FocusedValueKey { typealias Value = String }

extension FocusedValues {
    /// The note shown by the window in front, when that window shows one note only.
    var windowNote: String? {
        get { self[WindowNoteKey.self] }
        set { self[WindowNoteKey.self] = newValue }
    }
}

enum Launch {
    static func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }
    static func value(_ name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }
}
