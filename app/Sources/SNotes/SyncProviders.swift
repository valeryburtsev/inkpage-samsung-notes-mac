import AppKit
import SamsungNotesKit
import SwiftUI

/// What the notes on this Mac are kept in sync with: nothing, Samsung's own service, iCloud,
/// or the Drive of a Google account. The last two are shared by every Mac running this app.
enum SyncProviderKind: String, CaseIterable, Identifiable {
    case none, samsung, icloud, google

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return String(localized: "This Mac only")
        case .samsung: return String(localized: "Samsung Cloud (Experimental)")
        case .icloud, .google: return place
        }
    }
    var detail: String {
        switch self {
        case .none: return String(localized: "Notes stay on this Mac.")
        case .samsung: return String(localized: "With Samsung Notes on your Galaxy devices and Windows, through your Samsung account. Unofficial and not approved by Samsung: at your own risk.")
        case .icloud:
            return CloudAccess.usesCloudKit ? String(localized: "With this app on your other Macs, through your private iCloud database (CloudKit). Locked notes can be encrypted there.")
                : String(localized: "With this app on your other Macs, through a folder in your iCloud Drive. Locked notes can be encrypted there.")
        case .google: return String(localized: "With this app on your other Macs, through your Google account's Drive. Locked notes can be encrypted there.")
        }
    }
    /// What the service is called in a sentence.
    var place: String {
        switch self {
        case .none: return String(localized: "this Mac")
        case .samsung: return String(localized: "Samsung Cloud")
        case .icloud: return CloudAccess.usesCloudKit ? String(localized: "iCloud") : String(localized: "iCloud Drive")
        case .google: return String(localized: "Google Drive")
        }
    }
    /// Synced as a folder of this app's own files (`FolderSync`), not through Samsung's service.
    var syncsByFolder: Bool { self == .icloud || self == .google }
}

/// How this build of the app can reach iCloud. A build signed with the iCloud capability (the
/// Xcode project, with a team of the paid developer programme) uses CloudKit, and keeps the
/// key of encrypted notes in the keychain that iCloud syncs; any other build keeps its files
/// in iCloud Drive and locks the key with a password.
enum CloudAccess {
    /// A folder given on the command line stands in for iCloud in checks, whatever the build.
    static let usesCloudKit = CloudKitFiles.isEntitled && Launch.value("--sync-folder") == nil
    static let keyTravelsByKeychain = usesCloudKit && SyncedKeychainStore.isEntitled
    static var container: String { "iCloud." + (Bundle.main.bundleIdentifier ?? "com.krushock.inkpage") }
}

extension AppModel {
    var provider: SyncProviderKind { googleSync ? .google : icloudSync ? .icloud : (syncEnabled ? .samsung : .none) }
    var syncsByFolder: Bool { icloudSync || googleSync }

    /// The services Settings offer. Google Drive is among them only in a build registered with
    /// Google (see `GoogleRegistration`), or while it is the one in use.
    var offeredProviders: [SyncProviderKind] {
        SyncProviderKind.allCases.filter { $0 != .google || provider == .google || GoogleRegistration.client != nil }
    }

    /// The folder in iCloud Drive the notes are synced through; nil when this Mac has no iCloud Drive.
    var icloudFolder: URL? {
        if let given = Launch.value("--sync-folder") { return URL(fileURLWithPath: given) }
        // With CloudKit the folder is this Mac's own copy of what the database holds.
        if CloudAccess.usesCloudKit { return store.root.appendingPathComponent("cloud") }
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        // A folder made under the app's former name is used on, so other Macs that sync through it are not left behind.
        let former = drive.appendingPathComponent(LocalStore.formerName)
        let current = drive.appendingPathComponent(LocalStore.appName)
        return !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: former.path) ? former : current
    }

    /// The folder `FolderSync` works on for the service in use: the service's own folder, or
    /// this Mac's copy of what a cloud holds.
    var syncFolder: URL? {
        switch provider {
        case .icloud: return icloudFolder
        case .google: return store.root.appendingPathComponent("google")
        case .none, .samsung: return nil
        }
    }

    /// The cloud behind the copy, when the service is not a folder on this Mac.
    private var mirroredCloud: CloudFiles? {
        switch provider {
        case .google: return Launch.value("--google-stand-in").map { DirectoryCloud(folder: URL(fileURLWithPath: $0)) } ?? google.drive()
        case .icloud: return CloudAccess.usesCloudKit ? CloudKitFiles(containerID: CloudAccess.container) : nil
        case .none, .samsung: return nil
        }
    }

    /// Names the folder among those this Mac has synced with: what was agreed with one says nothing about another.
    private var folderHome: String { provider == .google ? "google:" + (googleEmail ?? "") : "icloud" }

    // MARK: Choosing

    /// Changes what the notes are synced with, after asking what is to become of the notes
    /// that the service being left holds.
    func chooseProvider(_ wanted: SyncProviderKind) {
        let now = provider
        guard wanted != now, !isSyncing, !signingOut, !isDemo else { return }
        // Before anything changes: Samsung Cloud sync is unofficial, and turned on only once that is accepted.
        if wanted == .samsung, !SamsungRisks.isAccepted {
            SamsungRisks.confirm { [weak self] in self?.chooseProvider(.samsung) }
            return
        }
        if wanted == .icloud, icloudFolder == nil {
            lastError = String(localized: "iCloud Drive is not switched on for this Mac. Turn it on in System Settings › Apple Account › iCloud, then try again.")
            return
        }
        if wanted == .google, !googleSignedIn {
            // The account first, on Google's page; it comes back here once it is signed in.
            signInToGoogle()
            return
        }
        flushAll()
        let onward = wanted.syncsByFolder ? String(localized: "Keep them on this Mac to sync them with \(wanted.place) from now on, or take them off this Mac and start \(wanted.place) with the other notes.")
            : wanted == .samsung ? String(localized: "Keep them on this Mac to send them to Samsung Cloud, or take them off this Mac and sync only the other notes with Samsung Cloud.")
            : String(localized: "Keep them on this Mac, or take them off this Mac.")
        switch now {
        case .none:
            enter(wanted)
        case .samsung:
            let effect = library.signOutSummary
            let held = effect.goes + effect.copied
            guard held > 0 else { leaveSamsung(removing: false); enter(wanted); return }
            ask(title: String(localized: "Stop syncing with Samsung Cloud?"),
                message: String(localized: "\(Format.notes(held)) on this Mac are also in Samsung Cloud. They stay in Samsung Cloud either way, as they are now.") + "\n\n" + onward,
                keep: String(localized: "Keep Notes on This Mac"), remove: String(localized: "Remove Samsung Cloud's Notes from This Mac")) { [weak self] remove in
                guard let self else { return }
                self.leaveSamsung(removing: remove) { self.enter(wanted) }
            }
        case .icloud, .google:
            let held = FolderSync.removable(in: store)
            guard held > 0 else { leaveFolder(removing: false); enter(wanted); return }
            ask(title: String(localized: "Stop syncing with \(now.place)?"),
                message: String(localized: "\(Format.notes(held)) on this Mac are also in \(now.place). They stay in \(now.place) either way, as they are now.") + "\n\n" + onward,
                keep: String(localized: "Keep Notes on This Mac"), remove: String(localized: "Remove \(now.place)'s Notes from This Mac")) { [weak self] remove in
                guard let self else { return }
                self.leaveFolder(removing: remove)
                self.enter(wanted)
            }
        }
    }

    private func ask(title: String, message: String, keep: String, remove: String, then: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: keep)
        alert.addButton(withTitle: remove).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: then(false)
        case .alertSecondButtonReturn: then(true)
        default: break
        }
    }

    private func leaveSamsung(removing: Bool, then: (@MainActor () -> Void)? = nil) {
        if removing {
            // As signing out does: the cloud's notes leave this Mac, what was never sent stays.
            signOut(then: then)
        } else {
            syncEnabled = false
            then?()
        }
    }

    private func leaveFolder(removing: Bool) {
        icloudSync = false
        googleSync = false
        syncConflicts = []
        sealedWaiting = 0
        syncError = nil
        vaultInFolder = nil
        vaultOpen = false
        if removing {
            FolderSync.detach(from: store)
            thumbnails.removeAll()
            path = []
            selection = []
        }
        library = store.loadLibrary()
        reindex()
    }

    private func enter(_ wanted: SyncProviderKind) {
        switch wanted {
        case .none:
            break
        case .samsung:
            // Everything on this Mac is the account's to have: notes it never got are sent as new.
            edits.queueAllForAccount()
            library = store.loadLibrary()
            setSync(true)
        case .icloud, .google:
            icloudSync = wanted == .icloud
            googleSync = wanted == .google
            refreshVault()
            syncNow()
        }
    }

    // MARK: Syncing with the folder

    func syncFolderNow() {
        let provider = provider
        guard provider.syncsByFolder, !isSyncing, !isDemo, !signingOut else { return }
        guard let folder = syncFolder else {
            syncError = SyncProblem(message: String(localized: "iCloud Drive is not available on this Mac."))
            return
        }
        if provider == .google, !googleSignedIn {
            syncError = SyncProblem(message: String(localized: "Sign in to Google again to go on syncing."))
            syncError?.needsSignIn = true
            return
        }
        syncSoon?.cancel()
        syncSoon = nil
        isSyncing = true
        syncFraction = nil
        syncMessage = String(localized: "Syncing with \(provider.place)…")
        let store = store
        let resolve = folderResolutions
        folderResolutions = [:]
        let key = vaultStore.load()
        let cloud = mirroredCloud
        let home = folderHome
        Task.detached(priority: .utility) {
            // The key is used when it is the key the folder is locked with.
            @Sendable func prepare(_ sync: FolderSync) {
                let locked = sync.lockedVault()
                if let key, let vault = Vault(stored: key), locked == nil || locked?.keyID == vault.keyID {
                    sync.vault = vault
                    sync.seals = locked?.active ?? false
                }
            }
            FolderSync.settle(in: store, home: home)
            let result: Result<FolderSync.Outcome, Error>
            if let cloud {
                if let reason = await (cloud as? CloudKitFiles)?.unavailable() {
                    result = .failure(CloudProblem(reason: reason))
                } else {
                    do { result = .success(try await CloudMirror(store: store, cloud: cloud, folder: folder).sync(resolve: resolve, prepare: prepare)) } catch { result = .failure(error) }
                }
            } else {
                let sync = FolderSync(store: store, folder: folder)
                prepare(sync)
                result = Result { try sync.sync(resolve: resolve) }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let before = Set(self.library.notes.keys)
                self.library = store.loadLibrary()
                var again = false
                switch result {
                case .success(let outcome):
                    self.syncError = nil
                    self.syncConflicts = outcome.conflicts
                    self.sealedWaiting = outcome.sealedWithoutKey
                    // Notes the service has not brought whole yet are looked for again shortly.
                    again = outcome.notHereYet > 0
                    if !outcome.arrived.isEmpty || Set(self.library.notes.keys) != before {
                        self.thumbnails.removeAll()
                        self.reindex()
                        // A note that is open and was replaced shows what arrived; one that is gone closes.
                        for id in outcome.arrived {
                            NotificationCenter.default.post(name: NoteSession.written, object: nil, userInfo: ["note": id, "sender": "folder-sync"])
                        }
                        self.path.removeAll { self.library.notes[$0] == nil }
                    }
                case .failure(let error):
                    self.syncError = SyncProblem(message: (error as? CloudProblem)?.reason ?? AppModel.describe(error, with: provider), detail: "\(error)")
                    if error as? GoogleAccount.Failure == .signInAgain || error as? GoogleAccount.Failure == .notSignedIn {
                        self.syncError?.needsSignIn = true
                        self.googleSignedIn = false
                    }
                    HTTPClient.log?("folder sync failed: \(error)")
                }
                self.refreshVault()
                self.isSyncing = false
                if again { self.scheduleSync(after: 12) }
                InkIndexer.shared.schedule(self)
            }
        }
    }

    /// Why a round with iCloud or Google Drive did not finish, in a sentence.
    nonisolated static func describe(_ error: Error, with provider: SyncProviderKind) -> String {
        let place = provider.place
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return String(localized: "This Mac is offline. Changes will be sent when the connection is back.")
            case .timedOut: return String(localized: "\(place) took too long to answer. Sync will try again shortly.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return String(localized: "\(place) could not be reached.")
            default: return url.localizedDescription
            }
        }
        if let refused = error as? GoogleDriveFiles.Refused {
            switch refused.status {
            case 403 where refused.detail.contains("accessNotConfigured") || refused.detail.contains("SERVICE_DISABLED"):
                return String(localized: "The Google Drive API is not switched on for your Google Cloud project. Enable it in Google Cloud Console (APIs & Services › Library › Google Drive API), wait a minute, and sync again.")
            case 403 where refused.detail.contains("storageQuotaExceeded"): return String(localized: "Your Google Drive is full.")
            case 401, 403: return String(localized: "Google Drive no longer accepts this sign-in. Sign out of Google and sign in again.")
            case 429, 500...599: return String(localized: "Google Drive is busy right now. Sync will try again shortly.")
            default: return String(localized: "Google Drive did not accept a request (\(refused.what), error \(refused.status)).")
            }
        }
        switch error as? GoogleAccount.Failure {
        case .signInAgain?, .notSignedIn?: return String(localized: "Google asks you to sign in again: its permission ran out or was taken back.")
        case .noClient?: return String(localized: "This build of the app is not registered with Google.")
        case .cancelled?: return String(localized: "The sign-in was not finished.")
        case .refused(let why)?: return why
        case nil: break
        }
        return String(localized: "\(place) could not be synced with. \(AppModel.describe(error))")
    }

    /// Says which of a note's two versions to keep, and syncs.
    func resolve(_ conflict: FolderSync.Conflict, _ resolution: FolderSync.Resolution) {
        folderResolutions[conflict.id] = resolution
        syncConflicts.removeAll { $0.id == conflict.id }
        if syncConflicts.isEmpty { showConflicts = false }
        syncNow()
    }

    // MARK: Encrypting locked notes

    /// Reads how the folder's vault stands: whether locked notes are encrypted there, and
    /// whether this Mac holds the key.
    func refreshVault() {
        guard syncsByFolder, let folder = syncFolder else { vaultInFolder = nil; vaultOpen = false; return }
        let locked = FolderSync(store: store, folder: folder).lockedVault()
        vaultInFolder = locked
        vaultOpen = locked != nil && vaultStore.load().flatMap(Vault.init(stored:))?.keyID == locked?.keyID
    }

    /// Locked notes are being encrypted in the folder, and this Mac can read them.
    var encryptsLocked: Bool { vaultInFolder?.active == true && vaultOpen }
    /// The folder has encrypted notes that this Mac cannot read until the password is typed here.
    var vaultNeedsPassword: Bool { vaultInFolder != nil && !vaultOpen }
    /// The key reaches the other Macs by itself, in the keychain iCloud syncs.
    var keyTravelsByKeychain: Bool { provider == .icloud && CloudAccess.keyTravelsByKeychain }

    /// Switches encrypting on with a new password: makes the key, keeps it in this Mac's
    /// keychain, and puts a copy locked with the password beside the notes.
    /// Without a password (a build whose key travels in the keychain that iCloud syncs), the
    /// folder only names the key.
    func startEncrypting(password: String?) -> Bool {
        guard syncsByFolder, let folder = syncFolder, vaultInFolder == nil, password.map({ $0.count >= 8 }) ?? keyTravelsByKeychain else { return false }
        // This Mac's copy of a cloud says nothing of the cloud before it has been filled from it: another Mac's key may be there.
        if let cloud = mirroredCloud, !CloudMirror(store: store, cloud: cloud, folder: folder).hasSynced {
            lastError = String(localized: "Sync with \(provider.place) once first, so that a key another Mac may have set is not replaced.")
            return false
        }
        let vault = Vault()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FolderSync(store: store, folder: folder).writeLockedVault(try password.map { try vault.locked(with: $0) } ?? Vault.Locked(keyOnly: vault))
            vaultStore.save(vault.stored)
            guard vaultStore.load() == vault.stored else { throw CloudProblem(reason: String(localized: "The key could not be kept in the keychain.")) }
        } catch {
            lastError = String(localized: "Encrypting could not be switched on. \(AppModel.describe(error))")
            return false
        }
        refreshVault()
        syncNow()
        return true
    }

    /// Opens the folder's vault on this Mac with its password.
    func openVault(password: String) -> Bool {
        guard let locked = vaultInFolder, let vault = try? Vault(locked, password: password) else { return false }
        vaultStore.save(vault.stored)
        refreshVault()
        syncNow()
        return true
    }

    /// Switches encrypting on or off for a folder whose key this Mac holds. Off: locked notes
    /// are written in the clear again; the key is kept, for what other Macs have yet to rewrite.
    func setEncrypting(_ on: Bool) {
        guard vaultOpen, var locked = vaultInFolder, locked.active != on, let folder = syncFolder else { return }
        locked.active = on
        do { try FolderSync(store: store, folder: folder).writeLockedVault(locked) } catch { lastError = AppModel.describe(error); return }
        refreshVault()
        syncNow()
    }
}

/// Why a service cannot be synced with, in words for the user.
struct CloudProblem: Error {
    var reason: String
}

/// The notes that changed in two places, each with the choice of which to keep.
struct ConflictSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.syncConflicts.count == 1 ? "A note changed in two places" : "\(model.syncConflicts.count) notes changed in two places").font(.headline)
            Text("Each of these notes was changed on this Mac and on another Mac before the two had synced. Nothing has been lost: choose which version to keep, or keep both as two notes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.syncConflicts) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(conflict.title.isEmpty ? String(localized: "Untitled note") : conflict.title).font(.body.weight(.medium)).lineLimit(1)
                            Text("This Mac: changed \(conflict.modifiedHere.map(Format.stamp) ?? "–")\n\(conflict.deviceThere): changed \(Format.stamp(conflict.modifiedThere))")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("Keep This Mac's") { model.resolve(conflict, .keepMine) }
                                Button("Keep \(conflict.deviceThere)'s") { model.resolve(conflict, .keepTheirs) }
                                Button("Keep Both") { model.resolve(conflict, .keepBoth) }.buttonStyle(.borderedProminent)
                                Spacer()
                                Button("Open") { model.showMainWindow?(); model.open(conflict.id); dismiss() }.buttonStyle(.link).help("Look at this Mac's version first")
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onChange(of: model.syncConflicts.isEmpty) { if model.syncConflicts.isEmpty { dismiss() } }
    }
}

/// The sheet for the password that the key of encrypted notes is locked with: a new one, or
/// the one set on another Mac.
struct VaultPasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var again = ""
    @State private var problem: String?

    var body: some View {
        let opening = model.vaultInFolder != nil
        let place = model.provider.place
        VStack(alignment: .leading, spacing: 14) {
            Text(opening ? "Enter the encryption password" : "Create an encryption password").font(.headline)
            Text(opening ? "Locked notes in \(place) were encrypted on another Mac. Type the password that was chosen there; this Mac then keeps the key in its keychain and does not ask again."
                 : "Locked notes are encrypted on this Mac before they go to \(place), so nobody can read them there, \(model.provider == .google ? "Google" : "Apple") included. The key stays in this Mac's keychain. You type this password once on each other Mac to read them there. If you forget it and lose your Macs, the encrypted copies cannot be opened by anyone.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                SecureField("Password", text: $password)
                if !opening { SecureField("Confirm password", text: $again) }
            }
            Text(problem ?? (opening ? " " : "At least 8 characters.")).font(.callout).foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(opening ? "Unlock" : "Encrypt Locked Notes") { done(opening) }.keyboardShortcut(.defaultAction).disabled(password.isEmpty || (!opening && (password.count < 8 || again.isEmpty)))
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func done(_ opening: Bool) {
        if opening {
            if model.openVault(password: password) { dismiss() } else { problem = String(localized: "That is not the password."); password = "" }
        } else {
            guard password == again else { problem = String(localized: "The two passwords are not the same."); return }
            if model.startEncrypting(password: password) { dismiss() } else { problem = String(localized: "Encrypting could not be switched on.") }
        }
    }
}
