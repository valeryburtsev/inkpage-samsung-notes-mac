import AppKit
import SamsungNotesKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("foldersExpanded") private var foldersExpanded = true

    var body: some View {
        let top = model.folders(in: TreeNode.rootID)
        List(selection: Binding(get: { model.section }, set: { new in
            guard let new else { return }
            model.path = []
            model.section = new
        })) {
            Section {
                Label(model.sectionTitle(.all), systemImage: "note.text").badge(model.count(.all)).tag(SidebarSection.all)
                    .dropDestination(for: String.self) { strings, _ in model.drop(strings, on: .all) }
                Label(model.sectionTitle(.favorites), systemImage: "star").badge(model.count(.favorites)).tag(SidebarSection.favorites)
                    .dropDestination(for: String.self) { strings, _ in model.drop(strings, on: .favorites) }
                Label(model.sectionTitle(.trash), systemImage: "trash").badge(model.count(.trash)).tag(SidebarSection.trash)
                    .dropDestination(for: String.self) { strings, _ in model.drop(strings, on: .trash) }
                    .contextMenu {
                        Button("Empty Trash…", systemImage: "trash.slash") { model.confirmEmptyTrash() }.disabled(model.count(.trash) == 0)
                    }
            }
            Section(isExpanded: $foldersExpanded) {
                ForEach(top) { folder in
                    FolderRow(folder: folder)
                }
                if top.isEmpty {
                    Text("No folders").font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { foldersExpanded = true; model.newFolder() } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18).contentShape(.rect)
                    }
                        .buttonStyle(.borderless)
                        .help("New folder")
                        .accessibilityLabel("New folder")
                        // The heading reaches further right than the rows: in line with their counts.
                        .padding(.trailing, 11)
                }
                // A folder dropped on the heading goes back to the top level.
                .dropDestination(for: String.self) { strings, _ in
                    let folders = DragPayload.parse(strings).folders
                    for folder in folders { model.moveFolder(folder, to: TreeNode.rootID) }
                    return !folders.isEmpty
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New Folder", systemImage: "folder.badge.plus") { foldersExpanded = true; model.newFolder() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
        .navigationTitle("Notes")
    }
}

/// The colours a folder can have, as Samsung Notes stores them.
struct FolderColor: Identifiable, Hashable {
    let argb: Int32
    let name: String
    var id: Int32 { argb }

    static let none = FolderColor(argb: -1, name: String(localized: "No Color"))
    static let palette: [FolderColor] = [
        .none,
        FolderColor(argb: -48845, name: String(localized: "Red")),
        FolderColor(argb: Int32(bitPattern: 0xFFFF_8A1F), name: String(localized: "Orange")),
        FolderColor(argb: Int32(bitPattern: 0xFFF5_BC00), name: String(localized: "Yellow")),
        FolderColor(argb: Int32(bitPattern: 0xFF34_B86B), name: String(localized: "Green")),
        FolderColor(argb: Int32(bitPattern: 0xFF3E_8EF7), name: String(localized: "Blue")),
        FolderColor(argb: Int32(bitPattern: 0xFF9B_6BF2), name: String(localized: "Purple")),
    ]

    /// A round swatch for a menu, which would draw a symbol in the text colour.
    var swatch: NSImage {
        let color = Format.color(argb).map { NSColor($0) }
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if let color {
                color.setFill()
                circle.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                circle.lineWidth = 1.2
                circle.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A folder and, under a disclosure triangle, the folders it holds.
private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: TreeNode

    /// Samsung's own folders (their ids are addresses) stay as they are.
    private var builtIn: Bool { folder.id.contains(":") }

    var body: some View {
        let children = model.folders(in: folder.id)
        if children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: Binding(get: { !model.collapsedFolders.contains(folder.id) }, set: { open in
                if open { model.collapsedFolders.remove(folder.id) } else { model.collapsedFolders.insert(folder.id) }
            })) {
                ForEach(children) { FolderRow(folder: $0) }
            } label: {
                label
            }
        }
    }

    private var label: some View {
        let tint = Format.color(folder.color)
        let name = folder.name.isEmpty ? String(localized: "Folder") : folder.name
        return Label {
            if model.renamingFolder == folder.id {
                RenameField(initial: folder.name, placeholder: String(localized: "Folder name")) { new in
                    if let new { model.renameFolder(folder.id, to: new) }
                    model.renamingFolder = nil
                }
            } else {
                Text(name)
            }
        } icon: {
            Image(systemName: tint == nil ? "folder" : "folder.fill").foregroundStyle(tint ?? Color.secondary)
        }
        .badge(model.count(.folder(folder.id)))
        .tag(SidebarSection.folder(folder.id))
        .draggable(DragPayload.folder(folder.id))
        .dropDestination(for: String.self) { strings, _ in
            if !model.collapsedFolders.isEmpty, !DragPayload.parse(strings).folders.isEmpty { model.collapsedFolders.remove(folder.id) }
            return model.drop(strings, on: .folder(folder.id))
        }
        .contextMenu { menu }
        .accessibilityLabel(name)
    }

    @ViewBuilder private var menu: some View {
        Button("New Folder", systemImage: "folder.badge.plus") {
            model.collapsedFolders.remove(folder.id)
            model.newFolder(in: folder.id)
        }
        Button("Rename", systemImage: "pencil") { model.renamingFolder = folder.id }.disabled(builtIn)
        Picker(selection: Binding(get: { Format.color(folder.color) == nil ? FolderColor.none.argb : folder.color }, set: { model.setFolderColor(folder.id, $0) })) {
            ForEach(FolderColor.palette) { color in
                Label { Text(color.name) } icon: { Image(nsImage: color.swatch) }.tag(color.argb)
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        .pickerStyle(.menu)
        .disabled(builtIn)
        if folder.parentID != TreeNode.rootID {
            Button("Move to Top Level", systemImage: "arrow.up.to.line") { model.moveFolder(folder.id, to: TreeNode.rootID) }.disabled(builtIn)
        }
        Divider()
        Button("Delete Folder…", systemImage: "trash", role: .destructive) { model.confirmDeleteFolder(folder.id) }.disabled(builtIn)
    }
}

/// The bottom of the sidebar: how sync stands, and the way to Settings.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.horizontal, 12)
            SyncStatusView()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            Button { openSettings() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").font(.system(size: 15))
                    Text("Settings")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open Settings (⌘,)")
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}

/// How sync stands, always in sight: under way, failed (with a way to try again), waiting, or done.
struct SyncStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.library.pendingCount
        HStack(alignment: .top, spacing: 8) {
            if model.provider.syncsByFolder {
                let google = model.provider == .google
                if model.isSyncing {
                    ProgressView().controlSize(.small)
                    text(model.syncMessage, nil)
                } else if let problem = model.syncError {
                    icon("exclamationmark.triangle.fill", color: .yellow)
                    text(String(localized: "Sync did not finish"), problem.message, lines: 5).help(problem.detail)
                    Spacer(minLength: 4)
                    if problem.needsSignIn {
                        Button("Sign In…") { model.signInToGoogle() }.controlSize(.small)
                    } else {
                        Button("Retry") { model.syncNow() }.controlSize(.small)
                    }
                } else if !model.syncConflicts.isEmpty {
                    icon("arrow.triangle.branch", color: .orange)
                    text(model.syncConflicts.count == 1 ? String(localized: "1 note changed in two places") : String(localized: "\(model.syncConflicts.count) notes changed in two places"), String(localized: "Choose which to keep."))
                    Spacer(minLength: 4)
                    Button("Resolve…") { model.showConflicts = true }.controlSize(.small)
                } else if model.vaultNeedsPassword, model.sealedWaiting > 0 {
                    icon(google ? "lock" : "lock.icloud")
                    text(String(localized: "\(Format.notes(model.sealedWaiting)) encrypted"), String(localized: "Type the encryption password to read them."))
                    Spacer(minLength: 4)
                    Button("Enter…") { model.showSyncSettings() }.controlSize(.small)
                } else {
                    icon(google ? "checkmark.circle" : "checkmark.icloud")
                    text(model.provider.place, synced)
                }
            } else if !model.signedIn, !model.signingOut {
                icon("internaldrive")
                text(String(localized: "On this Mac"), String(localized: "Notes are kept here and are not synced."))
                Spacer(minLength: 4)
                Button("Sync…") { model.showSyncSettings() }.controlSize(.small).help("Turn on sync with Samsung Cloud in Settings")
            } else if model.signingOut {
                ProgressView().controlSize(.small)
                text(String(localized: "Signing out…"), nil)
            } else if model.isSyncing {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.syncMessage).font(.caption).lineLimit(1)
                    if let fraction = model.syncFraction { ProgressView(value: fraction).controlSize(.small) }
                }
            } else if let problem = model.syncError {
                icon("exclamationmark.triangle.fill", color: .yellow)
                text(String(localized: "Sync did not finish"), problem.message + (waiting > 0 ? " " + waitingText(waiting) : ""), lines: 5)
                    .help(problem.detail)
                Spacer(minLength: 4)
                Button("Retry") { model.syncNow() }.controlSize(.small)
            } else if model.isDemo {
                icon("externaldrive")
                text(String(localized: "Demo library"), String(localized: "Nothing is sent to Samsung Cloud."))
            } else if !model.syncEnabled {
                icon("icloud.slash")
                text(String(localized: "Sync is off"), waiting > 0 ? waitingText(waiting) : synced)
            } else if waiting > 0 {
                icon("arrow.up.circle")
                text(waitingText(waiting), synced)
            } else {
                icon("checkmark.icloud")
                text(synced, nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sync status")
    }

    private var synced: String {
        guard let date = model.library.lastSync else { return String(localized: "Not synced yet") }
        return Calendar.current.isDateInToday(date) ? String(localized: "Synced today at \(date.formatted(date: .omitted, time: .shortened))")
            : String(localized: "Synced \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    private func waitingText(_ count: Int) -> String { String(localized: "\(Format.changes(count)) waiting to upload.") }

    private func icon(_ name: String, color: Color = .secondary) -> some View {
        Image(systemName: name).font(.system(size: 13)).foregroundStyle(color).frame(width: 16).accessibilityHidden(true)
    }

    private func text(_ title: String, _ detail: String?, lines: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.weight(.medium))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(lines).fixedSize(horizontal: false, vertical: true) }
        }
        .accessibilityElement(children: .combine)
    }
}
