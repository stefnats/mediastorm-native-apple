import Foundation

enum ContentArtworkKind: String, CaseIterable, Hashable {
    case poster = "posterUrl", backdrop = "backdropUrl"
    var label: String { self == .poster ? String(localized:"Poster") : String(localized:"Background") }
}

struct ContentArtworkPreference: Decodable, Equatable {
    let contentId: String?
    let artworkPreferenceSupported: Bool?
    let posterUrl: String?
    let backdropUrl: String?
    var supported: Bool { artworkPreferenceSupported == true }
    func choice(_ kind: ContentArtworkKind) -> String? {
        let value = kind == .poster ? posterUrl : backdropUrl
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct ContentArtworkOption: Equatable, Identifiable {
    let url: String?
    let preview: String?
    let label: String
    var id: String { url.map { "image:\($0)" } ?? "standard" }
}

enum ContentArtworkWire {
    static func key(_ id: String) -> String { id.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }
    static func options(_ title: Title, kind: ContentArtworkKind) -> [ContentArtworkOption] {
        let standard = kind == .poster ? (title.textPoster?.url ?? title.poster?.url) : title.backdrop?.url
        let images = kind == .poster ? [title.poster,title.textPoster].compactMap { $0 } + (title.posters ?? [])
            : [title.backdrop,title.textBackdrop].compactMap { $0 } + (title.backdrops ?? [])
        var seen = Set<String>()
        let variants = images.compactMap { image -> ContentArtworkOption? in
            guard !image.url.isEmpty, seen.count < 40, seen.insert(image.url).inserted else { return nil }
            return ContentArtworkOption(url:image.url,preview:image.url,label:"\(kind.label) \(seen.count)")
        }
        return [ContentArtworkOption(url:nil,preview:standard,label:String(localized:"Use standard picture"))] + variants
    }
    static func body(_ title: Title, kind: ContentArtworkKind, url: String?) throws -> [String:Any] {
        guard PersonalTasteWire.valid(title), options(title,kind:kind).contains(where:{$0.url == url}) else { throw PersonalTasteError.unavailable }
        return ["contentId":title.id,"contentType":title.isMovie ? "movie" : "series",kind.rawValue:url.map { $0 as Any } ?? NSNull()]
    }
    @MainActor static func request(_ title: Title, kind: ContentArtworkKind, url: String?, context: SourceActionContext) throws -> URLRequest {
        let request = try context.request("PUT",path:PersonalTasteWire.path(context)+"/content-preferences/artwork",body:body(title,kind:kind,url:url))
        guard request.httpBody.map({ $0.count <= 8192 }) == true else { throw PersonalTasteError.unavailable }
        return request
    }
}

@MainActor
protocol ContentArtworkAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func isCurrent(_ context: SourceActionContext) -> Bool
    func readContentArtwork(_ id: String, context: SourceActionContext) async throws -> ContentArtworkPreference
    func readAllContentArtwork(_ context: SourceActionContext) async throws -> [ContentArtworkPreference]
    func setContentArtwork(_ title: Title, kind: ContentArtworkKind, url: String?, context: SourceActionContext) async throws -> ContentArtworkPreference
}

extension APIClient: ContentArtworkAPI {
    func readContentArtwork(_ id: String, context: SourceActionContext) async throws -> ContentArtworkPreference {
        try requireSourceContext(context)
        let request = try context.request("GET",path:PersonalTasteWire.path(context)+"/preferences/content/\(Self.segment(id))")
        let raw = try await sendOriginalSourceAction(request)
        try Task.checkCancellation(); try requireSourceContext(context)
        let value = try decoder.decode(ContentArtworkPreference.self,from:raw)
        guard value.contentId == nil || value.contentId == ContentArtworkWire.key(id) else { throw PersonalTasteError.unavailable }
        guard value.contentId != nil || value.choice(.poster) == nil && value.choice(.backdrop) == nil else { throw PersonalTasteError.unavailable }
        return value
    }
    func readAllContentArtwork(_ context: SourceActionContext) async throws -> [ContentArtworkPreference] {
        try requireSourceContext(context)
        let request = try context.request("GET",path:PersonalTasteWire.path(context)+"/preferences/content")
        let raw = try await sendOriginalSourceAction(request)
        try Task.checkCancellation(); try requireSourceContext(context)
        return try decoder.decode([ContentArtworkPreference].self,from:raw)
    }
    func setContentArtwork(_ title: Title, kind: ContentArtworkKind, url: String?, context: SourceActionContext) async throws -> ContentArtworkPreference {
        try requireSourceContext(context)
        let request = try ContentArtworkWire.request(title,kind:kind,url:url,context:context)
        let raw = try await sendOriginalSourceAction(request)
        try Task.checkCancellation(); try requireSourceContext(context)
        let value = try decoder.decode(ContentArtworkPreference.self,from:raw)
        guard value.supported, value.contentId == ContentArtworkWire.key(title.id), value.choice(kind) == url else { throw PersonalTasteError.unavailable }
        return value
    }
}
