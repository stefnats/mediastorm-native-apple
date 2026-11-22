import Foundation

@MainActor
protocol ReminderAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func isCurrent(_ context: SourceActionContext) -> Bool
    func remindersAllowed(_ context: SourceActionContext) -> Bool
    func reminders(_ context: SourceActionContext) async throws -> ReminderList
    func reminderInbox(_ context: SourceActionContext, unread: Bool, cursor: String?) async throws -> ReminderInbox
    func createReminder(_ choice: ReminderChoice, context: SourceActionContext) async throws -> ReminderCreated
    func revokeReminder(_ id: String, context: SourceActionContext) async throws
    func markReminderEvent(_ id: String, read: Bool?, dismissed: Bool?, context: SourceActionContext) async throws -> ReminderUpdated
    func reloadReminderTitle(_ subject: ReminderSubject, context: SourceActionContext) async throws -> ReminderSubject
}

extension APIClient: ReminderAPI {
    func remindersAllowed(_ context: SourceActionContext) -> Bool {
        isCurrent(context) && AppSession.shared.profile?.isKidsProfile == false
    }
    static func reminderRequest(_ context: SourceActionContext, method: String, suffix: String,
                                query: [String: String] = [:], body: [String: Any]? = nil) throws -> URLRequest {
        let path = "/api/users/\(segment(context.profileID))/" + suffix
        return try reminderRequest(context, method: method, path: path, query: query, body: body)
    }
    private static func reminderRequest(_ context: SourceActionContext, method: String, path: String,
                                        query: [String: String], body: [String: Any]?) throws -> URLRequest {
        var request = try context.request(method, path: path, body: body)
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ReminderFailure.invalid }
        parts.queryItems = (parts.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.url = parts.url; request.timeoutInterval = 5
        guard request.url != nil else { throw ReminderFailure.invalid }; return request
    }
    private func requireReminderContext(_ context: SourceActionContext) throws {
        try requireSourceContext(context)
        guard remindersAllowed(context) else { throw ReminderFailure.changed }
    }
    private func reminderRead<T: Decodable>(_ type: T.Type, request: URLRequest, context: SourceActionContext) async throws -> T {
        try requireReminderContext(context)
        let raw = try await sendOriginalSourceAction(request)
        try requireReminderContext(context)
        let value = try decoder.decode(type, from: raw)
        try requireReminderContext(context)
        return value
    }
    func reminders(_ context: SourceActionContext) async throws -> ReminderList {
        try await reminderRead(ReminderList.self, request: Self.reminderRequest(context, method: "GET", suffix: "reminders"), context: context)
    }
    func reminderInbox(_ context: SourceActionContext, unread: Bool, cursor: String?) async throws -> ReminderInbox {
        if let cursor { guard !cursor.isEmpty, cursor.count <= 2048, !cursor.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ReminderFailure.invalid } }
        var query = ["limit": "25"]
        if unread { query["unread"] = "true" }; if let cursor { query["cursor"] = cursor }
        return try await reminderRead(ReminderInbox.self, request: Self.reminderRequest(context, method: "GET", suffix: "reminder-events", query: query), context: context)
    }
    func createReminder(_ choice: ReminderChoice, context: SourceActionContext) async throws -> ReminderCreated {
        try await reminderRead(ReminderCreated.self, request: Self.reminderRequest(context, method: "POST", suffix: "reminders", body: choice.body()), context: context)
    }
    func revokeReminder(_ id: String, context: SourceActionContext) async throws {
        guard ReminderChoices.identifier(id) else { throw ReminderFailure.invalid }
        try requireReminderContext(context)
        _ = try await sendOriginalSourceAction(Self.reminderRequest(context, method: "DELETE", suffix: "reminders/\(Self.segment(id))"))
        try requireReminderContext(context)
    }
    static func reminderEventBody(read: Bool?, dismissed: Bool?) throws -> [String: Any] {
        guard read != nil || dismissed != nil else { throw ReminderFailure.invalid }
        var body: [String: Any] = [:]; if let read { body["read"] = read }; if let dismissed { body["dismissed"] = dismissed }; return body
    }
    func markReminderEvent(_ id: String, read: Bool?, dismissed: Bool?, context: SourceActionContext) async throws -> ReminderUpdated {
        guard ReminderChoices.identifier(id) else { throw ReminderFailure.invalid }
        return try await reminderRead(ReminderUpdated.self, request: Self.reminderRequest(context, method: "PATCH", suffix: "reminder-events/\(Self.segment(id))", body: Self.reminderEventBody(read: read, dismissed: dismissed)), context: context)
    }
    static func reminderTitleRequest(_ subject: ReminderSubject, context: SourceActionContext) throws -> URLRequest {
        let target = subject.target
        var query = ["titleId": target.titleID, "name": target.name, "userId": context.profileID]
        if let year = target.year { query["year"] = String(year) }; if let value = target.tmdbID { query["tmdbId"] = value }
        if let value = target.imdbID { query["imdbId"] = value }; if let value = target.tvdbID { query["tvdbId"] = value }
        return try Self.reminderRequest(context, method: "GET", path: target.isMovie ? "/api/metadata/movies/details" : "/api/metadata/series/details", query: query, body: nil)
    }
    func reloadReminderTitle(_ subject: ReminderSubject, context: SourceActionContext) async throws -> ReminderSubject {
        let target = subject.target
        let request = try Self.reminderTitleRequest(subject, context: context)
        if target.isMovie {
            let title = try await reminderRead(Title.self, request: request, context: context)
            return try ReminderSubject(target: target, title: title, seasons: [])
        }
        let details = try await reminderRead(SeriesDetails.self, request: request, context: context)
        return try ReminderSubject(target: target, title: details.title, seasons: details.seasons)
    }
}
