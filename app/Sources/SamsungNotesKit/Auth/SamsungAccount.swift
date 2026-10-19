import Foundation

/// Samsung account sign-in for the Notes client: the web sign-in that ends in an encrypted
/// redirect, the master token, and the per-service OAuth tokens. Protocol notes are in
/// `protocol/sync-protocol.md`, section 4.
public enum SamsungAccount {
    /// The Samsung Account app's own client: every Samsung client signs in through it.
    public static let accountClientID = "yfrtglt53o"
    /// Samsung Notes for Windows.
    public static let notesClientID = "tcl0p60gnz"
    public static let redirectURI = "ms-app://s-1-15-2-4027708247-2189610-1983755848-2937435718-1578786913-2158692839-1974417358"
    public static let redirectScheme = "ms-app"
    /// The sign-in pages only serve browsers they know; this is the Windows client's web view.
    public static let browserUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36 Edg/155.0.0.0"

    public enum Gate: String, Codable, Sendable { case windows = "WINSDK", android = "ANDROIDSDK" }

    public struct EntryPoint: Sendable {
        public let signInURI: String
        public let publicKey: String
        public let chkDoNum: String
        public let keyIterations: Int?
    }

    /// What must survive between opening the sign-in page and its redirect.
    public struct Pending: Codable, Sendable {
        public var state: String
        public var verifier: String
        public var deviceID: String
        public var createdAt: Date
        public var signInURL: URL
    }

    /// The signed-in account: the master token and where to use it.
    public struct Session: Codable, Sendable, Equatable {
        public var authServer: String
        public var loginID: String
        public var userID: String
        public var userAuthToken: String
        public var deviceID: String
        public var signedInAt: Date
        /// The device as the token calls name it: the Windows client sends its id with this suffix
        /// (36 characters in every captured call, and the form the sign-in gate echoes back).
        public var physicalAddress: String { address ?? SamsungAccount.physicalAddress(deviceID) }
        /// Set when the sign-in only went through with the bare id.
        public var address: String?
    }

    static func physicalAddress(_ deviceID: String) -> String { "\(deviceID):UID" }

    public struct OAuthToken: Codable, Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date
        public var refreshExpiresAt: Date?
        public var isFresh: Bool { expiresAt.timeIntervalSinceNow > 300 }
    }

    public enum Failure: Error, CustomStringConvertible {
        case expired, unexpectedRedirect, missingField(String), untrustedServer(String), server(String)
        public var description: String {
            switch self {
            case .expired: return "The sign-in took too long. Please try again."
            case .unexpectedRedirect: return "Samsung's sign-in page returned to an unexpected address."
            case .missingField(let name): return "Samsung's answer is missing \(name)."
            case .untrustedServer(let host): return "Samsung's answer names an unknown server (\(host))."
            case .server(let text): return text
            }
        }
    }

    static var clientHeaders: [String: String] {
        ["x-osp-packagename": "Samsung account", "x-osp-packageversion": "1.26.6021.0",
         "x-osp-clientosversion": "10.0.26200.9457", "x-osp-clientmodel": "VBSA", "Cache-Control": "no-cache"]
    }

    public static func entryPoint(gate: Gate, country: String, http: HTTPClient = .shared) async throws -> EntryPoint {
        var url = "https://account.samsung.com/accounts/\(gate.rawValue)/getEntryPoint"
        if gate == .windows { url += "?countryCode=\(country.uppercased())" }
        let response = try await http.request("GET", URL(string: url)!, headers: clientHeaders)
        guard response.status == 200, let json = response.json, let signIn = json["signInURI"] as? String,
              let key = json["pkiPublicKey"] as? String, let chk = json["chkDoNum"] as? String else {
            throw HTTPError(status: response.status, what: "Samsung account entry point", detail: response.text)
        }
        return EntryPoint(signInURI: signIn, publicKey: key, chkDoNum: chk, keyIterations: (json["pbeKySpcIters"] as? String).flatMap(Int.init))
    }

    /// Builds the address of the sign-in page. `iterations` is the PBKDF2 count for the request key.
    public static func begin(gate: Gate = .windows, country: String, language: String, deviceID: String, entry: EntryPoint, iterations: Int? = nil, overrides: [String: String] = [:]) throws -> Pending {
        let state = AccountCrypto.randomAlphanumeric(32)
        let verifier = AccountCrypto.randomAlphanumeric(50)
        var payload: [String: String] = [
            "clientId": accountClientID,
            "code_challenge": AccountCrypto.codeChallenge(verifier),
            "code_challenge_method": "S256",
            "competitorDeviceYNFlag": "Y",
            "countryCode": country.lowercased(),
            "deviceType": "APP",
            "deviceUniqueID": deviceID,
            "redirect_uri": redirectURI,
            "replaceableClientConnectYN": "N",
            "replaceableClientId": "",
            "replaceableDevicePhysicalAddressText": "",
            "responseEncryptionType": "1",
            "responseEncryptionYNFlag": "Y",
            "scope": "",
            "state": state,
            "svcIptLgnID": "",
            "iosYNFlag": "Y",
        ]
        switch gate {
        case .windows:
            // No deviceInfo: the gate turns away browsers it does not list, and the field is optional.
            // The sign-in pages turn away clients that do not say which SDK they are.
            payload["clientVer"] = "WINSDK2.25.109"
            payload["deviceModelID"] = "Mac"
            payload["deviceName"] = Host.current().localizedName ?? "Mac"
            payload["deviceOSVersion"] = "10.0.26200"
            payload["devicePhysicalAddressText"] = physicalAddress(deviceID)
        case .android:
            payload["deviceInfo"] = "Google|com.android.chrome"
            payload["deviceModelID"] = "Pixel 8 Pro"
            payload["deviceName"] = "Google Pixel 8 Pro"
            payload["deviceOSVersion"] = "35"
            payload["devicePhysicalAddressText"] = "ANID:\(deviceID)"
        }
        for (key, value) in overrides { if value == "-" { payload[key] = nil } else { payload[key] = value } }
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let count = iterations ?? Int(entry.chkDoNum) ?? 1
        let parameter = try AccountCrypto.encryptServiceParameter(json: json, chkDoNum: entry.chkDoNum, iterations: count, publicKeyBase64: entry.publicKey)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = parameter.addingPercentEncoding(withAllowedCharacters: allowed) ?? parameter
        let locale = "\(language.lowercased())_\(country.uppercased())"
        let query = gate == .windows ? "type=popup&locale=\(locale)&svcParam=\(encoded)" : "locale=\(locale)&svcParam=\(encoded)&mode=C"
        guard let url = URL(string: "\(entry.signInURI)?\(query)") else { throw Failure.missingField("signInURI") }
        return Pending(state: state, verifier: verifier, deviceID: deviceID, createdAt: Date(), signInURL: url)
    }

    public static func isRedirect(_ url: URL) -> Bool {
        url.scheme?.lowercased() == redirectScheme && url.absoluteString.lowercased().hasPrefix(redirectURI.lowercased())
    }

    /// Only Samsung's own account hosts may receive the code and the tokens. The value is taken
    /// apart as an address, so nothing after the host (a path, a query, a fragment, a port, a
    /// user name) can make another host pass for one of Samsung's.
    static func trustedServer(_ value: String) throws -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), components.scheme == "https", let host = components.host,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil, components.path.isEmpty || components.path == "/",
              !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !host.hasPrefix("."), !host.contains("..") else { throw Failure.untrustedServer(String(value.prefix(80))) }
        let allowed = host == "account.samsung.com" || host.hasSuffix(".samsungosp.com") || host.hasSuffix(".account.samsung.com")
        guard allowed else { throw Failure.untrustedServer(host) }
        return "https://\(host)"
    }

    static func post(_ url: String, fields: [(String, String)], what: String, http: HTTPClient) async throws -> [String: Any] {
        var headers = clientHeaders
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        guard let address = URL(string: url) else { throw Failure.untrustedServer(String(url.prefix(80))) }
        let response = try await http.request("POST", address, headers: headers, body: HTTPClient.formBody(fields))
        guard response.status == 200, let json = response.json else { throw HTTPError(status: response.status, what: what, detail: response.text) }
        return json
    }

    /// Turns the sign-in page's redirect into the account's master token.
    public static func complete(redirect: URL, pending: Pending, http: HTTPClient = .shared) async throws -> Session {
        guard abs(pending.createdAt.timeIntervalSinceNow) < 900 else { throw Failure.expired }
        guard isRedirect(redirect), let components = URLComponents(url: redirect, resolvingAgainstBaseURL: false) else { throw Failure.unexpectedRedirect }
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] { fields[item.name] = item.value ?? "" }
        if let fragment = components.fragment, let extra = URLComponents(string: "x://x?\(fragment)")?.queryItems {
            for item in extra { fields[item.name] = item.value ?? "" }
        }
        func field(_ name: String) throws -> String {
            guard let value = fields[name], !value.isEmpty else { throw Failure.missingField(name) }
            return value
        }
        let cipher = try AccountCrypto.RedirectCipher(originalState: pending.state, encryptedStateHex: try field("state"))
        let server = try trustedServer(try cipher.decrypt(try field("auth_server_url")))
        let code = try cipher.decrypt(try field("code"))
        let loginID = try cipher.decrypt(try field("retValue"))
        func authenticate(_ address: String) async throws -> [String: Any] {
            try await post("\(server)/auth/oauth2/authenticate", fields: [
                ("grant_type", "authorization_code"), ("client_id", accountClientID), ("code", code),
                ("code_verifier", pending.verifier), ("username", loginID), ("physical_address_text", address), ("serviceType", "M"),
            ], what: "Samsung account sign-in", http: http)
        }
        var bare: String?
        let json: [String: Any]
        do {
            json = try await authenticate(physicalAddress(pending.deviceID))
        } catch let error as HTTPError where (400..<500).contains(error.status) {
            // The Android flow names the device by its bare id: one more try that way.
            guard let second = try? await authenticate(pending.deviceID) else { throw error }
            json = second
            bare = pending.deviceID
        }
        guard let token = json["userauth_token"] as? String, let userID = json["userId"] as? String else { throw Failure.missingField("userauth_token") }
        return Session(authServer: server, loginID: loginID, userID: userID, userAuthToken: token, deviceID: pending.deviceID, signedInAt: Date(), address: bare)
    }

    /// A service token for one client, from the master token.
    public static func issueToken(clientID: String = notesClientID, scope: String = "offline.access", session: Session, http: HTTPClient = .shared) async throws -> OAuthToken {
        let verifier = AccountCrypto.randomAlphanumeric(50)
        let authorized = try await post("\(session.authServer)/auth/oauth2/v2/authorize", fields: [
            ("response_type", "code"), ("serviceType", "M"), ("client_id", clientID), ("userauth_token", session.userAuthToken),
            ("code_challenge", AccountCrypto.codeChallenge(verifier)), ("code_challenge_method", "S256"),
            ("physical_address_text", session.physicalAddress), ("scope", scope), ("login_id", session.loginID), ("childAccountSupported", "Y"),
        ], what: "Samsung authorization", http: http)
        guard let code = authorized["code"] as? String else { throw Failure.missingField("code") }
        let json = try await post("\(session.authServer)/auth/oauth2/token", fields: [
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code), ("code_verifier", verifier),
            ("physical_address_text", session.physicalAddress),
        ], what: "Samsung token", http: http)
        return try parseToken(json)
    }

    public static func refresh(_ token: OAuthToken, clientID: String = notesClientID, session: Session, http: HTTPClient = .shared) async throws -> OAuthToken {
        guard let refresh = token.refreshToken else { throw Failure.missingField("refresh_token") }
        let json = try await post("\(session.authServer)/auth/oauth2/token", fields: [
            ("grant_type", "refresh_token"), ("client_id", clientID), ("refresh_token", refresh),
        ], what: "Samsung token refresh", http: http)
        return try parseToken(json)
    }

    static func parseToken(_ json: [String: Any]) throws -> OAuthToken {
        guard let access = json["access_token"] as? String else { throw Failure.missingField("access_token") }
        func seconds(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue ?? (json[key] as? String).flatMap(Double.init) }
        let life = seconds("access_token_expires_in") ?? seconds("expires_in") ?? 3600
        let refresh = (json["refresh_token"] as? String).flatMap { $0.count > 8 ? $0 : nil }
        let refreshLife = seconds("refresh_token_expires_in").flatMap { $0 > 0 ? $0 : nil }
        return OAuthToken(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(life), refreshExpiresAt: refreshLife.map { Date().addingTimeInterval($0) })
    }
}
