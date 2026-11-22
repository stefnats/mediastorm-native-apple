import Foundation

struct ContentLocalPreference: Decodable, Sendable {
    let contentId: String?
    let preferLocalFiles: Bool?
    let localSourcePreferenceSupported: Bool?

    var supported: Bool { localSourcePreferenceSupported == true }

    static func updateBody(_ value: Bool?, contentID: String, contentType: String) -> [String: Any] {
        ["contentId": contentID, "contentType": contentType,
         "preferLocalFiles": value.map { $0 as Any } ?? NSNull()]
    }
}

@MainActor
protocol ContentLocalPreferenceAPI: AnyObject {
    func sourceContext() -> SourceActionContext
    func isCurrent(_ context: SourceActionContext) -> Bool
    func contentLocalPreference(_ contentID: String, context: SourceActionContext) async throws -> ContentLocalPreference
    func setContentLocalPreference(_ value: Bool?, contentID: String, contentType: String,
                                   context: SourceActionContext) async throws -> ContentLocalPreference
}

extension APIClient: ContentLocalPreferenceAPI {
    func contentLocalPreference(_ contentID: String, context: SourceActionContext) async throws -> ContentLocalPreference {
        try requireSourceContext(context)
        let path = "/api/users/\(Self.segment(context.profileID))/preferences/content/\(Self.segment(contentID))"
        let data: Data
        do { data = try await sendOriginalSourceAction(context.request("GET", path: path)) }
        catch let error as APIError where error.statusCode == 404 {
            try requireSourceContext(context)
            return ContentLocalPreference(contentId: nil, preferLocalFiles: nil,
                                          localSourcePreferenceSupported: false)
        }
        try requireSourceContext(context)
        let result = try decoder.decode(ContentLocalPreference.self, from: data)
        if let id = result.contentId, id != contentID.lowercased() {
            throw APIError.notReady("The source preference belongs to another title")
        }
        return result
    }

    func setContentLocalPreference(_ value: Bool?, contentID: String, contentType: String,
                                   context: SourceActionContext) async throws -> ContentLocalPreference {
        try requireSourceContext(context)
        let path = "/api/users/\(Self.segment(context.profileID))/content-preferences/local-source"
        let body = ContentLocalPreference.updateBody(value, contentID: contentID, contentType: contentType)
        // Never fall back to PUT /preferences/content or DELETE the full preference:
        // those would overwrite unrelated language/subtitle settings on old servers.
        let data = try await sendOriginalSourceAction(context.request("PUT", path: path, body: body))
        try requireSourceContext(context)
        let result = try decoder.decode(ContentLocalPreference.self, from: data)
        guard result.supported, result.contentId == contentID.lowercased(), result.preferLocalFiles == value else {
            throw APIError.notReady("The saved source preference could not be confirmed. Reload it before trying again.")
        }
        return result
    }
}
