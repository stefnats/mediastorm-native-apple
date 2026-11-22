import Foundation

struct KidsLivePolicy: Decodable {
    let enabled: Bool
    let country: String
    let maximumAge: Int
    let guideSourceId: String
    var configured: Bool { enabled && country == "DE" && [0, 6, 12, 16, 18].contains(maximumAge) && !guideSourceId.isEmpty }
}
struct KidsLivePolicyReply: Decodable { let policy: KidsLivePolicy }
struct KidsLiveGuide: Decodable {
    let id: String
    let type: String
    let name: String?
    let observedAt: String
}
struct KidsLiveProgramme: Decodable {
    let title: String
    let startsAt: String
    let endsAt: String
    let age: Int
    let country: String
    let guide: KidsLiveGuide
    let classificationBasis: String
    var claim: String { "Age \(age)+ according to \(guide.name?.isEmpty == false ? guide.name! : "the selected guide")" }
}
struct KidsLiveChannel: Decodable, Identifiable {
    let id: String
    let name: String
    let programmeState: String
    let programmeReason: String?
    let programme: KidsLiveProgramme?
    var selectable: Bool { !id.isEmpty && programmeState == "within_limit" && programme != nil }
}
struct KidsLiveChannelsReply: Decodable { let channels: [KidsLiveChannel]; let total: Int }
struct KidsLiveStartReply: Decodable {
    let sessionId: String
    let playlistUrl: String
    let programmeEndsAt: String
    let programmeRemainingMillis: Int64
    let programme: KidsLiveProgramme
    let isDirect: Bool?
    let timeshiftWindowSeconds: Int?
}

struct KidsLiveOpened {
    let sessionID: String
    let url: URL
    let headers: [String: String]
    let programme: KidsLiveProgramme
    let deadline: Duration

    static func date(_ raw: String) -> Date? {
        (try? Date(raw, strategy: .iso8601)) ?? (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
    static func validSession(_ raw: String) -> Bool {
        raw.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    }
    static func validate(_ reply: KidsLiveStartReply, context: SourceActionContext,
                         requestedAt: Duration, now: Duration) throws -> Self {
        let p = reply.programme
        guard validSession(reply.sessionId), reply.isDirect != true, (reply.timeshiftWindowSeconds ?? 0) == 0,
              requestedAt >= .zero, reply.programmeRemainingMillis > 0, let end = date(reply.programmeEndsAt),
              let programmeEnd = date(p.endsAt), let start = date(p.startsAt), end == programmeEnd, end > start,
              p.country == "DE", [0, 6, 12, 16, 18].contains(p.age), p.classificationBasis == "selected_guide_claim",
              !p.title.isEmpty, !p.guide.id.isEmpty, !p.guide.type.isEmpty, date(p.guide.observedAt) != nil else {
            throw APIError.notReady("The selected programme is unavailable")
        }
        let deadline = requestedAt + .milliseconds(reply.programmeRemainingMillis)
        guard now < deadline else { throw APIError.notReady("This programme has ended. Choose a programme again.") }
        let expectedPath = "/video/hls/\(reply.sessionId)/stream.m3u8"
        guard let supplied = URLComponents(string: reply.playlistUrl), supplied.scheme == nil, supplied.host == nil,
              supplied.path == expectedPath, supplied.fragment == nil,
              (supplied.queryItems ?? []).allSatisfy({ $0.name == "profileId" && $0.value == context.profileID }) else {
            throw APIError.notReady("The child programme did not return its own server HLS playlist")
        }
        let request = try context.request("GET", path: "/api" + expectedPath)
        guard let rawURL = request.url, var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) else {
            throw APIError.notReady("The child programme address is unavailable")
        }
        var query = components.queryItems ?? []
        if let auth = request.value(forHTTPHeaderField: "Authorization"), auth.hasPrefix("Bearer ") {
            query.append(URLQueryItem(name: "token", value: String(auth.dropFirst(7))))
        }
        if let unlock = request.value(forHTTPHeaderField: "X-Profile-Unlock") {
            query.append(URLQueryItem(name: "profileUnlock", value: unlock))
        }
        query.append(URLQueryItem(name: "clientId", value: context.clientID))
        components.queryItems = query
        guard let url = components.url else { throw APIError.notReady("The child programme address is unavailable") }
        return Self(sessionID: reply.sessionId, url: url, headers: request.allHTTPHeaderFields ?? [:], programme: p, deadline: deadline)
    }
}
