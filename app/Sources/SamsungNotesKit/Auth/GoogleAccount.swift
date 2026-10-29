import CryptoKit
import Foundation
import Network

/// The app's registration with Google (an "OAuth client"), which whoever builds the app makes
/// once in Google Cloud Console and builds into it: Google gives no permission to an app
/// without one. A client registered as an app of Apple's platforms ("iOS") has an ID and no
/// secret, and Google answers its sign-in at an address only the app takes; one registered as
/// a "Desktop app" also has a "secret" (not one for an app on a desktop, as Google itself
/// says) and is answered on a port of this Mac.
public struct GoogleClient: Codable, Sendable, Equatable {
    public var id: String
    public var secret: String

    public init(id: String, secret: String = "") { self.id = id; self.secret = secret }

    /// Where Google sends the answer for a client without a secret: the client's ID turned
    /// around, as an address scheme of the app's own.
    public var appScheme: String? {
        let tail = ".apps.googleusercontent.com"
        guard secret.isEmpty, id.hasSuffix(tail), id.count > tail.count else { return nil }
        return "com.googleusercontent.apps." + id.dropLast(tail.count)
    }
}

/// Where Google is: its sign-in page, its token service and Drive's interface. A check puts a
/// stand-in at one address of this Mac in their place.
public struct GoogleEndpoints: Sendable, Equatable {
    public var authPage: String
    public var token: String
    public var revoke: String
    public var api: String
    public var upload: String

    public static let google = GoogleEndpoints(authPage: "https://accounts.google.com/o/oauth2/v2/auth", token: "https://oauth2.googleapis.com/token", revoke: "https://oauth2.googleapis.com/revoke",
                                               api: "https://www.googleapis.com/drive/v3", upload: "https://www.googleapis.com/upload/drive/v3")

    public init(authPage: String, token: String, revoke: String, api: String, upload: String) {
        self.authPage = authPage; self.token = token; self.revoke = revoke; self.api = api; self.upload = upload
    }

    /// A stand-in that answers for all of Google at `base` (`http://127.0.0.1:<port>`).
    public init(standIn base: String) {
        self.init(authPage: base + "/o/oauth2/v2/auth", token: base + "/token", revoke: base + "/revoke", api: base + "/drive/v3", upload: base + "/upload/drive/v3")
    }

    /// Whether an address Google's interface points on to (a place to send a file to, a place
    /// a file's content lies at) may be given the account's token: Google's interface itself
    /// over a safe connection, or the stand-in's own address.
    func takesToken(_ url: URL) -> Bool {
        if self == .google { return url.scheme == "https" && url.host?.hasSuffix(".googleapis.com") == true }
        guard let own = URL(string: upload) else { return false }
        return url.scheme == own.scheme && url.host == own.host && url.port == own.port
    }
}

/// The Google account the notes are synced with through Drive's own interface: its
/// permission, asked for on Google's own page, and the tokens that come of it.
public actor GoogleAccount {
    public struct State: Codable, Sendable, Equatable {
        public var client: GoogleClient?
        public var refreshToken: String?
        public var email: String?
        public init() {}
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noClient
        case notSignedIn
        /// Google's permission ran out or was taken back: the user signs in again.
        case signInAgain
        case cancelled
        case refused(String)

        public var description: String {
            switch self {
            case .noClient: return "No Google client is set."
            case .notSignedIn: return "Not signed in to Google."
            case .signInAgain: return "Google asks you to sign in again."
            case .cancelled: return "The sign-in was not finished."
            case .refused(let why): return why
            }
        }
    }

    /// All this app asks of an account: its own hidden folder in the Drive, and nothing else there.
    public static let scope = "https://www.googleapis.com/auth/drive.appdata"

    private let store: SecretStore
    private let http: HTTPClient
    let endpoints: GoogleEndpoints
    public private(set) var state: State
    private var access: (token: String, until: Date)?
    private var listening: LoopbackCatcher?

    public init(store: SecretStore, http: HTTPClient = .shared, endpoints: GoogleEndpoints = .google) {
        self.store = store
        self.http = http
        self.endpoints = endpoints
        state = store.load().flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    private func persist() { store.save(state == State() ? nil : try? JSONEncoder().encode(state)) }

    public var client: GoogleClient? { state.client }
    public var isSignedIn: Bool { state.refreshToken != nil }
    public var email: String? { state.email }

    /// Sets the app's registration with Google. Permission given to another one does not hold for it.
    public func setClient(_ client: GoogleClient?) {
        guard client != state.client else { return }
        state.client = client
        state.refreshToken = nil
        state.email = nil
        access = nil
        persist()
    }

    // MARK: Signing in

    static func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }

    /// The page on which the user gives permission. Its answer comes to `redirect`, on this Mac.
    static func page(_ address: String, client: GoogleClient, redirect: String, verifier: String, state: String) -> URL {
        var parts = URLComponents(string: address)!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: client.id), URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope), URLQueryItem(name: "code_challenge", value: encoded(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "state", value: state),
            // A token that lasts is given only when asked for, and only with the user's consent on the page.
            URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent"),
        ]
        return parts.url!
    }

    /// A sign-in under way for a client without a secret: the page to show, and the scheme of
    /// the address Google's answer comes back to.
    public struct Pending: Sendable {
        public var page: URL
        public var callbackScheme: String
        var redirect: String
        var verifier: String
        var mark: String
    }

    /// Begins a sign-in whose answer the system's sign-in window hands back to the app
    /// (`ASWebAuthenticationSession`): for a client registered as an app, without a secret.
    public func beginSignIn() throws -> Pending {
        guard let client = state.client else { throw Failure.noClient }
        guard let scheme = client.appScheme else { throw Failure.refused("This Google client is answered on a port of this Mac, not at an address of the app's.") }
        let redirect = scheme + ":/oauth2redirect"
        let verifier = GoogleAccount.encoded(GoogleAccount.random(48))
        let mark = GoogleAccount.encoded(GoogleAccount.random(16))
        return Pending(page: GoogleAccount.page(endpoints.authPage, client: client, redirect: redirect, verifier: verifier, state: mark), callbackScheme: scheme, redirect: redirect, verifier: verifier, mark: mark)
    }

    /// Finishes it with the address Google sent the sign-in window to.
    public func completeSignIn(_ pending: Pending, callback: URL) async throws {
        guard let client = state.client else { throw Failure.noClient }
        var answer: [String: String] = [:]
        for item in URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? [] { answer[item.name] = item.value ?? "" }
        guard callback.scheme?.lowercased() == pending.callbackScheme.lowercased() else { throw Failure.refused("The answer did not come to the app's own address.") }
        try await redeem(answer, client: client, redirect: pending.redirect, verifier: pending.verifier, mark: pending.mark)
    }

    /// Asks for the account's permission with a client that has a secret: `open` is given the
    /// page to show, and Google's answer comes back to a port on this Mac that is listened on
    /// until then. Google does not allow its sign-in inside an app's own web view.
    public func signIn(timeout: Double = 300, open: @Sendable (URL) -> Void) async throws {
        guard let client = state.client else { throw Failure.noClient }
        listening?.stop()
        let catcher = try LoopbackCatcher()
        listening = catcher
        defer { catcher.stop(); if listening === catcher { listening = nil } }
        let port = try await catcher.start()
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = GoogleAccount.encoded(GoogleAccount.random(48))
        let mark = GoogleAccount.encoded(GoogleAccount.random(16))
        open(GoogleAccount.page(endpoints.authPage, client: client, redirect: redirect, verifier: verifier, state: mark))
        let answer = try await catcher.answer(timeout: timeout)
        try await redeem(answer, client: client, redirect: redirect, verifier: verifier, mark: mark)
    }

    /// Takes Google's answer to the page, and gets the tokens for the code in it.
    private func redeem(_ answer: [String: String], client: GoogleClient, redirect: String, verifier: String, mark: String) async throws {
        guard answer["state"] == mark else { throw Failure.refused("The answer did not come from the sign-in that was started.") }
        if let error = answer["error"] { throw error == "access_denied" ? Failure.cancelled : Failure.refused("Google refused: \(error)") }
        guard let code = answer["code"] else { throw Failure.cancelled }
        var fields = [("code", code), ("client_id", client.id), ("redirect_uri", redirect), ("grant_type", "authorization_code"), ("code_verifier", verifier)]
        if !client.secret.isEmpty { fields.append(("client_secret", client.secret)) }
        let response = try await http.request("POST", URL(string: endpoints.token)!, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: HTTPClient.formBody(fields))
        guard response.status == 200, let json = response.json, let token = json["access_token"] as? String else { throw Failure.refused(GoogleAccount.reason(response)) }
        // The user can leave the Drive unticked on the page: then there is nothing to sync with.
        guard (json["scope"] as? String ?? GoogleAccount.scope).split(separator: " ").contains(Substring(GoogleAccount.scope)) else {
            throw Failure.refused("Permission for the app's folder in Google Drive was not given.")
        }
        guard let refresh = json["refresh_token"] as? String else { throw Failure.refused("Google gave no lasting permission.") }
        state.refreshToken = refresh
        access = (token, Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60))
        state.email = try? await GoogleDriveFiles(token: { _ in token }, http: http, endpoints: endpoints).owner()
        persist()
    }

    /// Ends a sign-in that is waiting for the browser.
    public func cancelSignIn() { listening?.stop() }

    private static func reason(_ response: HTTPResponse) -> String {
        let json = response.json
        let said = (json?["error_description"] as? String) ?? (json?["error"] as? String) ?? String(response.text.prefix(200))
        return "Google refused (HTTP \(response.status)): \(said)"
    }

    // MARK: Tokens

    /// A token for Drive's interface, renewed when it has run out or when `renew` says the last was refused.
    public func accessToken(renew: Bool = false) async throws -> String {
        if !renew, let access, access.until > Date() { return access.token }
        guard let client = state.client else { throw Failure.noClient }
        guard let refresh = state.refreshToken else { throw Failure.notSignedIn }
        var fields = [("refresh_token", refresh), ("client_id", client.id), ("grant_type", "refresh_token")]
        if !client.secret.isEmpty { fields.append(("client_secret", client.secret)) }
        let response = try await http.request("POST", URL(string: endpoints.token)!, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: HTTPClient.formBody(fields))
        if response.status == 400 || response.status == 401, response.json?["error"] as? String == "invalid_grant" {
            // Taken back in the Google account, or run out (a client still "in testing" gets a week).
            state.refreshToken = nil
            access = nil
            persist()
            throw Failure.signInAgain
        }
        guard response.status == 200, let json = response.json, let token = json["access_token"] as? String else { throw Failure.refused(GoogleAccount.reason(response)) }
        access = (token, Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60))
        return token
    }

    /// Gives the permission back to Google and forgets the account; the client stays.
    public func signOut() async {
        if let refresh = state.refreshToken {
            _ = try? await http.request("POST", URL(string: endpoints.revoke)!, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: HTTPClient.formBody([("token", refresh)]))
        }
        state.refreshToken = nil
        state.email = nil
        access = nil
        persist()
    }

    /// The account's Drive, as the cloud for `CloudMirror`.
    public nonisolated func drive(http: HTTPClient = .shared) -> GoogleDriveFiles {
        GoogleDriveFiles(token: { [self] renew in try await accessToken(renew: renew) }, http: http, endpoints: endpoints)
    }
}

/// Listens on a port of this Mac's own address for the one request with which the browser
/// brings back the answer of a sign-in page, and thanks it with a page to read.
final class LoopbackCatcher: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "snotes.loopback")
    private let lock = NSLock()
    private var ready: CheckedContinuation<UInt16, Error>?
    private var waiting: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init() throws {
        let parameters = NWParameters.tcp
        // Only this Mac can reach it.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Begins to listen and says on which port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); ready = continuation; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.began(.success(self.listener.port?.rawValue ?? 0))
                case .failed(let error): self.began(.failure(error)); self.finish(.failure(error))
                case .cancelled: self.began(.failure(GoogleAccount.Failure.cancelled))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    private func began(_ result: Result<UInt16, Error>) {
        lock.lock(); let continuation = ready; ready = nil; lock.unlock()
        continuation?.resume(with: result)
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume(with: outcome)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let line = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            var answer: [String: String] = [:]
            if parts.count >= 2, parts[0] == "GET", let items = URLComponents(string: "http://127.0.0.1" + parts[1])?.queryItems {
                for item in items { answer[item.name] = item.value ?? "" }
            }
            // The browser also asks for an icon and the like: only the answer itself counts.
            let isAnswer = answer["code"] != nil || answer["error"] != nil
            let text = isAnswer ? (answer["code"] != nil ? "You are signed in. You can close this page and go back to SNotes." : "The sign-in was not finished. You can close this page and go back to SNotes.") : ""
            let page = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(LocalStore.appName)</title></head><body style=\"font: 17px -apple-system, sans-serif; margin: 15% auto; max-width: 30em; text-align: center\"><p>\(text)</p></body></html>"
            let head = "HTTP/1.1 \(isAnswer ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + page).utf8), completion: .contentProcessed { _ in
                connection.cancel()
                if isAnswer { self?.finish(.success(answer)) }
            })
        }
    }

    /// The answer's fields, when it comes.
    func answer(timeout: Double) async throws -> [String: String] {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(GoogleAccount.Failure.cancelled)) }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return }
            waiting = continuation
            lock.unlock()
        }
    }

    func stop() {
        listener.cancel()
        finish(.failure(GoogleAccount.Failure.cancelled))
    }
}
