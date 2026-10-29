import AppKit
import SamsungNotesKit
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// The tab to show first; the snapshots choose it.
    @State var tab = SettingsTab.account

    var body: some View {
        TabView(selection: $tab) {
            Tab("Account & Sync", systemImage: "person.crop.circle", value: SettingsTab.account) { AccountSettings() }
            Tab("General", systemImage: "doc.badge.gearshape", value: SettingsTab.general) { GeneralSettings() }
            Tab("Appearance", systemImage: "circle.lefthalf.filled", value: SettingsTab.appearance) { AppearanceSettings() }
            Tab("Advanced", systemImage: "gearshape.2", value: SettingsTab.advanced) { AdvancedSettings() }
        }
        .scenePadding(.bottom)
        .frame(width: 560, height: tab == .account ? 720 : tab == .general ? 900 : tab == .appearance ? 340 : 470)
        .onChange(of: model.settingsTab, initial: true) { if let wanted = model.settingsTab { tab = wanted; model.settingsTab = nil } }
    }
}

enum SettingsTab: Hashable { case account, general, appearance, advanced }

/// Syncing through iCloud or Google Drive: the account, how it stands, notes waiting to be decided, and encryption.
private struct FolderSyncSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showPassword = false

    var body: some View {
        let kind = model.provider
        let place = kind.place
        let byKeychain = model.keyTravelsByKeychain
        Section {
            if kind == .google {
                LabeledContent {
                    if model.googleSignedIn {
                        Button("Sign Out…", role: .destructive) { model.signOutOfGoogle() }
                            .disabled(model.isSyncing || model.googleSigningIn)
                            .help("Stop syncing with this Google account")
                    } else {
                        Button("Sign In with Google…") { model.signInToGoogle() }.buttonStyle(.glassProminent).disabled(model.googleSigningIn)
                        Button("Privacy Policy") { model.showPrivacyPolicy?() }.buttonStyle(.link)
                    }
                } label: {
                    Text(model.googleEmail ?? String(localized: "Google account"))
                    Text(model.googleSignedIn ? "Signed in on this Mac. The app can reach only its own folder in this account's Drive."
                         : "Google asks for your permission again before the notes can go on syncing.")
                }
            }
            LabeledContent {
                if model.isSyncing {
                    ProgressView().controlSize(.small).accessibilityLabel("Syncing")
                } else {
                    Button("Sync Now") { model.syncNow() }.disabled(kind == .google && !model.googleSignedIn)
                }
            } label: {
                Text(model.isSyncing ? model.syncMessage : (model.library.lastSync.map { String(localized: "Last synced: \(Format.stamp($0))") } ?? String(localized: "Not synced yet")))
                Text(kind == .google ? "Notes are kept in this app's hidden folder of your Google Drive, in this app's own format. Open this app on another Mac, choose Google Drive there too, and sign in to the same Google account."
                     : CloudAccess.usesCloudKit ? "Notes are kept in your private iCloud database, which only your Apple Account can read. Open this app on another Mac and choose iCloud there too."
                     : "Notes are kept in the folder “\(model.icloudFolder?.lastPathComponent ?? LocalStore.appName)” in your iCloud Drive, in this app's own format. Open this app on another Mac and choose iCloud Drive there too.")
            }
            if !model.syncConflicts.isEmpty {
                LabeledContent {
                    Button("Resolve…") { model.showMainWindow?(); model.showConflicts = true }
                } label: {
                    Label(model.syncConflicts.count == 1 ? "1 note changed in two places" : "\(model.syncConflicts.count) notes changed in two places", systemImage: "arrow.triangle.branch")
                }
            }
            if let problem = model.syncError {
                Label(problem.message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout).textSelection(.enabled)
            }
        } header: {
            Text(place)
        }

        Section {
            if model.vaultNeedsPassword, model.vaultInFolder?.hasPassword == false {
                LabeledContent("Locked notes are encrypted") {
                    ProgressView().controlSize(.small)
                }
                Text("They were encrypted on another Mac, and the key travels in iCloud Keychain. It has not reached this Mac yet: make sure Passwords & Keychain is on for iCloud in System Settings, and give it a moment.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if model.vaultNeedsPassword {
                LabeledContent {
                    Button("Enter Password…") { showPassword = true }
                } label: {
                    Text("Locked notes are encrypted")
                    Text(model.sealedWaiting > 0 ? "\(Format.notes(model.sealedWaiting)) in \(place) cannot be read on this Mac until you type the encryption password that was chosen on another Mac."
                         : "Type the encryption password that was chosen on another Mac to read and write them here.")
                }
            } else {
                Toggle(isOn: Binding(get: { model.encryptsLocked }, set: { on in
                    if model.vaultInFolder != nil { model.setEncrypting(on) } else if on {
                        // The key goes to the other Macs by iCloud Keychain where this build may use it; else a password is asked for.
                        if byKeychain { _ = model.startEncrypting(password: nil) } else { showPassword = true }
                    }
                })) {
                    Text("Encrypt locked notes")
                    Text(model.encryptsLocked ? (byKeychain ? "Locked notes, their pictures and their titles are encrypted on this Mac before they go to iCloud. The key is in your iCloud Keychain, so your other Macs have it too."
                                                 : "Locked notes, their pictures and their titles are encrypted on this Mac before they go to \(place). The key is in this Mac's keychain.")
                         : (byKeychain ? "Locked notes are encrypted on this Mac before they go to iCloud, so they cannot be read there. The key is kept in your iCloud Keychain: nothing to remember, and your other Macs get it by themselves."
                            : "Locked notes are encrypted on this Mac before they go to \(place), so they cannot be read there. You choose a password, which is typed once on each other Mac."))
                }
                .disabled(kind == .google && !model.googleSignedIn)
            }
        } footer: {
            Text("This is real encryption, unlike the lock itself. The notes on this Mac are not encrypted: they are protected by your Mac's login, and a locked note asks for Touch ID.")
        }
        .sheet(isPresented: $showPassword) { VaultPasswordSheet() }
        .onAppear { model.refreshVault() }
    }
}

/// What new notes start with, and how notes are saved: the Windows client's "General" settings.
private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showPassword = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Page style", selection: $model.defaultEndless) {
                    Text("Split pages").tag(false)
                    Text("Infinite scroll").tag(true)
                }
                Picker("Layout", selection: $model.defaultLong) {
                    Text("Normal").tag(false)
                    Text("Long (1:2)").tag(true)
                }
                .disabled(model.defaultEndless)
                Picker("Scroll direction", selection: $model.defaultScroll) {
                    ForEach(ScrollDirection.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                LabeledContent("Colour") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 9), spacing: 6) {
                        ForEach(PaperColors.all, id: \.argb) { paper in
                            let chosen = model.defaultPaper == paper.argb
                            Button { model.defaultPaper = paper.argb } label: {
                                RoundedRectangle(cornerRadius: 4).fill(PenChoice.color(paper.argb))
                                    .frame(width: 30, height: 38)
                                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(chosen ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: chosen ? 2 : 1) }
                                    .overlay { if chosen { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(NoteRenderer.luminance(paper.argb) < 0.42 ? .white : .black) } }
                            }
                            .buttonStyle(.plain)
                            .help(paper.name)
                            .accessibilityLabel(paper.name)
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                }
                LabeledContent("Template") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 8), count: 5), spacing: 8) {
                        ForEach(PageTemplate.allCases) { template in
                            let chosen = model.defaultTemplate == template
                            Button { model.defaultTemplate = template } label: {
                                Canvas { context, size in
                                    let zoom: CGFloat = template.pitch > 0 ? 2 : 1
                                    context.withCGContext { template.draw(in: $0, page: CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom), dark: false) }
                                }
                                .background(Color.white)
                                .frame(width: 58, height: 82)
                                .overlay { Rectangle().strokeBorder(chosen ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: chosen ? 2.5 : 1) }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(template.title)
                            .accessibilityLabel(template.title)
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                }
            } header: {
                Text("Default note style")
            } footer: {
                Text("What a new note starts with. Any note's own style is changed with the palette button above the note.")
            }

            Section {
                LabeledContent {
                    Button(model.lockPasscode == nil ? "Create Password…" : "Change Password…") { showPassword = true }
                        .disabled(!model.signedIn || model.isDemo || (model.lockPasscode == nil && !model.lockDerivationConfirmed))
                } label: {
                    Text("Password for locked notes")
                    Text(lockStatus)
                }
            } header: {
                Text("Locked notes")
            } footer: {
                Text("On this Mac a locked note opens with Touch ID or your Mac's password. This password is the one Samsung Notes asks for on your other devices. The lock keeps a note closed; it does not encrypt it.")
            }

            Section {
                Toggle(isOn: $model.mathResults) {
                    Text("Answer calculations as you type")
                    Text("Type a calculation and = and the answer is written after it: 10+5= gives 15. One in words (15% of 240=) is first read by Apple Intelligence; the arithmetic is always done exactly.")
                }
                Toggle(isOn: $model.aiWriting) {
                    Text("Write with AI")
                    Text(NoteIntelligence.unavailable ?? "On an empty line a button at the caret writes what you describe. The text is written on this Mac by Apple Intelligence; nothing is sent anywhere. Proofreading and rewriting are in Edit › Writing Tools.")
                }
                .disabled(NoteIntelligence.unavailable != nil)
            } header: {
                Text("Apple Intelligence")
            }

            Section {
                Toggle(isOn: $model.autoSave) {
                    Text("Auto save notes")
                    Text(model.autoSave ? "What you type is stored a moment after you type it." : "What you type is stored when you press ⌘S or leave the note. Drawings and pictures are always stored at once.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPassword) { LockPasswordSheet() }
    }

    private var lockStatus: String {
        if !model.signedIn { return String(localized: "The password belongs to your Samsung account: sign in to use locked notes.") }
        if let code = model.lockPasscode {
            return String(localized: "Set \(Format.stamp(Date(timeIntervalSince1970: Double(code.time) / 1000))). One password for every device of your account.")
        }
        return model.lockDerivationConfirmed ? String(localized: "No password is set for your account yet.")
            : String(localized: "No password is set yet. Create it once in Samsung Notes on a Galaxy device or Windows; after it has been typed here once, it can be changed here too.")
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let waiting = model.library.pendingCount
        Form {
            Section {
                Picker(selection: Binding(get: { model.provider }, set: { model.chooseProvider($0) })) {
                    ForEach(model.offeredProviders) { kind in Text(kind.title).tag(kind) }
                } label: {
                    Text("Sync with")
                    Text(model.provider.detail)
                }
                .disabled(model.isSyncing || model.signingOut || model.isDemo || model.googleSigningIn)
            }

            if model.provider.syncsByFolder { FolderSyncSettings() }

            if !model.provider.syncsByFolder || model.signedIn {
            Section("Samsung account") {
                if model.signedIn {
                    LabeledContent {
                        Button("Sign Out…", role: .destructive) { model.confirmSignOut() }
                            .disabled(model.isSyncing || model.signingOut || model.isDemo)
                            .help(model.isSyncing ? "Wait for the sync to finish before signing out." : "Remove your notes and account from this Mac")
                    } label: {
                        Text(model.email ?? String(localized: "Signed in"))
                        Text(model.isSyncing ? String(localized: "You can sign out when the sync has finished.")
                             : waiting > 0 ? String(localized: "\(Format.changes(waiting)) not sent to Samsung Cloud yet.") : String(localized: "Signed in on this Mac."))
                    }
                } else {
                    LabeledContent {
                        Button("Sign In…") { model.beginSignIn() }
                            .buttonStyle(.glassProminent)
                    } label: {
                        Text("Notes are kept on this Mac")
                        Text("Sign in with your Samsung account to sync them with Samsung Cloud and your other devices. You can use the app without an account.")
                    }
                    // What signing in sends where, before it is done, and what it risks.
                    HStack(spacing: 14) {
                        Button("Privacy Policy") { model.showPrivacyPolicy?() }.buttonStyle(.link)
                        Button("Terms of Use") { model.showTermsOfUse?() }.buttonStyle(.link)
                        Button("Risks of Samsung Cloud Sync…") { SamsungRisks.show() }.buttonStyle(.link)
                    }
                }
            }

            }

            if !model.provider.syncsByFolder {
            Section("Samsung Cloud") {
                LabeledContent {
                    if model.isSyncing {
                        ProgressView().controlSize(.small).accessibilityLabel("Syncing")
                    } else {
                        Button("Sync Now") { model.syncNow() }.disabled(!model.signedIn || model.isDemo || model.signingOut)
                    }
                } label: {
                    Text(model.isSyncing ? model.syncMessage : !model.signedIn ? String(localized: "Not syncing") : (model.library.lastSync.map { String(localized: "Last synced: \(Format.stamp($0))") } ?? String(localized: "Not synced yet")))
                    if waiting > 0, !model.isSyncing { Text("\(Format.changes(waiting)) waiting to upload.") }
                }
                if let problem = model.syncError {
                    Label(problem.message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout).textSelection(.enabled)
                }
            }
            }

            Section("Storage") {
                LabeledContent("Notes on this Mac", value: "\(model.library.notes.count)")
                LabeledContent {
                    Text(Format.bytes(model.library.notes.values.reduce(0) { $0 + $1.bytes }))
                } label: {
                    Text("Used on this Mac")
                    Text("Notes are kept in Application Support. Signing out removes from this Mac the notes that are in Samsung Cloud; notes that were never sent stay.")
                }
                if let bytes = model.library.cloudBytes { LabeledContent("Used in Samsung Cloud", value: Format.bytes(bytes)) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Dark mode also darkens the pages of your notes, as Samsung Notes does.")
            }
            Section("Notes") {
                Picker("Show notes", selection: $model.gridStyle) {
                    Text("As a grid").tag(GridStyle.grid)
                    Text("As a list").tag(GridStyle.list)
                }
                Picker("Sort by", selection: $model.sort) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                Picker("Order", selection: $model.ascending) {
                    Text(model.sort == .title ? String(localized: "A to Z") : String(localized: "Oldest first")).tag(true)
                    Text(model.sort == .title ? String(localized: "Z to A") : String(localized: "Newest first")).tag(false)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Troubleshooting") {
                LabeledContent {
                    Button("Show in Finder") { if let url = model.logURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                } label: {
                    Text("Sync log")
                    Text("Which requests were made and how Samsung's servers answered. It holds no passwords, tokens or note content.")
                }
                if let problem = model.syncError {
                    LabeledContent {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(problem.detail, forType: .string)
                        }
                    } label: {
                        Text("Last sync error")
                        Text(problem.detail.isEmpty ? problem.message : String(problem.detail.prefix(600))).textSelection(.enabled)
                    }
                }
                if let failed = model.library.failedDownloads, !failed.isEmpty {
                    LabeledContent("Notes that could not be downloaded", value: "\(failed.count)")
                }
            }

            Section("Privacy") {
                Text("Your notes are kept on this Mac, in Application Support. Nothing is sent anywhere unless you turn on sync; then the app talks only to the service you chose: Samsung's own servers (account sign-in and Samsung Cloud), with your Samsung account, exactly as Samsung's apps do; your iCloud; or Google (its sign-in, and your Drive, where the app can reach only a folder of its own). It has no analytics, no advertising and no server of its own. Handwriting is read on this Mac for search and never leaves it.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Privacy Policy…") { model.showPrivacyPolicy?() }
                Link("Samsung's privacy notice", destination: URL(string: "https://account.samsung.com/membership/terms/privacypolicy")!)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
                Text("An independent notes app. Notes are kept on this Mac, and can be synced through iCloud Drive, Google Drive or, experimentally, Samsung Cloud. It is not made, endorsed or approved by Samsung, Apple or Google.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Samsung, Samsung Notes, Samsung Cloud and Galaxy are trademarks of Samsung Electronics Co., Ltd. Apple, Mac, iCloud and Apple Intelligence are trademarks of Apple Inc. Google and Google Drive are trademarks of Google LLC.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button("Privacy Policy") { model.showPrivacyPolicy?() }.buttonStyle(.link)
                    Button("Terms of Use") { model.showTermsOfUse?() }.buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }
}
