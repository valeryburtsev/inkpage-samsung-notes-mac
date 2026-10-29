import Foundation

/// Samsung Cloud's own tokens: every call to the notes service carries the user token it issues.
public enum CloudIdentity {
    public static let appVersion = "4.3.826.0"
    public static let sdkVersion = "3.1.5.0"

    public struct Tokens: Codable, Sendable, Equatable {
        public var userToken: String
        public var userExpiresAt: Date
        public var deviceToken: String?
        public var deviceID: String?
        public var isFresh: Bool { userExpiresAt.timeIntervalSinceNow > 600 }
    }

    public struct Endpoints: Codable, Sendable, Equatable {
        public var api = "https://api.samsungcloud.com"
        public var identity = "https://play.samsungcloud.com"
        public init() {}
    }

    static func trusted(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), url.scheme == "https", let host = url.host?.lowercased(),
              host == "samsungcloud.com" || host.hasSuffix(".samsungcloud.com") else { return nil }
        return "https://\(host)"
    }

    /// Asks where this account's region is served from.
    public static func endpoints(country: String, http: HTTPClient = .shared) async -> Endpoints {
        var result = Endpoints()
        let headers = ["x-sc-app-id": SamsungAccount.notesClientID, "x-sc-os-type": "win", "x-sc-device-model": "Mac",
                       "x-sc-device-cc": country, "x-sc-os-version": "10", "Cache-Control": "no-cache"]
        if let response = try? await http.request("GET", URL(string: "https://ers.samsungcloud.com/ers/v1/endpoints")!, headers: headers),
           response.status == 200, let json = response.json {
            if let api = trusted(json["default"] as? String) { result.api = api }
            if let play = trusted(json["play"] as? String) { result.identity = play }
        }
        return result
    }

    /// Registers this Mac with Samsung Cloud for the notes client and returns its tokens.
    public static func register(accessToken: String, userID: String, physicalID: String, clientID: String, deviceName: String,
                                country: String, endpoints: Endpoints, http: HTTPClient = .shared) async throws -> Tokens {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string: "\(endpoints.identity)/identity/v2/user/register?deviceCurrentTime=\(now)")!
        let body: [String: Any] = [
            "app": ["version": appVersion, "sdkVersion": sdkVersion],
            "device": ["osType": "win", "osVersion": "10", "platformVersion": "10.0.26200.0", "type": "pc", "countryCode": country,
                       "modelName": "Mac", "modelCode": "Mac", "alias": deviceName, "osUserId": "S-1-5-21-\(UInt32(physicalID.prefix(8), radix: 16) ?? 1000)-1001"],
        ]
        let headers = [
            "x-sc-app-id": SamsungAccount.notesClientID, "x-sc-uid": userID, "x-sc-access-token": accessToken,
            "x-sc-pdid": physicalID, "x-sc-cdid": clientID,
            "User-Agent": "Mac; Professional 26200.0; Samsung Notes=\(appVersion); windows sdk=10.0.26200.0; sw=10; [SCWSDK]SCWindowsSDK_PAM=\(sdkVersion);",
            "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-cache",
        ]
        let response = try await http.request("POST", url, headers: headers, body: try JSONSerialization.data(withJSONObject: body))
        guard response.status == 200, let json = response.json, let tokens = json["tokens"] as? [[String: Any]] else {
            throw HTTPError(status: response.status, what: "Samsung Cloud registration", detail: response.text)
        }
        func token(_ type: String) -> (String, Date)? {
            guard let entry = tokens.first(where: { $0["type"] as? String == type }), let value = entry["accessToken"] as? String else { return nil }
            let expiry = (entry["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                ?? Date().addingTimeInterval((entry["expiresIn"] as? NSNumber)?.doubleValue ?? 3600)
            return (value, expiry)
        }
        guard let user = token("user") else { throw SamsungAccount.Failure.missingField("user token") }
        return Tokens(userToken: user.0, userExpiresAt: user.1, deviceToken: token("device")?.0, deviceID: json["dvcId"] as? String)
    }
}
