import AppKit
import Observation
import SamsungNotesKit
import SwiftUI
import WebKit

enum SidebarSection: Hashable {
    case all, favorites, trash, folder(String)

    /// How the section is remembered between launches.
    var stored: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .trash: return "trash"
        case .folder(let id): return "folder:" + id
        }
    }

    init?(stored: String) {
        switch stored {
        case "all": self = .all
        case "favorites": self = .favorites
        case "trash": self = .trash
        default:
            guard stored.hasPrefix("folder:") else { return nil }
            self = .folder(String(stored.dropFirst(7)))
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modified: return String(localized: "Date Modified")
        case .created: return String(localized: "Date Created")
        case .title: return String(localized: "Title")
        }
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var scheme: ColorScheme? { self == .dark ? .dark : self == .light ? .light : nil }
    var title: String {
        switch self {
        case .system: return String(localized: "Match System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    /// Reads the choice as saved, including the names an earlier build saved it under.
    init(stored: String?) {
        switch stored {
        case "dark", "On": self = .dark
        case "light", "Off": self = .light
        default: self = .system
        }
    }
}

enum GridStyle: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
    var title: String { self == .grid ? String(localized: "as Grid") : String(localized: "as List") }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

/// A note as the grid shows it.
struct NoteItem: Identifiable, Equatable {
    let record: NoteRecord
    let node: TreeNode?
    let title: String
    var id: String { record.id }
    var date: Date { node.flatMap { $0.lastModifiedTime > 0 ? Date(timeIntervalSince1970: Double($0.lastModifiedTime) / 1000) : nil } ?? record.modifiedAt }
}

/// Why the last sync did not finish, in words for the sidebar and in full for troubleshooting.
struct SyncProblem: Equatable {
    var message: String
    var detail: String
    var needsSignIn = false

    init(_ error: Error) {
        detail = "\(error)"
        message = AppModel.describe(error)
        if let http = error as? HTTPError, http.status == 401 || http.status == 403 { needsSignIn = true }
    }

    init(message: String, detail: String = "") {
        self.message = message
        self.detail = detail
    }
}

@MainActor
@Observable
final class AppModel {
    /// The app's one model, for the application delegate and other places outside the view tree.
    static weak var current: AppModel?

    let store: LocalStore
    let account: AccountManager
    let engine: SyncEngine
    let isDemo: Bool

    var section: SidebarSection? {
        didSet {
            guard section != oldValue else { return }
            clearSelection()
            remember(section?.stored, "section")
        }
    }
    var path: [String] = []
    var library: Library { didSet { reindex() } }
    var search = "" { didSet { if search != oldValue { listsChanged() } } }
    var sort: SortKey { didSet { if sort != oldValue { remember(sort.rawValue, "sortKey"); listsChanged() } } }
    var ascending: Bool { didSet { if ascending != oldValue { remember(ascending, "sortAscending"); listsChanged() } } }
    var gridStyle: GridStyle { didSet { remember(gridStyle.rawValue, "gridStyle") } }

    var signedIn = false
    var email: String?
    var showSignIn = false
    var isSyncing = false
    var syncMessage = ""
    /// How far the running sync has come, when it can tell.
    var syncFraction: Double?
    /// Why the last sync round failed. Stays until a round succeeds.
    var syncError: SyncProblem?
    /// Something other than sync that went wrong, shown above the notes until dismissed.
    var lastError: String?
    var signingOut = false

    /// The notes picked in the grid or list.
    var selection: Set<String> = [] { didSet { if selection != oldValue { QuickLook.shared.selectionChanged(in: self) } } }
    /// Where a ⇧-click or ⇧-arrow selection started, and where the keyboard is now.
    @ObservationIgnored var selectionAnchor: String?
    @ObservationIgnored var selectionCursor: String?
    /// The note or folder whose name is being typed in place.
    var renamingNote: String?
    var renamingFolder: String?
    /// Raised to put the keyboard in the search field (⌥⌘F).
    var searchRequests = 0
    /// The Settings tab to show when the window opens next.
    var settingsTab: SettingsTab?
    /// Folders shown closed in the sidebar.
    var collapsedFolders: Set<String> { didSet { remember(Array(collapsedFolders), "collapsedFolders") } }

    var syncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(syncEnabled, forKey: "syncEnabled")
            if syncEnabled { syncNow(quiet: true) } else { syncSoon?.cancel(); syncSoon = nil }
        }
    }
    /// Synced through a folder in iCloud Drive in place of Samsung's service (see `provider`).
    var icloudSync: Bool { didSet { remember(icloudSync, "icloudSync") } }
    /// Synced with the Drive of a Google account (see `provider`); never together with `icloudSync`.
    var googleSync: Bool { didSet { remember(googleSync, "googleSync") } }
    /// Calculations are answered as they are typed, and text is written to order by the Mac's own language model.
    var mathResults: Bool = UserDefaults.standard.object(forKey: "mathResults") as? Bool ?? true { didSet { UserDefaults.standard.set(mathResults, forKey: "mathResults") } }
    var aiWriting: Bool = UserDefaults.standard.object(forKey: "aiWriting") as? Bool ?? true { didSet { UserDefaults.standard.set(aiWriting, forKey: "aiWriting") } }
    var writesWithAI: Bool { aiWriting && NoteIntelligence.unavailable == nil }
    /// The Google account, as the views show it: whether the app holds its permission, and whose it is.
    var googleSignedIn = false
    var googleEmail: String?
    var googleSigningIn = false
    /// Notes that changed here and on another Mac, waiting for the user to choose.
    var syncConflicts: [FolderSync.Conflict] = []
    var showConflicts = false
    /// Encrypted notes in the folder that this Mac cannot read yet.
    var sealedWaiting = 0
    /// The folder's locked key, when locked notes were ever encrypted there, and whether this Mac holds the key.
    var vaultInFolder: Vault.Locked?
    var vaultOpen = false
    @ObservationIgnored var folderResolutions: [String: FolderSync.Resolution] = [:]
    /// The key of encrypted notes: each service's folder has its own.
    @ObservationIgnored let icloudVaultStore: SecretStore
    @ObservationIgnored let googleVaultStore: SecretStore
    var vaultStore: SecretStore { googleSync ? googleVaultStore : icloudVaultStore }
    @ObservationIgnored let google: GoogleAccount
    var appearance: AppearanceChoice { didSet { remember(appearance.rawValue, "appearance") } }

    /// The verifier of the account's password for locked notes, and the mark its locked notes carry.
    var lockPasscode: Passcode?
    var lockOwner: String?

    /// What a new note starts with: its paper's colour, its ruling, and how its pages scroll.
    var defaultPaper: UInt32 { didSet { remember(Int(defaultPaper), "defaultPaper") } }
    var defaultTemplate: PageTemplate { didSet { remember(defaultTemplate.rawValue, "defaultTemplate") } }
    var defaultScroll: ScrollDirection { didSet { remember(defaultScroll.rawValue, "defaultScroll") } }
    /// One page that grows ("infinite scroll") in place of separate pages; pages twice as high as wide.
    var defaultEndless: Bool { didSet { remember(defaultEndless, "defaultEndless") } }
    var defaultLong: Bool { didSet { remember(defaultLong, "defaultLong") } }
    /// Off: what is typed is stored when the note is left or saved (⌘S), not as it is typed.
    var autoSave: Bool { didSet { remember(autoSave, "autoSave") } }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored var syncSoon: Task<Void, Never>?
    @ObservationIgnored lazy var edits = LocalEdits(store: store)
    @ObservationIgnored let thumbnails = ThumbnailCache()
    @ObservationIgnored private(set) var logURL: URL?
    /// Nothing is remembered between launches while the app photographs itself.
    // The scripted runs leave the user's own preferences as they are.
    @ObservationIgnored private let remembers = Launch.value("--window-snapshot") == nil && Launch.value("--editor-check") == nil && Launch.value("--editor-check") == nil

    // MARK: Undo and unsaved work

    /// The undo manager of the window in front. Library changes and the note editor register here.
    @ObservationIgnored var undoManager: UndoManager? {
        didSet { if let undoManager { undoManagers.add(undoManager) } }
    }
    @ObservationIgnored private let undoManagers = NSHashTable<UndoManager>.weakObjects()
    @ObservationIgnored private var flushes: [String: @MainActor () -> Void] = [:]
    /// Folders made again by undoing a deletion that had already been sent: old id to new id.
    @ObservationIgnored private var folderAliases: [String: String] = [:]

    /// Work that must be written before the app quits or the account is signed out, such as text
    /// typed a moment ago. One closure per id; registering again replaces it.
    func registerFlush(_ id: String, _ work: @escaping @MainActor () -> Void) { flushes[id] = work }
    func unregisterFlush(_ id: String) { flushes[id] = nil }

    /// The window's undo manager, for the scripted checks.
    var undoManagerForChecks: UndoManager? { undoManager ?? NSApp.keyWindow?.undoManager ?? NSApp.mainWindow?.undoManager }

    /// Runs every registered flush. Called before quitting and before signing out.
    func flushAll() {
        for work in Array(flushes.values) { work() }
    }

    func registerUndo(_ name: String, _ inverse: @escaping @MainActor (AppModel) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in MainActor.assumeIsolated { inverse(model) } }
        undoManager.setActionName(name)
    }

    private func forgetUndo() {
        for manager in undoManagers.allObjects { manager.removeAllActions(withTarget: self) }
    }

    // MARK: Set-up

    /// Set by the main window so that code outside the view tree can open these.
    @ObservationIgnored var showSettingsWindow: (() -> Void)?
    @ObservationIgnored var showNoteWindow: ((String) -> Void)?
    @ObservationIgnored var showMainWindow: (() -> Void)?
    @ObservationIgnored var showPrivacyPolicy: (() -> Void)?
    @ObservationIgnored var showTermsOfUse: (() -> Void)?
    /// When the app last looked for changes on its own.
    @ObservationIgnored private var lastLook = Date.distantPast

    /// The settings the app kept under its former identifier come along, once, where the new one has none of its own.
    static func adoptFormerSettings() {
        let defaults = UserDefaults.standard
        guard let mine = Bundle.main.bundleIdentifier, mine != LocalStore.formerBundleID, !defaults.bool(forKey: "adoptedFormerSettings") else { return }
        if let former = defaults.persistentDomain(forName: LocalStore.formerBundleID) {
            let own = defaults.persistentDomain(forName: mine) ?? [:]
            for (key, value) in former where own[key] == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "adoptedFormerSettings")
    }

    init(storeRoot: URL? = nil, demo: Bool = false) {
        isDemo = demo
        if storeRoot == nil { AppModel.adoptFormerSettings() }
        let root = storeRoot ?? LocalStore.defaultRoot
        store = LocalStore(root: root)
        let secrets: SecretStore = storeRoot == nil ? KeychainStore() : FileSecretStore(url: root.appendingPathComponent("account.json"))
        account = AccountManager(store: secrets)
        engine = SyncEngine(account: account, store: store)
        let defaults = UserDefaults.standard
        // Notes live on this Mac; sync is something the user turns on, in Settings.
        syncEnabled = defaults.object(forKey: "syncEnabled") as? Bool ?? false
        // Checks and snapshots sync with a folder only when they are given one.
        let byICloud = Launch.value("--google-stand-in") == nil && (Launch.value("--sync-folder") != nil || (Launch.value("--window-snapshot") == nil && Launch.value("--editor-check") == nil && storeRoot == nil && defaults.bool(forKey: "icloudSync")))
        icloudSync = byICloud
        // The key of encrypted notes: in the keychain iCloud syncs when this build may use it, else in this Mac's own.
        icloudVaultStore = storeRoot != nil ? FileSecretStore(url: root.appendingPathComponent("vault.key")) as SecretStore
            : (CloudAccess.keyTravelsByKeychain ? SyncedKeychainStore(account: "sync-vault-key") as SecretStore : KeychainStore(account: "sync-vault-key") as SecretStore)
        googleVaultStore = storeRoot != nil ? FileSecretStore(url: root.appendingPathComponent("vault-google.key")) as SecretStore : KeychainStore(account: "sync-vault-key-google") as SecretStore
        // The checks play Google with a folder (`--google-stand-in`), and sync with it from the start.
        googleSync = Launch.value("--google-stand-in") != nil || (!byICloud && Launch.value("--window-snapshot") == nil && Launch.value("--editor-check") == nil && storeRoot == nil && defaults.bool(forKey: "googleSync"))
        // The checks can put a stand-in for all of Google at an address of this Mac (`--google-test-server`).
        google = GoogleAccount(store: storeRoot == nil ? KeychainStore(account: "google-account") as SecretStore : FileSecretStore(url: root.appendingPathComponent("google.json")) as SecretStore,
                               endpoints: Launch.value("--google-test-server").map(GoogleEndpoints.init(standIn:)) ?? .google)
        appearance = AppearanceChoice(stored: defaults.string(forKey: "appearance"))
        defaultPaper = (defaults.object(forKey: "defaultPaper") as? Int).map { UInt32(truncatingIfNeeded: $0) } ?? PaperColors.plain
        defaultTemplate = PageTemplate(rawValue: defaults.string(forKey: "defaultTemplate") ?? "") ?? .blank
        defaultScroll = ScrollDirection(rawValue: defaults.string(forKey: "defaultScroll") ?? "") ?? .vertical
        defaultEndless = defaults.bool(forKey: "defaultEndless")
        defaultLong = defaults.bool(forKey: "defaultLong")
        autoSave = defaults.object(forKey: "autoSave") as? Bool ?? true
        sort = SortKey(rawValue: defaults.string(forKey: "sortKey") ?? "") ?? .modified
        ascending = defaults.bool(forKey: "sortAscending")
        gridStyle = GridStyle(rawValue: defaults.string(forKey: "gridStyle") ?? "") ?? .grid
        collapsedFolders = Set(defaults.stringArray(forKey: "collapsedFolders") ?? [])
        let loaded = store.loadLibrary()
        library = loaded
        var restored = defaults.string(forKey: "section").flatMap(SidebarSection.init(stored:)) ?? .all
        if case .folder(let id) = restored, loaded.nodes[id]?.kind != .folder || loaded.nodes[id]?.state != .normal { restored = .all }
        section = Launch.value("--window-snapshot") == nil && Launch.value("--editor-check") == nil ? restored : .all
        if demo { signedIn = true; email = "you@example.com" }
        let log = SyncLog(url: root.appendingPathComponent("sync.log"))
        logURL = log.url
        HTTPClient.log = { log.append($0) }
        reindex()
        AppModel.current = self
    }

    private func remember(_ value: Any?, _ key: String) {
        guard remembers else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Called when a window appears. The account is looked up and the timer made only once.
    func start() {
        guard !started else { return }
        started = true
        // Handwriting is read in the background, so that search finds it.
        InkIndexer.shared.schedule(self)
        guard !isDemo else { return }
        // Samsung Cloud sync from before its risks were asked about is asked about now, once, before anything is sent.
        confirmSamsungRisksOnLaunch()
        Task {
            signedIn = await account.isSignedIn
            email = await account.loginID
            await refreshLock()
            // An account that was signed in before sync could be switched off was syncing: it still is.
            if signedIn, UserDefaults.standard.object(forKey: "syncEnabled") == nil { syncEnabled = true }
            if signedIn { syncNow(quiet: true) }
            await refreshGoogle()
            if syncsByFolder { refreshVault(); syncNow(quiet: true) }
        }
        // Samsung's service does not tell this app when something changed (its own clients are
        // told by their platforms' push services), so the app asks: every half minute while it is
        // in front, every five minutes while it is not, and at once when it comes to the front.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.lookForChanges(every: NSApplication.shared.isActive ? 30 : 300) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lookForChanges(every: 10) }
        }
    }

    /// One of the app's own rounds, unless the last one began less than `seconds` ago.
    private func lookForChanges(every seconds: Double) {
        // The scripted checks sync when they mean to.
        guard Date().timeIntervalSince(lastLook) >= seconds - 1, !isSyncing, Launch.value("--editor-check") == nil else { return }
        lastLook = Date()
        syncNow(quiet: true)
    }

    // MARK: The library as the views read it

    /// Raised when the library changes; `listGeneration` also when the search or the order does.
    private(set) var libraryGeneration = 0
    private(set) var listGeneration = 0
    @ObservationIgnored private var itemsByID: [String: NoteItem] = [:]
    @ObservationIgnored private var counts: [SidebarSection: Int] = [:]
    @ObservationIgnored private var lists: [SidebarSection: [NoteItem]] = [:]
    @ObservationIgnored private var folderLists: [String: [TreeNode]] = [:]
    @ObservationIgnored private var folderChildren: [String: [String]] = [:]

    private static let defaultTitleDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

    func title(for record: NoteRecord, node: TreeNode?) -> String {
        if !record.title.isEmpty { return record.title }
        if let name = node?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let day = AppModel.defaultTitleDate.string(from: record.createdAt)
        if record.hasInk { return String(localized: "Handwritten note \(day)") }
        if record.hasText { return String(localized: "Text note \(day)") }
        return String(localized: "No title")
    }

    /// Reads the library once into what the sidebar and the lists ask for again and again.
    func reindex() {
        var items: [String: NoteItem] = [:]
        var all = 0, favorites = 0, trash = 0
        var direct: [String: Int] = [:]
        for record in library.notes.values {
            let node = library.nodes[record.id]
            items[record.id] = NoteItem(record: record, node: node, title: title(for: record, node: node))
            switch node?.state ?? .normal {
            case .normal:
                all += 1
                if record.isFavorite { favorites += 1 }
                direct[node?.parentID ?? TreeNode.rootID, default: 0] += 1
            case .trashed: trash += 1
            case .deleted: break
            }
        }
        var children: [String: [String]] = [:]
        for node in library.nodes.values where node.kind == .folder { children[node.parentID, default: []].append(node.id) }
        var totals: [String: Int] = [:]
        func total(_ id: String, _ depth: Int) -> Int {
            if let known = totals[id] { return known }
            guard depth < 64 else { return 0 }
            totals[id] = 0   // a folder that contains itself counts once
            let sum = (direct[id] ?? 0) + (children[id] ?? []).reduce(0) { $0 + total($1, depth + 1) }
            totals[id] = sum
            return sum
        }
        var counted: [SidebarSection: Int] = [.all: all, .favorites: favorites, .trash: trash]
        for node in library.nodes.values where node.kind == .folder { counted[.folder(node.id)] = total(node.id, 0) }
        itemsByID = items
        counts = counted
        folderChildren = children
        folderLists = [:]
        lists = [:]
        libraryGeneration += 1
        listGeneration += 1
    }

    private func listsChanged() {
        lists = [:]
        listGeneration += 1
    }

    /// A folder and every folder below it.
    func subtree(of folder: String) -> Set<String> {
        var out: Set<String> = [folder]
        var frontier = [folder]
        while let next = frontier.popLast() {
            for child in folderChildren[next] ?? [] where out.insert(child).inserted { frontier.append(child) }
        }
        return out
    }

    /// The notes of a section, filtered by the search and in the chosen order. Worked out once
    /// per change of the library, the search or the order.
    func items(in section: SidebarSection) -> [NoteItem] {
        _ = listGeneration
        if let known = lists[section] { return known }
        var items: [NoteItem]
        func state(_ item: NoteItem) -> TreeNode.State { item.node?.state ?? .normal }
        switch section {
        case .all: items = itemsByID.values.filter { state($0) == .normal }
        case .favorites: items = itemsByID.values.filter { state($0) == .normal && $0.record.isFavorite }
        case .trash: items = itemsByID.values.filter { state($0) == .trashed }
        case .folder(let id):
            let folders = subtree(of: id)
            items = itemsByID.values.filter { state($0) == .normal && folders.contains($0.node?.parentID ?? "") }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            items = items.filter { item in
                if item.title.range(of: query, options: options) != nil { return true }
                // A locked note is found by its title only: what it holds stays closed.
                guard !item.record.isLocked else { return false }
                return (item.record.fullText ?? item.record.preview).range(of: query, options: options) != nil
                    || item.record.inkText?.range(of: query, options: options) != nil
            }
        }
        let ascending = ascending
        switch sort {
        case .modified: items.sort { ($0.date, $0.id) < ($1.date, $1.id) }
        case .created: items.sort { ($0.record.createdAt, $0.id) < ($1.record.createdAt, $1.id) }
        case .title: items.sort { a, b in
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        }
        if !ascending { items.reverse() }
        lists[section] = items
        return items
    }

    func count(_ section: SidebarSection) -> Int {
        _ = libraryGeneration
        return counts[section] ?? 0
    }

    /// The folders directly inside a folder, in Samsung's order.
    func folders(in parent: String) -> [TreeNode] {
        _ = libraryGeneration
        if let known = folderLists[parent] { return known }
        let found = library.folders(in: parent)
        folderLists[parent] = found
        return found
    }

    func sectionTitle(_ section: SidebarSection?) -> String {
        switch section {
        case .all, .none: return String(localized: "All notes")
        case .favorites: return String(localized: "Favorites")
        case .trash: return String(localized: "Trash")
        case .folder(let id):
            let name = library.nodes[id]?.name ?? ""
            return name.isEmpty ? String(localized: "Folder") : name
        }
    }

    func item(_ id: String) -> NoteItem? {
        _ = libraryGeneration
        return itemsByID[id]
    }

    func isTrashed(_ id: String) -> Bool { library.nodes[id]?.state == .trashed }

    /// The notes a menu command acts on: the open note, otherwise the selection in the order shown.
    var targetIDs: [String] {
        if let open = path.last { return library.notes[open] != nil ? [open] : [] }
        guard !selection.isEmpty, let section else { return [] }
        return items(in: section).filter { selection.contains($0.id) }.map(\.id)
    }

    // MARK: Sync and account

    /// Starts a sync round. `quiet` rounds are the app's own (timer, after an edit, at launch) and
    /// do not run while sync is switched off; the other kind is the user asking for one.
    func syncNow(quiet: Bool = false) {
        if syncsByFolder { syncFolderNow(); return }
        guard signedIn, !isSyncing, !isDemo, !signingOut else { return }
        if quiet, !syncEnabled { return }
        syncSoon?.cancel()
        syncSoon = nil
        isSyncing = true
        syncFraction = nil
        syncMessage = String(localized: "Syncing…")
        Task {
            var problem: SyncProblem?
            do {
                _ = try await engine.sync { progress in
                    Task { @MainActor [weak self] in self?.show(progress) }
                }
            } catch {
                problem = SyncProblem(error)
                HTTPClient.log?("sync failed: \(error)")
            }
            library = store.loadLibrary()
            await refreshLock()
            syncError = problem
            isSyncing = false
            syncFraction = nil
            InkIndexer.shared.schedule(self)
            // Something was changed here while the round ran: send it soon.
            if library.hasPendingUploads, problem == nil { scheduleSync() }
        }
    }

    private func show(_ progress: SyncEngine.Progress) {
        guard isSyncing else { return }
        var message = progress.message
        var fraction: Double?
        if let total = progress.total, total > 0 {
            let done = min(progress.done + 1, total)
            message = String(localized: "\(progress.message) \(done) of \(total)")
            fraction = Double(min(progress.done, total)) / Double(total)
        }
        if message != syncMessage { syncMessage = message }
        if fraction != syncFraction { syncFraction = fraction }
    }

    /// An error in words a person can act on. Raw details stay in the sync log.
    nonisolated static func describe(_ error: Error) -> String {
        if let http = error as? HTTPError {
            switch http.status {
            case 401, 403: return String(localized: "Samsung Cloud no longer accepts this sign-in. Sign out and sign in again.")
            case 408, 429: return String(localized: "Samsung Cloud is busy right now. Sync will try again shortly.")
            case 500...599: return String(localized: "Samsung Cloud is having trouble (error \(http.status)). Sync will try again shortly.")
            default: return String(localized: "Samsung Cloud did not accept a request (\(http.what), error \(http.status)).")
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return String(localized: "This Mac is offline. Changes will be sent when the connection is back.")
            case .timedOut: return String(localized: "Samsung Cloud took too long to answer. Sync will try again shortly.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return String(localized: "Samsung Cloud could not be reached.")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return String(localized: "A secure connection to Samsung Cloud could not be made.")
            default: return url.localizedDescription
            }
        }
        if error is CancellationError { return String(localized: "Sync was interrupted.") }
        if let known = error as? LocalizedError, let text = known.errorDescription { return text }
        let cocoa = error as NSError
        if type(of: error) is NSError.Type || cocoa.domain == NSCocoaErrorDomain || cocoa.domain == NSPOSIXErrorDomain { return cocoa.localizedDescription }
        // Errors of the library that say what happened in a sentence of their own.
        if let text = (error as? CustomStringConvertible)?.description { return text }
        return String(localized: "Something unexpected went wrong. The sync log in Settings has the details.")
    }

    // MARK: Changes made here

    /// Rereads the library after a change and arranges for it to be sent.
    func changed(sync: Bool = true) {
        library = store.loadLibrary()
        if sync { scheduleSync() }
    }

    func scheduleSync(after seconds: Double = 3) {
        guard (signedIn && syncEnabled) || syncsByFolder, !isDemo, !signingOut else { return }
        syncSoon?.cancel()
        syncSoon = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if isSyncing { scheduleSync(after: 2) } else { syncNow(quiet: true) }
        }
    }

    /// A note that should open with the pen in hand.
    var openForDrawing: String?

    func createNote(handwritten: Bool = false) {
        var parent = TreeNode.rootID
        if case .folder(let id) = section { parent = id }
        if section == .trash || section == .favorites || section == nil { section = .all }
        guard let id = try? edits.createTextNote(title: "", body: "", parent: parent, layout: NoteFile.Layout(long: defaultLong && !defaultEndless, endless: defaultEndless)) else {
            lastError = String(localized: "A new note could not be made.")
            return
        }
        // The style new notes are given in Settings.
        if defaultPaper != PaperColors.plain { try? edits.setPaper(id, .color(defaultPaper)) }
        if defaultTemplate != .blank { try? edits.setPaper(id, .template(defaultTemplate)) }
        if defaultScroll != .vertical, remembers { defaultScroll.remember(for: id) }
        changed(sync: false)
        if handwritten { openForDrawing = id }
        clearSelection()
        showMainWindow?()
        // Read first and shown whole, as any note that is opened.
        open(id)
    }

    @ObservationIgnored private var opening: Task<Void, Never>?

    /// Opens a note from the list: it is read and its first pages drawn first, and then shown,
    /// whole, in one step, instead of appearing in pieces.
    /// Back to the list of notes, crossfaded as opening a note is.
    func showList() {
        guard !path.isEmpty else { return }
        WindowCover.crossfade(WindowCover.notesWindow) { path = [] }
    }

    func open(_ id: String) {
        guard library.notes[id] != nil, path != [id] else { return }
        opening?.cancel()
        opening = Task { @MainActor [weak self] in
            guard let self else { return }
            let session = NoteSession(noteID: id, model: self)
            await session.load(text: true)
            if let note = session.note, let images = session.images {
                let window = NSApp.keyWindow ?? NSApp.mainWindow
                // The pages' width once the folders have made way: as the note view works it out.
                let width = max(min((window?.contentView?.bounds.width ?? 1180) - 150, 720), 320)
                let scale = window?.backingScaleFactor ?? 2
                let dark = (self.appearance.scheme.map { $0 == .dark }) ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                let shown = min(session.visiblePages, 2)
                await PageView.drawAhead(note, images: images, pages: 0..<shown, revisions: session.pageRevisions, pixels: Int(width * scale), dark: dark)
            }
            guard !Task.isCancelled, self.library.notes[id] != nil else { session.close(); return }
            NoteSession.ready[id] = session
            WindowCover.crossfade(WindowCover.notesWindow) { self.path = [id] }
        }
    }

    func saveText(_ id: String, title: String, body: String) {
        guard library.notes[id] != nil else { return }
        do { try edits.saveText(id, title: title, body: body); changed() } catch { lastError = String(localized: "The note could not be saved. \(AppModel.describe(error))") }
    }

    /// A new note left empty is not kept.
    func discardIfEmpty(_ id: String) {
        guard let record = library.notes[id], record.pending == .create, record.title.isEmpty, !record.hasText, !record.hasInk, record.coverFile == nil else { return }
        edits.deleteForever(id)
        selection.remove(id)
        changed()
    }

    /// Saves strokes drawn on a page and returns them as stored.
    func addStrokes(_ id: String, page: Int, strokes: [(points: [InkPoint], argb: UInt32, penSize: Double, id: String?)]) -> [InkStroke] {
        do {
            let saved = try edits.addStrokes(id, page: page, strokes: strokes)
            changed()
            return saved
        } catch {
            lastError = String(localized: "The drawing could not be saved. \(AppModel.describe(error))")
            return []
        }
    }

    func eraseStrokes(_ id: String, ids: Set<String>) {
        do { try edits.eraseStrokes(id, ids: ids); changed() } catch { lastError = String(localized: "The drawing could not be changed. \(AppModel.describe(error))") }
    }

    func setTrashed(_ ids: Set<String>, _ trashed: Bool) {
        let affected = ids.filter { library.notes[$0] != nil && isTrashed($0) != trashed }
        guard !affected.isEmpty else { return }
        var failed = 0
        for id in affected { do { try edits.setTrashed(id, trashed) } catch { failed += 1 } }
        path.removeAll { affected.contains($0) }
        selection.subtract(affected)
        changed()
        if failed > 0 { lastError = trashed ? String(localized: "Some notes could not be moved to the Trash.") : String(localized: "Some notes could not be restored.") }
        registerUndo(trashed ? String(localized: "Move to Trash") : String(localized: "Restore")) { $0.setTrashed(affected, !trashed) }
    }

    /// Deletes for good, without asking: the views go through `confirmDeleteForever`.
    func deleteForever(_ ids: Set<String>) {
        for id in ids { edits.deleteForever(id) }
        path.removeAll { ids.contains($0) }
        selection.subtract(ids)
        changed()
    }

    func emptyTrash() {
        edits.emptyTrash()
        selection = []
        changed()
    }

    func rename(_ id: String, to title: String) {
        let new = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let old = library.notes[id]?.title, old != new, new != item(id).map(editableTitle) else { return }
        guard edits.canRename(id) else {
            lastError = String(localized: "This note's title has formatting that cannot be rewritten here yet.")
            return
        }
        do {
            try edits.rename(id, to: new)
            changed()
            registerUndo(String(localized: "Rename")) { $0.rename(id, to: old) }
        } catch {
            lastError = String(localized: "The note could not be renamed. \(AppModel.describe(error))")
        }
    }

    func setFavorite(_ id: String, _ favorite: Bool) { setFavorite([id], favorite) }

    func setFavorite(_ ids: [String], _ favorite: Bool) {
        let affected = ids.filter { library.notes[$0].map { $0.isFavorite != favorite } ?? false }
        guard !affected.isEmpty else { return }
        for id in affected { try? edits.setFavorite(id, favorite) }
        changed()
        registerUndo(favorite ? String(localized: "Add to Favorites") : String(localized: "Remove from Favorites")) { $0.setFavorite(affected, !favorite) }
    }

    /// A folder's id today: a folder brought back by undo may have a new one.
    private func current(_ folder: String) -> String {
        var id = folder
        var hops = 0
        while let next = folderAliases[id], hops < 16 { id = next; hops += 1 }
        return id
    }

    func move(_ ids: Set<String>, to folder: String) {
        let target = current(folder)
        guard target == TreeNode.rootID || library.nodes[target]?.kind == .folder else { return }
        var before: [String: String] = [:]
        for id in ids {
            guard let node = library.nodes[id], node.kind == .note, node.parentID != target else { continue }
            before[id] = node.parentID
        }
        guard !before.isEmpty else { return }
        for id in before.keys { edits.move(id, to: target) }
        changed()
        registerUndo(String(localized: "Move")) { $0.restoreParents(before) }
    }

    private func restoreParents(_ parents: [String: String]) {
        var before: [String: String] = [:]
        for (id, parent) in parents {
            guard let node = library.nodes[id] else { continue }
            before[id] = node.parentID
            edits.move(id, to: current(parent))
        }
        changed()
        registerUndo(String(localized: "Move")) { $0.restoreParents(before) }
    }

    func duplicate(_ ids: [String]) {
        var made: Set<String> = []
        var failed = false
        for id in ids { if let new = try? edits.duplicate(id) { made.insert(new) } else { failed = true } }
        changed()
        if failed { lastError = String(localized: "Some notes could not be duplicated.") }
        guard !made.isEmpty else { return }
        if path.isEmpty { selection = made; selectionAnchor = nil; selectionCursor = nil }
        registerUndo(String(localized: "Duplicate")) { $0.setTrashed(made, true) }
    }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String, in parent: String = TreeNode.rootID) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = edits.createFolder(name: trimmed, parent: current(parent))
        changed()
        registerUndo(String(localized: "New Folder")) { $0.deleteFolder(id) }
        return id
    }

    /// A folder made at once and named in place, as the Finder does.
    func newFolder(in parent: String = TreeNode.rootID) {
        guard let id = createFolder(named: String(localized: "New folder"), in: parent) else { return }
        showMainWindow?()
        path = []
        section = .folder(id)
        renamingFolder = id
    }

    func renameFolder(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let old = library.nodes[id]?.name, old != trimmed else { return }
        edits.renameFolder(id, to: trimmed)
        changed()
        registerUndo(String(localized: "Rename Folder")) { $0.renameFolder($0.current(id), to: old) }
    }

    func setFolderColor(_ id: String, _ color: Int32) {
        guard let old = library.nodes[id]?.color, old != color else { return }
        edits.setFolderColor(id, color)
        changed()
        registerUndo(String(localized: "Folder Color")) { $0.setFolderColor($0.current(id), old) }
    }

    func moveFolder(_ id: String, to parent: String) {
        let target = current(parent)
        guard let old = library.nodes[id]?.parentID, old != target, id != target, !subtree(of: id).contains(target) else { return }
        edits.moveFolder(id, to: target)
        changed()
        registerUndo(String(localized: "Move Folder")) { $0.moveFolder($0.current(id), to: old) }
    }

    /// How many notes a folder and the folders in it hold.
    func notesInFolder(_ id: String) -> Int { count(.folder(id)) }

    /// Deletes a folder and those inside it; their notes go to the Trash. The views ask first.
    func deleteFolder(_ folder: String) {
        let id = current(folder)
        guard let node = library.nodes[id], node.kind == .folder, node.state == .normal else { return }
        let folders = subtree(of: id).compactMap { library.nodes[$0] }.filter { $0.kind == .folder && $0.state == .normal }
        let ids = Set(folders.map(\.id))
        var notes: [String: String] = [:]
        for other in library.nodes.values where other.kind == .note && other.state == .normal && ids.contains(other.parentID) && library.notes[other.id] != nil { notes[other.id] = other.parentID }
        do { try edits.deleteFolder(id) } catch {
            lastError = String(localized: "The folder could not be deleted. \(AppModel.describe(error))")
            changed()
            return
        }
        if case .folder(let shown) = section, ids.contains(shown) { section = .all }
        if let renamingFolder, ids.contains(renamingFolder) { self.renamingFolder = nil }
        selection.subtract(notes.keys)
        changed()
        registerUndo(String(localized: "Delete Folder")) { $0.bringBack(folders: folders, top: id, notes: notes) }
    }

    /// Undoes a folder's deletion. While the deletion is unsent the same folders return; once
    /// Samsung Cloud has it, new folders are made with the old names and the notes moved into them.
    private func bringBack(folders: [TreeNode], top: String, notes: [String: String]) {
        let unsent = library.dirtyNodes ?? []
        let ids = Set(folders.map(\.id))
        if ids.allSatisfy({ unsent.contains($0) && library.nodes[$0]?.state == .deleted }) {
            let millis = Int64(Date().timeIntervalSince1970 * 1000)
            store.exclusive {
                store.update { library in
                    for folder in folders {
                        guard var node = library.nodes[folder.id] else { continue }
                        node.state = .normal
                        node.syncModifiedTime = millis
                        node.lastModifiedTime = millis
                        library.nodes[folder.id] = node
                    }
                }
            }
        } else {
            // Parents before children, each under its parent's new id.
            var remaining = folders
            var passes = 0
            while !remaining.isEmpty, passes < 64 {
                passes += 1
                for folder in remaining where !ids.contains(folder.parentID) || folderAliases[folder.parentID] != nil || folder.id == top {
                    let new = edits.createFolder(name: folder.name, parent: current(folder.parentID))
                    edits.setFolderColor(new, folder.color)
                    folderAliases[folder.id] = new
                    remaining.removeAll { $0.id == folder.id }
                }
            }
        }
        for (note, parent) in notes where library.notes[note] != nil {
            try? edits.setTrashed(note, false)
            edits.move(note, to: current(parent))
        }
        changed()
        let restored = current(top)
        registerUndo(String(localized: "Delete Folder")) { $0.deleteFolder(restored) }
    }

    // MARK: Asking first

    func confirmDeleteForever(_ ids: Set<String>) {
        let ids = ids.filter { library.notes[$0] != nil }
        guard !ids.isEmpty else { return }
        let title = ids.count == 1 ? String(localized: "Delete “\(item(ids.first!)?.title ?? "")” forever?") : String(localized: "Delete \(Format.notes(ids.count)) forever?")
        let cloud = ids.contains { library.isInCloud($0) }
        let one = ids.count == 1
        Dialogs.confirm(title: title,
                        message: cloud
                            ? (one ? String(localized: "This removes it from this Mac and from Samsung Cloud on all your devices. You cannot undo this.")
                                   : String(localized: "This removes them from this Mac and from Samsung Cloud on all your devices. You cannot undo this."))
                            : (one ? String(localized: "This removes it from this Mac. You cannot undo this.") : String(localized: "This removes them from this Mac. You cannot undo this.")),
                        action: String(localized: "Delete")) { [weak self] in self?.deleteForever(ids) }
    }

    func confirmEmptyTrash() {
        let count = count(.trash)
        guard count > 0 else { return }
        let cloud = library.notes.values.contains { library.state(of: $0.id) == .trashed && !$0.serverID.isEmpty }
        Dialogs.confirm(title: String(localized: "Empty the Trash?"),
                        message: cloud ? String(localized: "\(Format.notes(count)) in the Trash will be deleted from this Mac and from Samsung Cloud on all your devices. You cannot undo this.")
                            : String(localized: "\(Format.notes(count)) in the Trash will be deleted from this Mac. You cannot undo this."),
                        action: String(localized: "Empty Trash")) { [weak self] in self?.emptyTrash() }
    }

    func confirmDeleteFolder(_ id: String) {
        guard let node = library.nodes[id], node.kind == .folder else { return }
        let notes = notesInFolder(id)
        let inside = subtree(of: id).count - 1
        var message = notes == 0 ? String(localized: "The folder is empty.") : String(localized: "\(Format.notes(notes)) in it will move to the Trash.")
        if inside > 0 { message += " " + String(localized: "The folders inside it are deleted too.") }
        Dialogs.confirm(title: String(localized: "Delete the folder “\(node.name)”?"), message: message, action: String(localized: "Delete Folder")) { [weak self] in self?.deleteFolder(id) }
    }

    func confirmSignOut() {
        guard signedIn, !isSyncing, !signingOut else { return }
        // What was typed a moment ago is written first, so the count below is true.
        flushAll()
        if syncsByFolder {
            Dialogs.confirm(title: String(localized: "Sign out of your Samsung account?"),
                            message: String(localized: "Your notes stay on this Mac and in \(provider.place). Samsung Cloud keeps its copies as they are now."), action: String(localized: "Sign Out")) { [weak self] in self?.signOut() }
            return
        }
        let effect = library.signOutSummary
        var parts: [String] = []
        if effect.goes + effect.copied > 0 {
            parts.append(String(localized: "Notes that are in Samsung Cloud are removed from this Mac. They stay in the cloud and come back when you sign in again."))
        }
        if effect.staysHere > 0 {
            parts.append(String(localized: "\(Format.notes(effect.staysHere)) that were never sent to Samsung Cloud stay on this Mac."))
        }
        if effect.copied > 0 {
            parts.append(String(localized: "\(Format.notes(effect.copied)) with changes that were not sent yet are kept on this Mac as separate notes."))
        }
        if parts.isEmpty { parts.append(String(localized: "Your notes stay on this Mac, and sync stops.")) }
        Dialogs.confirm(title: String(localized: "Sign out of your Samsung account?"),
                        message: parts.joined(separator: "\n\n"), action: String(localized: "Sign Out")) { [weak self] in self?.signOut() }
    }

    // MARK: Account

    @ObservationIgnored private var signInAttempt = 0

    /// True when changes are being sent to and fetched from Samsung Cloud.
    var syncIsOn: Bool { signedIn && syncEnabled && !isDemo }

    /// The switch in Settings. Turning sync on without an account asks for one first; the switch
    /// then goes on when the sign-in has worked, and stays off if it was given up.
    func setSync(_ on: Bool) {
        if !on { syncEnabled = false; return }
        // Samsung Cloud sync is unofficial: it goes on only once its risks are accepted.
        SamsungRisks.confirm { [weak self] in
            guard let self else { return }
            if self.signedIn { self.syncEnabled = true } else { self.beginSignIn() }
        }
    }

    func beginSignIn() {
        guard !isDemo, !signedIn else { return }
        SamsungRisks.confirm { [weak self] in
            self?.showMainWindow?()
            self?.showSignIn = true
        }
    }

    /// Samsung Cloud sync that was on before its risks were asked about (or before their wording
    /// changed) is asked about once; if they are not accepted, it is turned off.
    func confirmSamsungRisksOnLaunch() {
        guard syncEnabled, signedIn, !isDemo, !SamsungRisks.isAccepted else { return }
        var accepted = false
        SamsungRisks.confirm { accepted = true }
        if !accepted { syncEnabled = false }
    }

    /// Opens Settings on the account and sync tab.
    func showSyncSettings() {
        settingsTab = .account
        showSettingsWindow?()
    }

    func cancelSignIn() {
        signInAttempt += 1
        showSignIn = false
    }

    func finishSignIn(redirect: URL, pending: SamsungAccount.Pending) async {
        let attempt = signInAttempt
        do {
            try await account.completeSignIn(redirect: redirect, pending: pending, country3: "USA")
            guard attempt == signInAttempt else {
                // Cancelled while the last exchange was under way: the account is not kept.
                await account.signOut()
                await refreshLock()
                return
            }
            signedIn = true
            email = await account.loginID
            showSignIn = false
            lastError = nil
            syncError = nil
            // Signing in is asking for sync: what was written here goes up, what is there comes down.
            // Signed in while the notes are synced with iCloud or Google Drive: the account is there to turn to, and sync stays as it is.
            if !syncsByFolder { syncEnabled = true }
            syncNow()
        } catch {
            guard attempt == signInAttempt else { return }
            showSignIn = false
            lastError = String(localized: "Sign-in did not complete. \(AppModel.describe(error))")
        }
    }

    /// Signs out and removes everything, without asking: the views go through `confirmSignOut`.
    func signOut(then: (@MainActor () -> Void)? = nil) {
        guard !signingOut else { return }
        signingOut = true
        flushAll()
        syncSoon?.cancel()
        syncSoon = nil
        Task {
            // A round under way finishes first, so nothing is written after the wipe.
            await engine.idle()
            await account.signOut()
            await refreshLock()
            // The sign-in page's own session goes too, so the next sign-in starts from nothing.
            await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            syncSoon?.cancel()
            syncSoon = nil
            // Notes the cloud has leave this Mac; what was never sent stays, and so does
            // anything changed that was not sent (as a copy).
            if syncsByFolder {
                // The notes are iCloud's or Google Drive's too: they all stay, and only the account is forgotten.
                edits.forgetAccount()
            } else {
                do { try edits.detachFromAccount() } catch {
                    HTTPClient.log?("sign-out could not keep local notes: \(error)")
                    lastError = String(localized: "Some notes could not be kept on this Mac. \(AppModel.describe(error))")
                }
            }
            thumbnails.removeAll()
            forgetUndo()
            folderAliases = [:]
            flushes = [:]
            path = []
            selection = []
            renamingNote = nil
            renamingFolder = nil
            library = store.loadLibrary()
            reindex()
            syncEnabled = false
            section = .all
            signedIn = false
            email = nil
            syncError = nil
            signingOut = false
            then?()
        }
    }
}

enum Format {
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()
    private static let day: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd"); return f }()
    private static let dayYear: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("yMMMd"); return f }()
    private static let full: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()
    private static let spoken: DateFormatter = { let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f }()

    /// Today as a time, this year as a day, earlier with its year: as Samsung Notes dates its cards.
    static func cardDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) { return day.string(from: date) }
        return dayYear.string(from: date)
    }

    static func stamp(_ date: Date) -> String { full.string(from: date) }

    /// A date as VoiceOver should say it.
    static func spokenDate(_ date: Date) -> String { spoken.string(from: date) }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// "1 note", "2 notes": the system agrees the noun with the number.
    static func notes(_ count: Int) -> String { String(AttributedString(localized: "^[\(count) note](inflect: true)").characters) }
    static func changes(_ count: Int) -> String { String(AttributedString(localized: "^[\(count) change](inflect: true)").characters) }

    static func color(_ argb: Int32) -> Color? {
        let value = UInt32(bitPattern: argb)
        guard value >> 24 != 0, value & 0x00FF_FFFF != 0x00FF_FFFF || argb != -1 else { return nil }
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// A short record of what was asked of Samsung's servers and how they answered: no tokens, no
/// note content. It is what to look at when a sync fails.
final class SyncLog: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

    init(url: URL) {
        self.url = url
        // Start afresh once the file has grown.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > 400_000 { try? FileManager.default.removeItem(at: url) }
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
