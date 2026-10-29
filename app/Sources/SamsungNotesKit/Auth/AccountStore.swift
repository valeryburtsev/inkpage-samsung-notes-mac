import Foundation
import Security

/// Everything that identifies the signed-in account on this Mac. Stored as one secret.
public struct AccountState: Codable, Sendable, Equatable {
    public var session: SamsungAccount.Session?
    public var oauth: SamsungAccount.OAuthToken?
    public var cloud: CloudIdentity.Tokens?
    public var endpoints = CloudIdentity.Endpoints()
    public var deviceID = AccountCrypto.randomHex(16)
    public var physicalID = AccountCrypto.randomHex(16)
    public var clientID = AccountCrypto.randomHex(16)
    public var country = "USA"
    /// The verifier of the password of locked notes, and whether it was set here and has yet
    /// to be sent. Kept with the account's other secrets.
    public var passcode: Passcode?
    public var passcodeUnsent: Bool?
    public init() {}
    public var isSignedIn: Bool { session != nil }
}

public protocol SecretStore: Sendable {
    func load() -> Data?
    func save(_ data: Data?)
}

/// The login keychain, for the app.
public struct KeychainStore: SecretStore {
    let service: String
    let account: String
    public init(service: String = LocalStore.formerBundleID, account: String = "samsung-account") {
        self.service = service
        self.account = account
    }
    private var query: [CFString: Any] { [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] }

    public func load() -> Data? {
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }

    public func save(_ data: Data?) {
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var request = query
        request[kSecValueData] = data
        request[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(request as CFDictionary, nil)
    }
}

/// The keychain that iCloud keeps the same on all of the user's devices, end to end encrypted
/// by Apple. Only an app signed with a keychain access group may use it.
public struct SyncedKeychainStore: SecretStore {
    let service: String
    let account: String
    public init(service: String = LocalStore.formerBundleID, account: String) {
        self.service = service
        self.account = account
    }

    /// True when this app was signed with the entitlement the synced keychain asks for.
    public static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil), let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) else { return false }
        return !((value as? [String]) ?? []).isEmpty
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecAttrSynchronizable: true, kSecUseDataProtectionKeychain: true]
    }

    public func load() -> Data? {
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }

    public func save(_ data: Data?) {
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var request = query
        request[kSecValueData] = data
        request[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(request as CFDictionary, nil)
    }
}

/// A file only its owner can read, for the command-line probe and tests.
public struct FileSecretStore: SecretStore {
    let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> Data? { try? Data(contentsOf: url) }
    public func save(_ data: Data?) {
        guard let data else { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

/// Owns the account's tokens and renews them as they run out.
public actor AccountManager {
    private let store: SecretStore
    private let http: HTTPClient
    public private(set) var state: AccountState

    public init(store: SecretStore, http: HTTPClient = .shared) {
        self.store = store
        self.http = http
        state = store.load().flatMap { try? JSONDecoder().decode(AccountState.self, from: $0) } ?? AccountState()
    }

    private func persist() { store.save(try? JSONEncoder().encode(state)) }

    public var loginID: String? { state.session?.loginID }
    public var isSignedIn: Bool { state.isSignedIn }

    /// Prepares the sign-in page for the in-app browser.
    public func beginSignIn(country: String, language: String) async throws -> SamsungAccount.Pending {
        let entry = try await SamsungAccount.entryPoint(gate: .windows, country: country, http: http)
        return try SamsungAccount.begin(gate: .windows, country: country, language: language, deviceID: state.deviceID, entry: entry)
    }

    /// Finishes the sign-in with the page's redirect and gets every token down to the cloud's.
    public func completeSignIn(redirect: URL, pending: SamsungAccount.Pending, country3: String) async throws {
        let session = try await SamsungAccount.complete(redirect: redirect, pending: pending, http: http)
        state.session = session
        state.oauth = nil
        state.cloud = nil
        state.country = country3
        persist()
        let endpoints = await CloudIdentity.endpoints(country: country3, http: http)
        guard state.session == session else { throw SamsungAccount.Failure.server("Not signed in.") }
        state.endpoints = endpoints
        _ = try await cloudToken()
    }

    public func signOut() {
        let device = state.deviceID, physical = state.physicalID, client = state.clientID
        state = AccountState()
        state.deviceID = device; state.physicalID = physical; state.clientID = client
        persist()
    }

    func oauthToken() async throws -> String {
        guard let session = state.session else { throw SamsungAccount.Failure.server("Not signed in.") }
        if let token = state.oauth, token.isFresh { return token.accessToken }
        var fresh: SamsungAccount.OAuthToken
        if let token = state.oauth, token.refreshToken != nil, let renewed = try? await SamsungAccount.refresh(token, session: session, http: http) {
            fresh = renewed
        } else {
            fresh = try await SamsungAccount.issueToken(session: session, http: http)
        }
        // Signed out, or signed in as someone else, while the answer was on its way: it is not kept.
        guard state.session == session else { throw SamsungAccount.Failure.server("Not signed in.") }
        state.oauth = fresh
        persist()
        return fresh.accessToken
    }

    /// The token for the notes service, renewed when it is close to running out.
    public func cloudToken(forceNew: Bool = false) async throws -> String {
        guard let session = state.session else { throw SamsungAccount.Failure.server("Not signed in.") }
        if !forceNew, let cloud = state.cloud, cloud.isFresh { return cloud.userToken }
        if forceNew { state.oauth = nil }
        let access = try await oauthToken()
        let cloud = try await CloudIdentity.register(accessToken: access, userID: session.userID, physicalID: state.physicalID, clientID: state.clientID,
                                                     deviceName: Host.current().localizedName ?? "Mac", country: state.country, endpoints: state.endpoints, http: http)
        guard state.session == session else { throw SamsungAccount.Failure.server("Not signed in.") }
        state.cloud = cloud
        persist()
        return cloud.userToken
    }

    public var apiBase: String { state.endpoints.api }

    // MARK: The password of locked notes

    public var passcode: Passcode? { state.passcode }
    public var passcodeUnsent: Bool { state.passcodeUnsent ?? false }

    /// The mark this account's locked notes carry.
    public var lockOwner: String? { state.session.map { Passcode.owner(userID: $0.userID) } }

    /// Keeps a verifier: one made here waits to be sent, one from the service is the service's.
    public func setPasscode(_ passcode: Passcode?, unsent: Bool) {
        state.passcode = passcode
        state.passcodeUnsent = unsent ? true : nil
        persist()
    }
}
