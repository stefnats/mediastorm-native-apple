import Foundation

enum StoredMediaFailure: LocalizedError {
    case invalid, unsupported, changed, expired
    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "The saved filter data could not be read. Refresh this view explicitly.")
        case .unsupported: String(localized: "This server or catalogue does not confirm support for the selected saved filters.")
        case .changed: String(localized: "The original profile or saved view changed. Reopen this list.")
        case .expired: String(localized: "The saved catalogue observation expired. Refresh the saved view; no new search was started.")
        }
    }
}

/// Every conjunction is evaluated by the backend within one saved file/track.
struct StoredMediaFilters: Hashable {
    var audioLanguage: String?
    var subtitleLanguage: String?
    var audioCodec: String?
    var videoCodec: String?
    var hdr: String?
    var minHeight: Int?
    var subtitles: String?
    var unknown = "include"
    var active: Bool { audioLanguage != nil || subtitleLanguage != nil || audioCodec != nil || videoCodec != nil || hdr != nil || minHeight != nil || subtitles != nil }
    static let basis = "stored_library_versions"
    func canonical() throws -> Self {
        var value = self
        if let raw = audioLanguage { guard let code = MediaFilterValues.language(raw) else { throw StoredMediaFailure.invalid }; value.audioLanguage = code }
        if let raw = subtitleLanguage { guard let code = MediaFilterValues.language(raw) else { throw StoredMediaFailure.invalid }; value.subtitleLanguage = code }
        guard MediaFilterValues.codec(audioCodec), MediaFilterValues.codec(videoCodec),
              hdr == nil || MediaFilterValues.ranges.contains(hdr!), minHeight == nil || (144...8640).contains(minHeight!),
              subtitles == nil || ["present", "absent"].contains(subtitles!), ["include", "exclude", "only"].contains(unknown) else { throw StoredMediaFailure.invalid }
        return value
    }
    func query() throws -> [String: String] {
        let f = try canonical()
        guard f.active else { return [:] }
        var q = ["mediaUnknown": f.unknown]
        q["audioLanguage"] = f.audioLanguage; q["subtitleLanguage"] = f.subtitleLanguage
        q["audioCodec"] = f.audioCodec; q["videoCodec"] = f.videoCodec; q["hdr"] = f.hdr
        q["subtitles"] = f.subtitles; q["minHeight"] = f.minHeight.map(String.init)
        return q
    }
}

struct StoredMediaCapability: Hashable {
    var originalLanguage = false
    var media = false
    var basis: String?
    func require(_ options: BrowseOptions) throws {
        if options.originalLanguageActive && !originalLanguage { throw StoredMediaFailure.unsupported }
        if options.storedMedia.active && (!media || basis != StoredMediaFilters.basis) { throw StoredMediaFailure.unsupported }
    }
}

extension BrowseOptions {
    var originalLanguageActive: Bool { !originalLanguages.isEmpty || includeUnknownOriginalLanguage }
    var savedFiltersActive: Bool { originalLanguageActive || storedMedia.active }
    func savedQuery() throws -> [String: String] {
        var languages = Set<String>()
        for raw in originalLanguages {
            guard let code = MediaFilterValues.language(raw) else { throw StoredMediaFailure.invalid }; languages.insert(code)
        }
        guard languages.count <= 32 else { throw StoredMediaFailure.invalid }
        var query = try storedMedia.query()
        if !languages.isEmpty { query["originalLanguages"] = languages.sorted().joined(separator: ",") }
        if includeUnknownOriginalLanguage { query["includeUnknownOriginalLanguage"] = "true" }
        return query
    }
}

extension BrowseList {
    /// External discovery does not acquire saved-file facts by filtering a page.
    var storedSource: String? {
        switch self {
        case .custom: "custom-list"
        case .watchlist: "watchlist"
        case .permanentPrequeue: "permanent-prequeue"
        case .hidden: "hidden"
        case .continueWatching: "continue-watching-cached"
        case .popularOnServer: "popular-on-server-cached"
        case .similar: "similar-cached"
        case let .remote(_, _, query):
            ["hidden", "loved-stored", "continue-watching-cached", "collection-cached", "similar-cached", "recently-watched-cached", "popular-on-server-cached", "tmdb-public-list-cached", "tmdb-person-credits-cached"].contains(query["source"] ?? "")
                ? query["source"] : (["mdblist", "mdblist-url", "mdblist-shelf"].contains(query["source"] ?? "") && query["url"]?.hasPrefix("mediastorm:custom-list:") == true ? query["source"] : nil)
        default: nil
        }
    }
    var storedEligible: Bool {
        if case let .library(library) = self { return ["", "local", "plex", "jellyfin"].contains(library.sourceType?.lowercased() ?? "") }
        return storedSource != nil
    }
    var isDirectSavedCatalogue: Bool {
        if case .remote = self { return storedEligible }; return false
    }
    var savedSorts: [BrowseSort] {
        switch storedSource {
        case "similar-cached", "tmdb-public-list-cached", "tmdb-person-credits-cached", "recently-watched-cached", "popular-on-server-cached": return [.default, .name]
        case "continue-watching-cached": return [.default, .name, .year]
        case "collection-cached": return [.default, .name, .year]
        case "hidden", "loved-stored": return [.default, .added, .name, .year]
        default: return sorts
        }
    }
    var requiresSavedEntry: Bool {
        switch self { case .popularOnServer, .similar, .continueWatching: true; default: false }
    }
}
