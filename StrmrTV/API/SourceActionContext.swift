import Foundation

/// A client-side stale-result guard, never server authorization. Keep these original
/// values through a dialog; changing profile/server/session requires reopening it.
/// This value is not Codable and is never logged or persisted.
struct SourceActionContext: Equatable {
    let baseURL: URL
    let profileID: String
    let clientID: String
    private let sessionToken: String?
    private let unlock: String?
    private let remoteCredential: String?

    @MainActor
    init(_ api: APIClient) {
        baseURL = api.baseURL
        profileID = api.profileID
        clientID = Config.clientID
        sessionToken = api.token
        unlock = api.profileUnlocks.token(for: api.profileID)
        remoteCredential = api.remoteCredential
    }

    /// Internal initializer for deterministic context/encoding tests.
    init(baseURL: URL, profileID: String, clientID: String, sessionToken: String?,
         unlock: String? = nil, remoteCredential: String? = nil) {
        self.baseURL = baseURL
        self.profileID = profileID
        self.clientID = clientID
        self.sessionToken = sessionToken
        self.unlock = unlock
        self.remoteCredential = remoteCredential
    }

    /// Ordinary API resolution may refresh its session. A returned source still
    /// cannot cross a server/profile/client switch while that work was pending.
    func sameViewer(as other: SourceActionContext) -> Bool {
        baseURL == other.baseURL && profileID == other.profileID && clientID == other.clientID
            && remoteCredential == other.remoteCredential
    }

    func request(_ method: String, path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.notReady("Server address is invalid")
        }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + path
        components.queryItems = [URLQueryItem(name: "profileId", value: profileID)]
        guard let url = components.url else { throw APIError.notReady("Server address is invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(clientID, forHTTPHeaderField: "X-Client-ID")
        if let sessionToken { request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization") }
        if let unlock { request.setValue(unlock, forHTTPHeaderField: "X-Profile-Unlock") }
        if let remoteCredential { request.setValue(remoteCredential, forHTTPHeaderField: "X-Remote-Access-Credential") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}
