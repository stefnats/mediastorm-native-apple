import Foundation

/// An observed search result, never playback/PIN permission or a release date.
struct SourceAvailability: Decodable, Hashable, Sendable {
    let state: String
    let checkedAt: String?
    let expiresAt: String?
    let providers: [String]
    let complete: Bool
    let reason: String?
    let sourceType: String?
    let episodeCoverage: SourceEpisodeCoverage?
    private enum CodingKeys: String,CodingKey { case state,checkedAt,expiresAt,providers,complete,reason,sourceType,episodeCoverage }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        state = try c.decodeIfPresent(String.self,forKey:.state) ?? "unknown"
        checkedAt = try c.decodeIfPresent(String.self,forKey:.checkedAt)
        expiresAt = try c.decodeIfPresent(String.self,forKey:.expiresAt)
        providers = c.contains(.providers) ? try c.decode([String].self,forKey:.providers) : []
        complete = try c.decodeIfPresent(Bool.self,forKey:.complete) ?? false
        reason = try c.decodeIfPresent(String.self,forKey:.reason)
        sourceType = try c.decodeIfPresent(String.self,forKey:.sourceType)
        episodeCoverage = try c.decodeIfPresent(SourceEpisodeCoverage.self,forKey:.episodeCoverage)
        guard providers.count <= 64, providers.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              reason.map({$0.utf8.count <= 1024}) ?? true else { throw SourceHintFailure.invalid }
    }
    func fresh(at now: Date) -> Bool {
        guard let checkedAt, let expiresAt, let checked = RecordingCapture.date(checkedAt),
              let expiry = RecordingCapture.date(expiresAt) else { return false }
        return checked <= now && now < expiry && expiry > checked && expiry.timeIntervalSince(checked) <= 86_400
    }
    func presentation(at now: Date = .now, inLibrary: Bool = false) -> SourceHintPresentation {
        var kind = SourceHintPresentation.Kind.unknown
        let interval = checkedAt.flatMap(RecordingCapture.date).flatMap { start in expiresAt.flatMap(RecordingCapture.date).map{$0.timeIntervalSince(start)} }
        let aggregateLocal = sourceType == "local" && providers.isEmpty &&
            ["episode_candidates","partial_episode_candidates"].contains(reason ?? "") &&
            (episodeCoverage?.foundEpisodes ?? 0) > 0 && (interval.map{$0 <= 120} ?? false)
        if fresh(at:now), reason?.hasPrefix("recheck_") != true {
            if state == "found", episodeCoverage?.state == "partial", sourceType == nil || aggregateLocal { kind = .partial }
            else if state == "found", aggregateLocal { kind = .candidate }
            else if state == "not_found", episodeCoverage != nil { kind = .unknown }
            else if sourceType != nil || reason == "local_file_checked" {
                if state == "found", sourceType == "local", reason == "local_file_checked", providers.isEmpty,
                   interval.map({$0 <= 120}) == true { kind = .local }
            } else if state == "not_found", complete, ["no_matching_candidates","reported_candidates"].contains(reason ?? "") { kind = inLibrary ? .localNeedsChecking : .missing }
            else if state == "found" { kind = .candidate }
        }
        return SourceHintPresentation(kind:kind,reason:reason,checkedAt:checkedAt.flatMap(RecordingCapture.date).flatMap{$0 <= now ? $0 : nil},
            coverage:fresh(at:now) ? episodeCoverage : nil)
    }
}

/// Invalid additive JSON cannot discard an otherwise usable catalogue object.
@propertyWrapper
struct SourceHintField: Decodable, Hashable, Sendable {
    var wrappedValue: SourceAvailability?
    init(wrappedValue: SourceAvailability? = nil) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try? SourceAvailability(from:decoder) }
}
extension KeyedDecodingContainer {
    func decode(_ type: SourceHintField.Type, forKey key: Key) throws -> SourceHintField {
        (try? decodeIfPresent(type,forKey:key)) ?? SourceHintField()
    }
}

struct SourceEpisodeCoverage: Decodable, Hashable, Sendable {
    struct Season: Decodable, Hashable, Sendable {
        let seasonNumber: Int
        let state: String
        let foundEpisodes: Int
        let notFoundEpisodes: Int
        let unknownEpisodes: Int
        var valid: Bool {
            (0...10_000).contains(seasonNumber) && SourceEpisodeCoverage.validCounts(state,foundEpisodes,notFoundEpisodes,unknownEpisodes)
        }
    }
    let state: String
    let foundEpisodes: Int
    let notFoundEpisodes: Int
    let unknownEpisodes: Int
    let catalogueComplete: Bool
    let seasons: [Season]
    private enum CodingKeys: String,CodingKey { case state,foundEpisodes,notFoundEpisodes,unknownEpisodes,catalogueComplete,seasons }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        state = try c.decode(String.self,forKey:.state)
        foundEpisodes = try c.decode(Int.self,forKey:.foundEpisodes)
        notFoundEpisodes = try c.decode(Int.self,forKey:.notFoundEpisodes)
        unknownEpisodes = try c.decode(Int.self,forKey:.unknownEpisodes)
        catalogueComplete = try c.decode(Bool.self,forKey:.catalogueComplete)
        seasons = try c.decode([Season].self,forKey:.seasons)
        guard !catalogueComplete, Self.validCounts(state,foundEpisodes,notFoundEpisodes,unknownEpisodes),
              seasons.count <= 1012, seasons.allSatisfy(\.valid), Set(seasons.map(\.seasonNumber)).count == seasons.count,
              seasons.reduce(0,{$0+$1.foundEpisodes}) == foundEpisodes,
              seasons.reduce(0,{$0+$1.notFoundEpisodes}) == notFoundEpisodes,
              seasons.reduce(0,{$0+$1.unknownEpisodes}) == unknownEpisodes else { throw SourceHintFailure.invalid }
    }
    static func validCounts(_ state: String, _ found: Int, _ missing: Int, _ unknown: Int) -> Bool {
        ["unknown","partial"].contains(state) && (0...1012).contains(found) && (0...1012).contains(missing) &&
            (0...1012).contains(unknown) && found+missing+unknown <= 1012 && (state == "partial") == (found > 0 && missing > 0)
    }
}

struct SourceHintPresentation: Equatable {
    enum Kind: Equatable { case unknown,candidate,missing,local,partial,localNeedsChecking }
    let kind: Kind
    let reason: String?
    let checkedAt: Date?
    let coverage: SourceEpisodeCoverage?
    var dimArtwork: Bool { kind == .missing }
    var label: String {
        switch kind {
        case .candidate: String(localized:"Source candidate found")
        case .missing: String(localized:"No matching source")
        case .local: String(localized:"Local file checked")
        case .partial: String(localized:"Partial episode coverage")
        case .localNeedsChecking: String(localized:"Local version needs checking")
        case .unknown:
            switch reason {
            case "recheck_queued": String(localized:"Checking sources")
            case "catalogue_refresh_required": String(localized:"Reload catalogue to check")
            case "audio_track_unverified","audio_not_confirmed": String(localized:"Audio language needs checking")
            default: String(localized:"Source status unknown")
            }
        }
    }
    var explanation: String {
        var parts = [label]
        if let checkedAt { parts.append(String(localized:"Checked \(checkedAt.formatted(date:.abbreviated,time:.shortened))")) }
        if let coverage { parts.append(String(localized:"Observed episodes: \(coverage.foundEpisodes) found, \(coverage.notFoundEpisodes) missing, \(coverage.unknownEpisodes) unknown. Catalogue completeness is not established.")) }
        parts.append(String(localized:"A candidate is not proof of playback. Open details to choose a source."))
        return parts.joined(separator:". ")
    }
}

enum SourceHintFailure: Error, Equatable { case invalid,changed,unsupported }
