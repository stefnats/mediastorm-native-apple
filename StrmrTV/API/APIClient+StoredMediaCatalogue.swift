import CoreFoundation
import Foundation

struct StoredMediaReply: Sendable {
    let data: Data
    let status: Int
    let date: String?
    let started: ContinuousClock.Instant
    let received: ContinuousClock.Instant
    func clock() throws -> RecordingResponseClock {
        guard let date else { throw StoredMediaFailure.invalid }
        return try RecordingResponseClock(date: date, started: started, received: received, budgetMS: 30_000)
    }
}

/// The finite saved catalogue owns its actual response resource through
/// invalidation. A cancelled read cannot release a slot while its task still runs.
private final class StoredMediaHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Slots: @unchecked Sendable { let lock = NSLock(); var used = 0 }
    private static let slots = Slots()
    private let lock = NSLock()
    private var callback: CheckedContinuation<StoredMediaReply, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var url: URL?
    private var started = ContinuousClock.now
    private var result: Result<StoredMediaReply, Error>?
    private var failure: Error?
    private var cancelled = false
    private var charged = false

    static func send(_ request: URLRequest) async throws -> StoredMediaReply {
        let owner = StoredMediaHTTP()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { owner.start(request, callback: $0) }
        } onCancel: { owner.cancel() }
    }
    private func start(_ request: URLRequest, callback: CheckedContinuation<StoredMediaReply, Error>) {
        Self.slots.lock.lock()
        let allowed = Self.slots.used < 2
        if allowed { Self.slots.used += 1 }
        Self.slots.lock.unlock()
        guard allowed else { callback.resume(throwing: StoredMediaFailure.invalid); return }
        lock.lock()
        if cancelled {
            lock.unlock(); Self.slots.lock.lock(); Self.slots.used -= 1; Self.slots.lock.unlock()
            callback.resume(throwing: CancellationError()); return
        }
        charged = true; self.callback = callback; url = request.url; started = .now
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false; config.urlCache = nil; config.httpCookieStorage = nil
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        var request = request; request.timeoutInterval = 30
        let task = session.dataTask(with: request)
        self.session = session; self.task = task
        lock.unlock(); task.resume()
    }
    private func cancel() { lock.lock(); cancelled = true; let task = self.task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let http = response as? HTTPURLResponse
        let valid = !cancelled && response.url == url && http != nil && response.expectedContentLength <= 4_194_304 &&
            (!(200..<300).contains(http!.statusCode) || http!.statusCode == 204 || response.mimeType == "application/json")
        if valid { self.response = response as? HTTPURLResponse } else { failure = StoredMediaFailure.invalid }
        lock.unlock(); completionHandler(valid ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let overflow = self.data.count + data.count > 4_194_304
        if overflow { failure = StoredMediaFailure.invalid; self.data.removeAll() }
        else if failure == nil && !cancelled { self.data.append(data) }
        lock.unlock(); if overflow { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if cancelled { result = .failure(CancellationError()) }
        else if let failure = failure ?? error { result = .failure(failure) }
        else if let response { result = .success(StoredMediaReply(data: data, status: response.statusCode,
            date: response.value(forHTTPHeaderField: "Date"), started: started, received: .now)) }
        else { result = .failure(StoredMediaFailure.invalid) }
        data.removeAll(); lock.unlock(); session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock(); let callback = self.callback, result = self.result ?? .failure(error ?? StoredMediaFailure.invalid), refund = charged
        self.callback = nil; self.result = nil; self.session = nil; self.task = nil; charged = false; lock.unlock()
        if refund { Self.slots.lock.lock(); Self.slots.used -= 1; Self.slots.lock.unlock() }
        callback?.resume(with: result)
    }
}

struct StoredMediaObservation {
    let identity: String
    let deadline: ContinuousClock.Instant
    func current(now: ContinuousClock.Instant = .now) -> Bool { now < deadline }
}

@MainActor
enum StoredMediaWire {
    static func object(_ raw: Any?) throws -> [String: Any] {
        guard let raw = raw as? [String: Any] else { throw StoredMediaFailure.invalid }; return raw
    }
    static func integer(_ raw: Any?) throws -> Int {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              let number = Int(value.stringValue), String(number) == value.stringValue, number >= 0 else { throw StoredMediaFailure.invalid }; return number
    }
    static func bool(_ raw: Any?) -> Bool? {
        guard let raw = raw as? NSNumber, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }; return raw.boolValue
    }
    static func text(_ raw: Any?) throws -> String {
        guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 2048, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw StoredMediaFailure.invalid }; return value
    }
    private static let fraction: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let whole: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    static func date(_ raw: Any?) throws -> Double {
        let value = try text(raw)
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil,
              let date = fraction.date(from: value) ?? whole.date(from: value) else { throw StoredMediaFailure.invalid }; return date.timeIntervalSince1970 * 1000
    }
    static func decode<T: Decodable>(_ type: T.Type, _ raw: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: raw))
    }
    static func capability(_ root: [String: Any], localLibrary: Bool? = nil) -> StoredMediaCapability {
        StoredMediaCapability(originalLanguage: localLibrary != false && bool(root["originalLanguageFilterSupported"]) == true,
            media: bool(root["storedMediaFilterSupported"]) == true, basis: root["storedMediaFilterBasis"] as? String)
    }
    static func letters(_ raw: Any?) throws -> [String] {
        guard let raw else { return [] }
        guard let values = raw as? [String], values.count <= 27, Set(values).count == values.count,
              values.allSatisfy({ $0 == "#" || $0.range(of: #"^[A-Z]$"#, options: .regularExpression) != nil }) else { throw StoredMediaFailure.invalid }; return values
    }
    static func observation(_ root: [String: Any], source: String, query: [String: String], reply: StoredMediaReply) throws -> StoredMediaObservation? {
        let key: String
        switch source {
        case "continue-watching-cached": key = "pool"
        case "similar-cached": key = "similar"
        case "collection-cached": key = "collection"
        case "tmdb-public-list-cached": key = "publicList"
        case "tmdb-person-credits-cached": key = "personCredits"
        default: return nil
        }
        let value = try object(root[key]), clock = try reply.clock()
        let observed = try date(value["observedAt"]), expires = try date(value["expiresAt"])
        let maximum = source == "continue-watching-cached" ? 600_000.0 : 86_400_000.0
        guard ceil(observed) <= clock.upperAtReceiptMS, expires > observed, expires - observed <= maximum,
              floor(expires) > clock.upperAtReceiptMS else { throw StoredMediaFailure.expired }
        switch source {
        case "continue-watching-cached":
            let id = try text(value["id"])
            guard id.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil, bool(value["complete"]) == true else { throw StoredMediaFailure.invalid }
        case "similar-cached":
            guard String(try integer(value["tmdbId"])) == query["tmdbId"], try text(value["mediaType"]) == query["mediaType"], try text(value["scope"]) == "returned-results" else { throw StoredMediaFailure.invalid }
        case "collection-cached": guard String(try integer(value["id"])) == (query["collectionId"] ?? query["id"]) else { throw StoredMediaFailure.invalid }
        case "tmdb-public-list-cached": guard String(try integer(value["listId"])) == query["listId"], try text(value["scope"]) == "returned-items" else { throw StoredMediaFailure.invalid }
        default: guard String(try integer(value["personId"])) == query["personId"], try text(value["sourceType"]) == "person-credits", try text(value["scope"]) == "returned-cast-titles" else { throw StoredMediaFailure.invalid }
        }
        if key != "pool" { let language = try text(value["metadataLanguage"]); guard language.count <= 32 else { throw StoredMediaFailure.invalid } }
        let identity = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]).base64EncodedString()
        let remaining = floor(expires) - clock.upperAtReceiptMS
        return StoredMediaObservation(identity: source + ":" + identity, deadline: reply.received.advanced(by: .milliseconds(Int64(remaining))))
    }
    static func page(_ reply: StoredMediaReply, list: BrowseList, options: BrowseOptions, query: [String: String], limit: Int, offset: Int) throws -> BrowsePage {
        let root = try object(JSONSerialization.jsonObject(with: reply.data)), source = query["source"] ?? ""
        let support = capability(root)
        try support.require(options)
        let total = try integer(root["total"])
        guard let rows = root["items"] as? [[String: Any]], total >= rows.count, rows.count <= 4096 else { throw StoredMediaFailure.invalid }
        let strict = source.hasSuffix("-cached") || source == "hidden" || source == "loved-stored"
        if strict {
            guard try text(root["source"]) == source, support.originalLanguage,
                  rows.count == min(limit, max(0, total - offset)) else { throw StoredMediaFailure.invalid }
        }
        let observed = try observation(root, source: source, query: query, reply: reply)
        var hidden: [HiddenItem]?, watching: [ContinueWatchingItem]?
        let entries: [BrowseEntry]
        if source == "continue-watching-cached" {
            guard total <= 4096 else { throw StoredMediaFailure.invalid }
            watching = try rows.map { row in
                let kind = try text(row["mediaType"]), id = try text(row["seriesId"])
                try validatePrimary(id, kind: kind)
                _ = try date(row["updatedAt"])
                let item = try decode(ContinueWatchingItem.self, row)
                if let resume = item.resume { guard resume.position.isFinite, resume.position >= 0, resume.duration.isFinite, (resume.duration == 0 || resume.duration >= resume.position), resume.percent.isFinite, (0...100).contains(resume.percent) else { throw StoredMediaFailure.invalid } }
                return item
            }
            entries = try rows.map { .title(try minimalTitle(id: text($0["seriesId"]), name: text($0["seriesTitle"]), kind: text($0["mediaType"]), year: $0["year"])) }
        } else if source == "hidden" {
            hidden = try rows.map { try decode(HiddenItem.self, $0) }
            entries = try hidden!.map { .title(try minimalTitle(id: $0.id, name: $0.name ?? $0.id, kind: $0.mediaType, year: $0.year)) }
        } else {
            entries = try rows.map { row in
                if let title = row["title"] as? [String: Any] { return .title(try decode(Title.self, title)) }
                if list.itemShape == .item { return .item(try decode(WatchlistItem.self, row)) }
                return .title(try decode(Title.self, row))
            }
        }
        if source == "recently-watched-cached" || source == "popular-on-server-cached" {
            for (index, row) in rows.enumerated() {
                let rank = try integer(row["rank"])
                guard source == "recently-watched-cached" ? rank == offset + index + 1 : rank > 0 else { throw StoredMediaFailure.invalid }
            }
        }
        let effectiveTotal = support.originalLanguage || support.media ? total : (try root["sourceTotal"].map(integer) ?? total)
        var genres: [String] = []
        if let value = root["genres"], !(value is NSNull) {
            guard let values = value as? [String] else { throw StoredMediaFailure.invalid }; genres = values
        }
        return BrowsePage(entries: entries, total: max(effectiveTotal, entries.count), genres: genres,
            letters: try letters(root["alphabetBuckets"]), savedCapability: support, savedObservation: observed, savedHidden: hidden, savedWatching: watching)
    }
    static func library(_ reply: StoredMediaReply, library: LibraryRef, options: BrowseOptions) throws -> BrowsePage {
        let remote = ["plex", "jellyfin"].contains(library.sourceType?.lowercased() ?? "")
        var root = try object(JSONSerialization.jsonObject(with: reply.data))
        let support = capability(root, localLibrary: !remote); try support.require(options)
        for name in ["originalLanguageFilterSupported", "storedMediaFilterSupported", "storedMediaFilterBasis"] { root[name] = nil }
        let page = try decode(LibraryGroupPage.self, root)
        guard page.total >= page.groups.count, page.total >= 0 else { throw StoredMediaFailure.invalid }
        return BrowsePage(entries: page.groups.map { .library(LibraryEntry(library: library, group: $0)) }, total: page.total,
            letters: try letters(root["alphabetBuckets"]), savedCapability: support)
    }
    private static func validatePrimary(_ id: String, kind: String) throws {
        guard ["movie", "series"].contains(kind), id.range(of: #"^(?:tmdb:(?:movie|tv|series):[1-9][0-9]*|tvdb:(?:(?:movie|series):)?[1-9][0-9]*|imdb:(?:movie|series):tt[0-9]+)$"#, options: .regularExpression) != nil,
              !id.contains(":movie:") || kind == "movie", !id.contains(":series:") && !id.contains(":tv:") || kind == "series" else { throw StoredMediaFailure.invalid }
    }
    private static func minimalTitle(id: String, name: String, kind: String, year: Any?) throws -> Title {
        guard !name.isEmpty, ["movie", "series"].contains(kind) else { throw StoredMediaFailure.invalid }
        var raw: [String: Any] = ["id": id, "name": name, "mediaType": kind]
        if let year { raw["year"] = year }; return try decode(Title.self, raw)
    }
}

@MainActor
protocol StoredMediaAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func isCurrent(_ context: SourceActionContext) -> Bool
    func savedMediaPage(_ list: BrowseList, options: BrowseOptions, limit: Int, offset: Int, context: SourceActionContext) async throws -> BrowsePage
    func savedMediaUnhide(_ item: HiddenItem, context: SourceActionContext) async throws
}

extension APIClient: StoredMediaAPI {
    static func storedMediaRequest(_ context: SourceActionContext, path: String, method: String = "GET", query: [String: String]) throws -> URLRequest {
        var request = try context.request(method, path: path)
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw StoredMediaFailure.invalid }
        var values = query; values["profileId"] = context.profileID
        parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.url = parts.url; guard request.url != nil else { throw StoredMediaFailure.invalid }; return request
    }
    private func storedMediaResponse(_ request: URLRequest, context: SourceActionContext) async throws -> StoredMediaReply {
        try requireSourceContext(context)
        let reply = try await StoredMediaHTTP.send(request)
        try requireSourceContext(context)
        guard (200..<300).contains(reply.status) else { throw APIError.http(HTTPFailure(status: reply.status, data: reply.data)) }
        return reply
    }
    static func savedCatalogueQuery(_ list: BrowseList, options: BrowseOptions, limit: Int, offset: Int) throws -> [String: String] {
        guard list.storedEligible, let source = list.storedSource, (1...200).contains(limit), offset >= 0 else { throw StoredMediaFailure.unsupported }
        var query = list.query
        query["source"] = source
        if source.hasSuffix("-cached") || source == "hidden" || source == "loved-stored" {
            guard options.watch == .all, options.genres.isEmpty, list.savedSorts.contains(options.sort) else { throw StoredMediaFailure.invalid }
            if options.sort != .default { query["sortBy"] = options.sort.rawValue; query["sortDirection"] = options.ascending ? "asc" : "desc" }
            if let kind = options.kind { query["filterMediaType"] = kind.mediaType }; if let letter = options.letter { query["alphabet"] = letter }
        } else { query.merge(options.query(for: list)) { _, new in new } }
        query.merge(try options.savedQuery()) { _, new in new }; query["limit"] = String(limit); query["offset"] = String(offset)
        return query
    }
    func savedMediaPage(_ list: BrowseList, options: BrowseOptions, limit: Int, offset: Int, context: SourceActionContext) async throws -> BrowsePage {
        try requireSourceContext(context)
        if case let .library(library) = list { return try await savedLibraryPage(library, options: options, limit: limit, offset: offset, context: context) }
        let query = try Self.savedCatalogueQuery(list, options: options, limit: limit, offset: offset)
        let request = try Self.storedMediaRequest(context, path: "/api/users/\(Self.segment(context.profileID))/display-list", query: query)
        let reply = try await storedMediaResponse(request, context: context)
        let page = try StoredMediaWire.page(reply, list: list, options: options, query: query, limit: limit, offset: offset)
        try requireSourceContext(context); return page
    }
    func savedMediaUnhide(_ item: HiddenItem, context: SourceActionContext) async throws {
        let request = try Self.storedMediaRequest(context, path: "/api/users/\(Self.segment(context.profileID))/hidden-items/\(Self.segment(item.mediaType))/\(Self.segment(item.id))", method: "DELETE", query: [:])
        _ = try await storedMediaResponse(request, context: context)
    }
    static func savedLibraryQuery(_ library: LibraryRef, options: BrowseOptions, limit: Int, offset: Int, context: SourceActionContext) throws -> [String: String] {
        let remote = ["plex", "jellyfin"].contains(library.sourceType?.lowercased() ?? "")
        guard (1...200).contains(limit), offset >= 0, options.watch == .all, options.genres.isEmpty,
              BrowseList.library(library).savedSorts.contains(options.sort),
              BrowseList.library(library).storedEligible, !remote || !options.originalLanguageActive else { throw StoredMediaFailure.unsupported }
        var query = ["userId": context.profileID, "include": "cards", "limit": String(limit), "offset": String(offset),
            "sort": options.sort == .name ? "name" : options.sort == .year ? "year" : "created", "dir": options.sort == .default ? "desc" : options.ascending ? "asc" : "desc"]
        if options.sort == .name, let letter = options.letter { query["alphabet"] = letter }; if let kind = options.kind { query["mediaType"] = kind.mediaType }
        query.merge(try options.savedQuery()) { _, new in new }; return query
    }
    func savedLibraryPage(_ library: LibraryRef, options: BrowseOptions, limit: Int, offset: Int, context: SourceActionContext) async throws -> BrowsePage {
        let query = try Self.savedLibraryQuery(library, options: options, limit: limit, offset: offset, context: context)
        let reply = try await storedMediaResponse(Self.storedMediaRequest(context, path: "/api/library/libraries/\(Self.segment(library.id))/groups", query: query), context: context)
        let page = try StoredMediaWire.library(reply, library: library, options: options)
        try requireSourceContext(context); return page
    }
}
