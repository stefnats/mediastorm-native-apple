import Foundation

struct SourceFilters: Codable, Hashable {
    var basis = "candidate"
    var unknown = "include"
    var audioLanguage: String?
    var subtitleLanguage: String?
    var claimedResolutionAtLeast: String?
    var heightAtLeast: Int?
    var videoCodec: String?
    var dynamicRange: String?
    var audioCodec: String?
    var audioDescription: Bool?
    var active: Bool { audioLanguage != nil || subtitleLanguage != nil || claimedResolutionAtLeast != nil || heightAtLeast != nil || videoCodec != nil || dynamicRange != nil || audioCodec != nil || audioDescription != nil }
    func validated() throws -> Self {
        guard ["candidate", "probed"].contains(basis), ["include", "exclude"].contains(unknown),
              audioLanguage == nil || MediaFilterValues.language(audioLanguage!) == audioLanguage,
              subtitleLanguage == nil || MediaFilterValues.language(subtitleLanguage!) == subtitleLanguage,
              MediaFilterValues.codec(videoCodec), MediaFilterValues.codec(audioCodec),
              dynamicRange == nil || MediaFilterValues.ranges.contains(dynamicRange!), audioDescription != false,
              heightAtLeast == nil || (144...8640).contains(heightAtLeast!),
              basis != "candidate" || (heightAtLeast == nil && audioCodec == nil && audioDescription == nil),
              basis != "probed" || claimedResolutionAtLeast == nil else { throw SourceFilterFailure.invalid }
        if let value = claimedResolutionAtLeast {
            guard value.hasSuffix("p"), let height = Int(value.dropLast()), (144...8640).contains(height), value == "\(height)p" else { throw SourceFilterFailure.invalid }
        }
        return self
    }
    mutating func chooseBasis(_ basis: String) {
        self.basis = basis
        if basis == "candidate" { heightAtLeast = nil; audioCodec = nil; audioDescription = nil }
        else { claimedResolutionAtLeast = nil }
    }
    func body() throws -> [String: Any] {
        _ = try validated(); return try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
    }
}

struct SourceFilterTarget: Codable, Hashable {
    struct EpisodeTarget: Codable, Hashable {
        let episodeId: String
        let seasonNumber: Int
        let episodeNumber: Int
        let numbering: EpisodeNumbering?
    }
    let titleId: String
    let mediaType: String
    let episode: EpisodeTarget?
    init(title: DetailsTarget, episode: Episode?) {
        titleId = title.titleID; mediaType = title.isMovie ? "movie" : "series"
        self.episode = title.isMovie ? nil : episode.map {
            EpisodeTarget(episodeId: $0.id, seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber,
                numbering: $0.numbering.map { EpisodeNumbering(seriesId: $0.seriesId, ordering: $0.ordering?.isEmpty == false ? $0.ordering : nil) })
        }
    }
    @MainActor
    func validate() throws {
        _ = try SourceFilterWire.text(titleId)
        guard ["movie", "series"].contains(mediaType) else { throw SourceFilterFailure.invalid }
        if let episode {
            guard mediaType == "series", (0...10_000).contains(episode.seasonNumber), (1...100_000).contains(episode.episodeNumber) else { throw SourceFilterFailure.invalid }
            _ = try SourceFilterWire.text(episode.episodeId)
            if let numbering = episode.numbering {
                _ = try SourceFilterWire.text(numbering.seriesId)
                if let order = numbering.ordering { guard order.count <= 128 else { throw SourceFilterFailure.invalid }; _ = try SourceFilterWire.text(order) }
            }
        }
    }
}

struct SourceFilterEvidence: Equatable {
    let candidateVersion: String
    let sourceVersion: String
    let probed: Bool
    static func parse(_ value: Any?, candidate: String? = nil) -> Self? {
        guard let object = value as? [String: Any], (object["version"] as? Int) == 1,
              let source = object["sourceVersion"] as? String,
              let version = object["candidateVersion"] as? String,
              SourceFilterWire.version(version, prefix: "candidate_v1_"), candidate == nil || candidate == version else { return nil }
        let probed = object["probed"] is [String: Any]
        guard SourceFilterWire.version(source, prefix: probed ? "file_v1_" : "candidate_v1_"), probed || source == version else { return nil }
        return Self(candidateVersion: version, sourceVersion: source, probed: probed)
    }
}

final class SourceFilterRow: Identifiable {
    let result: SourceResult
    let verdict: String
    let evidence: SourceFilterEvidence?
    var id: Int { result.index }
    init(result: SourceResult, verdict: String, evidence: SourceFilterEvidence?) { self.result = result; self.verdict = verdict; self.evidence = evidence }
}
struct SourceFilterCoverage: Codable, Equatable { let retainedCandidates: Int; let truncated: Bool }
struct SourceFilterPage {
    let snapshotId: String
    let viewId: String
    let expiresAt: Date
    let target: SourceFilterTarget
    let filters: SourceFilters
    let rows: [SourceFilterRow]
    let total: Int
    let matchedTotal: Int
    let unknownTotal: Int
    let coverage: SourceFilterCoverage
    let nextCursor: String?
    let sourceHealthToken: String?
}
enum SourceFilterReply { case legacy([SourceFilterRow]), supported(SourceFilterPage) }
enum SourceFilterFailure: LocalizedError, Equatable {
    case invalid, changed, expired
    var errorDescription: String? {
        switch self {
        case .invalid: "Source filter data could not be read. Reload the source list."
        case .changed: "Source metadata changed. Apply the filters again."
        case .expired: "Source results expired or changed. Reload the source list."
        }
    }
}

@MainActor
enum SourceFilterWire {
    static func text(_ value: Any?) throws -> String {
        let value = try StoredMediaWire.text(value); guard value.count <= 1024 else { throw SourceFilterFailure.invalid }; return value
    }
    nonisolated static func version(_ value: String, prefix: String) -> Bool { value.range(of: "^" + prefix + "[0-9a-f]{64}$", options: .regularExpression) != nil }
    static func initial(_ data: Data) throws -> SourceFilterReply {
        guard data.count <= 8_388_608 else { throw SourceFilterFailure.invalid }
        let value = try JSONSerialization.jsonObject(with: data)
        if let array = value as? [Any] {
            return .legacy(array.enumerated().compactMap { index, raw in (raw as? [String: Any]).flatMap { SourceResult($0, index: index) }.map { SourceFilterRow(result: $0, verdict: "unfiltered", evidence: nil) } })
        }
        return .supported(try page(value))
    }
    static func page(_ value: Any) throws -> SourceFilterPage {
        let object = try StoredMediaWire.object(value)
        guard try StoredMediaWire.integer(object["sourceFiltersVersion"]) == 1 else { throw SourceFilterFailure.invalid }
        let snapshot = try text(object["snapshotId"]), view = try text(object["viewId"])
        let expiry = try StoredMediaWire.date(object["expiresAt"])
        guard let rawTarget = object["target"], let rawFilters = object["filters"], let rawCoverage = object["coverage"] else { throw SourceFilterFailure.invalid }
        let target = try StoredMediaWire.decode(SourceFilterTarget.self, rawTarget); try target.validate()
        let filters = try StoredMediaWire.decode(SourceFilters.self, rawFilters).validated()
        let coverage = try StoredMediaWire.decode(SourceFilterCoverage.self, rawCoverage)
        guard (0...512).contains(coverage.retainedCandidates) else { throw SourceFilterFailure.invalid }
        let total = try StoredMediaWire.integer(object["total"]), matched = try StoredMediaWire.integer(object["matchedTotal"]), unknown = try StoredMediaWire.integer(object["unknownTotal"])
        guard [total, matched, unknown].allSatisfy({ $0 <= coverage.retainedCandidates }), matched + unknown <= coverage.retainedCandidates,
              !filters.active || total == matched + (filters.unknown == "include" ? unknown : 0),
              filters.active || total == coverage.retainedCandidates,
              let array = object["rows"] as? [[String: Any]], array.count <= 100, array.count <= total,
              !array.isEmpty || total == 0 else { throw SourceFilterFailure.invalid }
        let rows = try array.map { raw -> SourceFilterRow in
            let index = try StoredMediaWire.integer(raw["sourceIndex"]), candidate = try text(raw["candidateVersion"])
            guard index < coverage.retainedCandidates, version(candidate, prefix: "candidate_v1_"), let resultRaw = raw["result"] as? [String: Any],
                  let result = SourceResult(resultRaw, index: index, snapshotID: snapshot, candidateVersion: candidate) else { throw SourceFilterFailure.invalid }
            let verdict = try text(raw["verdict"])
            guard ["unfiltered", "match", "unknown"].contains(verdict), filters.active ? verdict != "unfiltered" : verdict == "unfiltered",
                  !(filters.active && filters.unknown == "exclude" && verdict == "unknown") else { throw SourceFilterFailure.invalid }
            return SourceFilterRow(result: result, verdict: verdict, evidence: SourceFilterEvidence.parse(raw["mediaEvidence"], candidate: candidate))
        }
        guard Set(rows.map(\.id)).count == rows.count else { throw SourceFilterFailure.invalid }
        func optional(_ key: String) throws -> String? { guard let value = object[key], !(value is NSNull) else { return nil }; return try text(value) }
        return SourceFilterPage(snapshotId: snapshot, viewId: view, expiresAt: Date(timeIntervalSince1970: expiry / 1000), target: target, filters: filters, rows: rows,
            total: total, matchedTotal: matched, unknownTotal: unknown, coverage: coverage, nextCursor: try optional("nextCursor"), sourceHealthToken: try optional("sourceHealthToken"))
    }
}
