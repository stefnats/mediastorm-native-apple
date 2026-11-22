import Foundation

enum PersonalTitleRating: String, CaseIterable, Codable, Hashable {
    case like, love, dislike, none
    var label: String {
        switch self {
        case .like: String(localized: "Like")
        case .love: String(localized: "Love")
        case .dislike: String(localized: "Dislike")
        case .none: String(localized: "No personal rating")
        }
    }
}

enum PersonalTasteError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The personal choice could not be confirmed. Reload before trying again." }
    static func message(_ error: Error) -> String {
        switch (error as? APIError)?.statusCode {
        case 404, 405, 501: String(localized: "Personal preferences are unavailable on this server.")
        case 403: String(localized: "This profile cannot change these preferences.")
        case 409: String(localized: "Reload or search for these titles again before saving.")
        default: String(localized: "The personal choice could not be confirmed. Reload before trying again.")
        }
    }
}

struct TasteSetupReply: Decodable, Equatable {
    let status: String
    let source: String
    let titles: [Title]
    let available: Bool
    let canUseHistory: Bool
    let mediaTypes: [String]
    func validate() throws {
        guard ["new", "skipped", "completed"].contains(status), ["", "manual", "history"].contains(source),
              titles.count <= 40, titles.allSatisfy(PersonalTasteWire.valid), mediaTypes.count <= 2,
              Set(mediaTypes).count == mediaTypes.count, mediaTypes.allSatisfy({ ["movie", "series"].contains($0) }),
              !available || !mediaTypes.isEmpty else { throw PersonalTasteError.unavailable }
    }
}

enum PersonalTasteWire {
    static func valid(_ title: Title) -> Bool {
        !title.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.id.utf8.count <= 128 &&
            ["movie", "series", "tv"].contains(title.mediaType)
    }
    static func same(_ a: Title, _ b: Title) -> Bool {
        guard a.isMovie == b.isMovie else { return false }
        return a.id == b.id || (a.tmdbId.map { $0 > 0 && $0 == b.tmdbId } ?? false) ||
            (a.tvdbId.map { $0 > 0 && $0 == b.tvdbId } ?? false) ||
            (a.imdbId.map { !$0.isEmpty && $0 == b.imdbId } ?? false)
    }
    @MainActor static func path(_ context: SourceActionContext) -> String { "/api/users/\(APIClient.segment(context.profileID))" }
    @MainActor static func ratingRequest(_ rating: PersonalTitleRating?, target: DetailsTarget, context: SourceActionContext) throws -> URLRequest {
        guard !target.titleID.isEmpty, target.titleID.utf8.count <= 128 else { throw PersonalTasteError.unavailable }
        let path = path(context) + "/ratings/\(target.isMovie ? "movie" : "series")/\(APIClient.segment(target.titleID))"
        return try context.request(rating == nil ? "GET" : "PUT", path: path, body: rating.map { ["rating": $0.rawValue] })
    }
    @MainActor static func setupRequest(_ context: SourceActionContext, action: String? = nil, titles: [Title] = [], clear: Bool = false) throws -> URLRequest {
        guard !clear || action == nil && titles.isEmpty else { throw PersonalTasteError.unavailable }
        var body: [String: Any]?
        if let action {
            guard ["save", "skip", "history"].contains(action), titles.count <= 40,
                  action == "save" || titles.isEmpty, titles.allSatisfy(valid) else { throw PersonalTasteError.unavailable }
            body = ["action": action]
            if action == "save" { body?["titles"] = titles.map { ["titleId": $0.id, "mediaType": $0.isMovie ? "movie" : "series"] } }
        } else if !titles.isEmpty { throw PersonalTasteError.unavailable }
        let request = try context.request(clear ? "DELETE" : action == nil ? "GET" : "PUT", path: path(context) + "/taste-onboarding", body: body)
        guard request.httpBody.map({ $0.count <= 16_384 }) ?? true else { throw PersonalTasteError.unavailable }
        return request
    }
    @MainActor static func candidatesRequest(_ context: SourceActionContext, kind: String, query: String) throws -> URLRequest {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["movie", "series"].contains(kind), query.unicodeScalars.count <= 200 else { throw PersonalTasteError.unavailable }
        var request = try context.request("GET", path: path(context) + "/taste-onboarding/candidates")
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PersonalTasteError.unavailable }
        parts.queryItems = (parts.queryItems ?? []) + [.init(name: "kind", value: kind), .init(name: "q", value: query)]
        guard let url = parts.url else { throw PersonalTasteError.unavailable }
        request.url = url
        return request
    }
}

@MainActor
protocol PersonalTasteAPI: AnyObject {
    func isCurrent(_ context: SourceActionContext) -> Bool
    func readRating(_ target: DetailsTarget, context: SourceActionContext) async throws -> PersonalTitleRating
    func setRating(_ rating: PersonalTitleRating, target: DetailsTarget, context: SourceActionContext) async throws -> PersonalTitleRating
    func readTasteSetup(_ context: SourceActionContext) async throws -> TasteSetupReply
    func tasteCandidates(_ context: SourceActionContext, kind: String, query: String) async throws -> [Title]
    func saveTasteSetup(_ context: SourceActionContext, action: String, titles: [Title]) async throws -> TasteSetupReply
    func clearTasteSetup(_ context: SourceActionContext) async throws -> TasteSetupReply
}

extension APIClient: PersonalTasteAPI {
    private func tasteData(_ request: URLRequest, context: SourceActionContext) async throws -> Data {
        try requireSourceContext(context)
        let data = try await sendOriginalSourceAction(request)
        try Task.checkCancellation()
        try requireSourceContext(context)
        return data
    }
    private func tasteReply(_ request: URLRequest, context: SourceActionContext) async throws -> TasteSetupReply {
        let data = try await tasteData(request, context: context)
        let value = try decoder.decode(TasteSetupReply.self, from: data)
        try value.validate()
        return value
    }
    func readRating(_ target: DetailsTarget, context: SourceActionContext) async throws -> PersonalTitleRating {
        struct Reply: Decodable { let rating: PersonalTitleRating }
        let data = try await tasteData(PersonalTasteWire.ratingRequest(nil, target: target, context: context), context: context)
        return try decoder.decode(Reply.self, from: data).rating
    }
    func setRating(_ rating: PersonalTitleRating, target: DetailsTarget, context: SourceActionContext) async throws -> PersonalTitleRating {
        struct Reply: Decodable { let rating: PersonalTitleRating }
        let data = try await tasteData(PersonalTasteWire.ratingRequest(rating, target: target, context: context), context: context)
        let saved = try decoder.decode(Reply.self, from: data).rating
        guard saved == rating else { throw PersonalTasteError.unavailable }
        return saved
    }
    func readTasteSetup(_ context: SourceActionContext) async throws -> TasteSetupReply {
        try await tasteReply(PersonalTasteWire.setupRequest(context), context: context)
    }
    func tasteCandidates(_ context: SourceActionContext, kind: String, query: String) async throws -> [Title] {
        struct Page: Decodable { let items: [SearchResult] }
        let data = try await tasteData(PersonalTasteWire.candidatesRequest(context, kind: kind, query: query), context: context)
        let titles = try decoder.decode(Page.self, from: data).items.map(\.title)
        guard titles.count <= 24, titles.allSatisfy({ PersonalTasteWire.valid($0) && ($0.isMovie ? "movie" : "series") == kind }) else { throw PersonalTasteError.unavailable }
        return titles
    }
    func saveTasteSetup(_ context: SourceActionContext, action: String, titles: [Title]) async throws -> TasteSetupReply {
        try await tasteReply(PersonalTasteWire.setupRequest(context, action: action, titles: titles), context: context)
    }
    func clearTasteSetup(_ context: SourceActionContext) async throws -> TasteSetupReply {
        try await tasteReply(PersonalTasteWire.setupRequest(context, clear: true), context: context)
    }
}

extension Notification.Name { static let personalTasteChanged = Notification.Name("personalTasteChanged") }

@MainActor
enum PersonalTasteChanges {
    static func saved(_ context: SourceActionContext) {
        NotificationCenter.default.post(name: .personalTasteChanged, object: context)
    }
}
