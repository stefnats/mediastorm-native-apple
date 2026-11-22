import Foundation

struct SourceTitleCoordinate: Codable, Hashable, Sendable {
    let titleId: String
    let mediaType: String
    init(_ target: DetailsTarget) { titleId = target.titleID; mediaType = target.isMovie ? "movie" : "series" }
    init(titleId: String, mediaType: String) { self.titleId = titleId; self.mediaType = mediaType }
    var valid: Bool { !titleId.isEmpty && titleId.utf8.count <= 128 && ["movie","series"].contains(mediaType) }
}
struct SourceEpisodeCoordinate: Codable, Hashable, Sendable {
    let episodeId: String
    let seasonNumber: Int
    let episodeNumber: Int
    init(_ episode: Episode) { episodeId = episode.id; seasonNumber = episode.seasonNumber; episodeNumber = episode.episodeNumber }
    init(episodeId: String, seasonNumber: Int, episodeNumber: Int) { self.episodeId = episodeId; self.seasonNumber = seasonNumber; self.episodeNumber = episodeNumber }
    var valid: Bool { !episodeId.isEmpty && episodeId.utf8.count <= 1024 && (0...10_000).contains(seasonNumber) && (0...100_000).contains(episodeNumber) }
}
struct SourceTitleHint: Decodable, Hashable, Sendable {
    let titleId: String
    let mediaType: String
    @SourceHintField var sourceAvailability: SourceAvailability?
    var coordinate: SourceTitleCoordinate { .init(titleId:titleId,mediaType:mediaType) }
}
struct SourceEpisodeHint: Decodable, Hashable, Sendable {
    let episodeId: String
    let seasonNumber: Int
    let episodeNumber: Int
    @SourceHintField var sourceAvailability: SourceAvailability?
    var coordinate: SourceEpisodeCoordinate { .init(episodeId:episodeId,seasonNumber:seasonNumber,episodeNumber:episodeNumber) }
}
struct SourceTitleHintsReply: Decodable {
    let enabled: Bool
    let version: Int64
    let items: [SourceTitleHint]
}
struct SourceEpisodeHintsReply: Decodable {
    let enabled: Bool
    let version: Int64
    let items: [SourceEpisodeHint]
    let episodeCoverage: SourceEpisodeCoverage?
}

@MainActor
enum SourceHintsWire {
    static func validView(_ value: String) -> Bool { value.range(of:#"^[A-Za-z0-9_-]{1,64}$"#,options:.regularExpression) != nil }
    static func request(_ context: SourceActionContext, kind: String, view: String, body: [String:Any]) throws -> URLRequest {
        guard ["titles","episodes"].contains(kind), validView(view) else { throw SourceHintFailure.invalid }
        let request = try context.request("PUT",path:"/api/users/\(APIClient.segment(context.profileID))/source-availability/\(kind)/\(view)",body:body)
        guard request.httpBody.map({$0.count <= 32*1024}) == true else { throw SourceHintFailure.invalid }
        return request
    }
    static func titles(_ context: SourceActionContext, view: String, version: Int64, values: [SourceTitleCoordinate]) throws -> URLRequest {
        guard version >= 1, values.count <= 24, Set(values).count == values.count, values.allSatisfy(\.valid) else { throw SourceHintFailure.invalid }
        return try request(context,kind:"titles",view:view,body:["version":version,"titles":values.map{["titleId":$0.titleId,"mediaType":$0.mediaType]}])
    }
    static func episodes(_ context: SourceActionContext, view: String, version: Int64, titleID: String?, numbering: EpisodeNumbering?, values: [SourceEpisodeCoordinate]) throws -> URLRequest {
        guard version >= 1, values.count <= 12, Set(values).count == values.count, Set(values.map(\.episodeId)).count == values.count,
              values.allSatisfy(\.valid) else { throw SourceHintFailure.invalid }
        var body: [String:Any] = ["version":version,"episodes":values.map{["episodeId":$0.episodeId,"seasonNumber":$0.seasonNumber,"episodeNumber":$0.episodeNumber] as [String:Any]}]
        if !values.isEmpty {
            guard let titleID, !titleID.isEmpty, titleID.utf8.count <= 128, let numbering, !numbering.seriesId.isEmpty,
                  numbering.seriesId.utf8.count <= 128, numbering.ordering.map({$0.utf8.count <= 128}) ?? true else { throw SourceHintFailure.invalid }
            body["titleId"] = titleID
            var number = ["seriesId":numbering.seriesId]; number["ordering"] = numbering.ordering
            body["numbering"] = number
        }
        return try request(context,kind:"episodes",view:view,body:body)
    }
    static func titleReply(_ data: Data, version: Int64, requested: [SourceTitleCoordinate]) throws -> SourceTitleHintsReply {
        let value = try JSONDecoder().decode(SourceTitleHintsReply.self,from:data)
        guard value.version == version, value.items.count <= 24, Set(value.items.map(\.coordinate)).count == value.items.count,
              value.enabled ? Set(value.items.map(\.coordinate)) == Set(requested) : value.items.isEmpty else { throw SourceHintFailure.invalid }
        return value
    }
    static func episodeReply(_ data: Data, version: Int64, requested: [SourceEpisodeCoordinate]) throws -> SourceEpisodeHintsReply {
        let value = try JSONDecoder().decode(SourceEpisodeHintsReply.self,from:data)
        guard value.version == version, value.items.count <= 12, Set(value.items.map(\.coordinate)).count == value.items.count,
              value.enabled ? Set(value.items.map(\.coordinate)) == Set(requested) : value.items.isEmpty else { throw SourceHintFailure.invalid }
        return value
    }
}

@MainActor
protocol SourceHintsAPI: AnyObject {
    func isCurrent(_ context: SourceActionContext) -> Bool
    func sourceHints(_ request: URLRequest) async throws -> Data
}
extension APIClient: SourceHintsAPI {
    /// Existing demand may schedule work only under the server's configured
    /// checker. This is deliberately distinct from passive annotation decode.
    func sourceHints(_ request: URLRequest) async throws -> Data { try await sendOriginalSourceAction(request) }
}
