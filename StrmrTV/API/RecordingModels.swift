import Foundation

/// A Live TV recording from `/api/live/recordings` (the Expo app's `Recording`).
struct Recording: Decodable, Identifiable, Hashable {
    enum Status: String, Decodable {
        case pending, starting, running, completed, cancelled, failed, unknown

        init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// The Expo TV list's status labels.
        var label: String {
            switch self {
            case .pending: String(localized: "Scheduled")
            case .starting: String(localized: "Starting")
            case .running: String(localized: "Recording")
            case .completed: String(localized: "Completed")
            case .cancelled: String(localized: "Cancelled")
            case .failed, .unknown: String(localized: "Failed")
            }
        }
    }

    let id: String
    let ruleId: String?
    let status: Status
    let channelId: String
    let tvgId: String?
    let channelName: String
    let title: String
    let description: String?
    let startAt: Date
    let endAt: Date
    let paddingAfterSeconds: Int?
    let outputPath: String?
    let outputSizeBytes: Int64?
    let actualStartAt: Date?
    let error: String?
    let userId: String?
    /// Keep the original server spelling for source-observation comparison.
    let updatedAt: String?
    let capturePresent: Bool
    let capture: RecordingCapture?

    private enum CodingKeys: String, CodingKey {
        case id, ruleId, status, channelId, tvgId, channelName, title, description, startAt, endAt,
             paddingAfterSeconds, outputPath, outputSizeBytes, actualStartAt, error, userId, updatedAt, capture
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ruleId = try c.decodeIfPresent(String.self, forKey: .ruleId)
        status = try c.decode(Status.self, forKey: .status)
        channelId = try c.decodeIfPresent(String.self, forKey: .channelId) ?? ""
        tvgId = try c.decodeIfPresent(String.self, forKey: .tvgId)
        channelName = try c.decodeIfPresent(String.self, forKey: .channelName) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        startAt = try Self.date(c, .startAt) ?? .distantPast
        endAt = try Self.date(c, .endAt) ?? .distantPast
        paddingAfterSeconds = try c.decodeIfPresent(Int.self, forKey: .paddingAfterSeconds)
        outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath)
        outputSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .outputSizeBytes)
        actualStartAt = try Self.date(c, .actualStartAt)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        // A present but unsupported descriptor is never a legacy whole file.
        // Keep the rest of the recording list usable when this field is malformed.
        capturePresent = c.contains(.capture)
        capture = try? c.decode(RecordingCapture.self, forKey: .capture)
    }

    /// RFC 3339, with or without fractional seconds.
    private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date? {
        guard let text = try c.decodeIfPresent(String.self, forKey: key), !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // MARK: What the Expo TV screen offers

    /// A file to play: completed, still recording, or stopped / failed part way.
    var canPlay: Bool {
        if capturePresent { return !playableParts.isEmpty || singleActivePart != nil }
        return !(outputPath ?? "").isEmpty && [.completed, .running, .cancelled, .failed].contains(status)
    }

    var singleActivePart: RecordingCapture.Part? {
        guard capturePresent, status == .running, let capture, capture.supported, !capture.restored,
              capture.phase == "capturing", capture.parts.count == 1, capture.gaps.isEmpty,
              let part = capture.parts.first, part.index == 1, part.bytes > 0,
              part.endedAt == nil, part.endReason == nil || part.endReason == "",
              part.streamPath == "recording:\(id)/parts/1" else { return nil }
        return part
    }

    var playableParts: [RecordingCapture.Part] {
        guard capturePresent, let capture, capture.supported, !capture.restored,
              [.completed, .running, .cancelled, .failed].contains(status) else { return [] }
        return capture.parts.filter { $0.playable(recordingID: id) }.sorted { $0.index < $1.index }
    }

    var captureNotice: String? {
        guard capturePresent else { return nil }
        guard let capture, capture.supported else {
            return String(localized: "Capture details are unavailable. No complete file or playable timeline is assumed.")
        }
        if capture.restored { return String(localized: "Restored capture observations require current server validation. Refresh before playing a part.") }
        if capture.incomplete || !capture.gaps.isEmpty || capture.parts.count > 1 {
            return String(localized: "Incomplete or separate capture parts. Each part plays independently from its beginning; capture gaps are not playable media time.")
        }
        return String(localized: "Captured parts are separate files. No movie or episode watched status is written.")
    }

    /// Cancel a scheduled recording, or stop one in progress.
    var canCancel: Bool { [.pending, .starting, .running].contains(status) }

    /// Everything but a scheduled recording a recurring rule made (the rule owns those).
    var canDelete: Bool { !(ruleId != nil && status == .pending) }

    /// When the recording stops, padding included: a growing file keeps growing until then.
    var stopsAt: Date { endAt.addingTimeInterval(TimeInterval(paddingAfterSeconds ?? 0)) }

    /// The programme title, else the one in the file name (`Channel - 2026-10-22 1900-2000 - Title.ts`),
    /// else the channel (Expo's `resolveRecordingTitle`).
    var displayTitle: String {
        let channel = Self.clean(channelName).isEmpty ? String(localized: "Recording") : Self.clean(channelName)
        let raw = Self.clean(title)
        if !raw.isEmpty, raw != channel { return raw }
        if let name = outputPath?.split(separator: "/").last.map(String.init) {
            let stem = name.replacingOccurrences(of: #"\.[^.]+$"#, with: "", options: .regularExpression)
            for pattern in [#"^.+ - \d{4}-\d{2}-\d{2} \d{4}-\d{4} - (.+)$"#, #"^.+ - \d{4}-\d{2}-\d{2} \d{4} - (.+)$"#] {
                guard let match = stem.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
                let derived = Self.clean(String(stem[match]).replacingOccurrences(
                    of: pattern, with: "$1", options: [.regularExpression, .caseInsensitive]))
                if !derived.isEmpty, derived != channel { return derived }
            }
        }
        return raw.isEmpty ? channel : raw
    }

    /// The error worth showing (a paused or removed rule's cancellations aren't).
    var visibleError: String? {
        guard let error, !error.isEmpty, error != "recording rule paused",
              !error.hasPrefix("cancelled because the recording rule") else { return nil }
        return error
    }

    /// "45m", "1h 30m", "2h" (Expo's `formatDuration`).
    var durationText: String {
        let minutes = Int((endAt.timeIntervalSince(startAt) / 60).rounded())
        guard minutes > 0 else { return "" }
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 > 0 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes / 60)h"
    }

    var sizeText: String? {
        guard let bytes = outputSizeBytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Capture observations are not a continuous media timeline or seek map.
struct RecordingCapture: Decodable, Hashable {
    struct Part: Decodable, Hashable, Identifiable {
        let index: Int
        let startedAt: String
        let endedAt: String?
        let bytes: Int64
        let endReason: String?
        let streamPath: String?
        let sourceId: String?
        let channelId: String?
        var id: Int { index }

        func playable(recordingID: String) -> Bool {
            guard let endedAt, let start = RecordingCapture.date(startedAt), let end = RecordingCapture.date(endedAt) else { return false }
            return (1...256).contains(index) && bytes > 0 && end >= start &&
                ["schedule", "source_ended", "capture_failed", "cancelled", "shutdown", "restart"].contains(endReason ?? "") &&
                streamPath == "recording:\(recordingID)/parts/\(index)"
        }

        var label: String { String(localized: "Play part \(index) from beginning") }
    }
    struct Gap: Decodable, Hashable {
        let startedAt: String
        let endedAt: String?
        let reason: String

        var label: String {
            let start = RecordingCapture.date(startedAt)?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Unknown start")
            let end = endedAt.flatMap(RecordingCapture.date)?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Unconfirmed end")
            return String(localized: "Capture gap (wall clock): \(start) to \(end). Reason: \(reason)")
        }
    }
    let version: Int
    let phase: String
    let incomplete: Bool
    let sourceChanges: Int
    let parts: [Part]
    let gaps: [Gap]
    let restored: Bool

    private enum CodingKeys: String, CodingKey { case version, phase, incomplete, sourceChanges, parts, gaps, restored }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        phase = try c.decode(String.self, forKey: .phase)
        incomplete = try c.decode(Bool.self, forKey: .incomplete)
        sourceChanges = try c.decode(Int.self, forKey: .sourceChanges)
        parts = try c.decode([Part].self, forKey: .parts)
        gaps = try c.decode([Gap].self, forKey: .gaps)
        restored = try c.decodeIfPresent(Bool.self, forKey: .restored) ?? false
    }
    var supported: Bool {
        guard version == 1, ["capturing", "waiting_capacity", "finished", "interrupted"].contains(phase),
              (0...256).contains(sourceChanges), parts.count <= 256, gaps.count <= 256,
              Set(parts.map(\.index)).count == parts.count else { return false }
        return parts.allSatisfy { part in
            guard (1...256).contains(part.index), part.bytes >= 0, let start = Self.date(part.startedAt) else { return false }
            return part.endedAt.map { Self.date($0).map { $0 >= start } ?? false } ?? true
        } && gaps.allSatisfy { gap in
            guard ["source_retry", "capacity", "access_changed"].contains(gap.reason), let start = Self.date(gap.startedAt) else { return false }
            return gap.endedAt.map { Self.date($0).map { $0 >= start } ?? false } ?? true
        }
    }
    static func date(_ text: String) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"#, options: .regularExpression) != nil else { return nil }
        if let value = try? Date(text, strategy: .iso8601) { return value }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// The Expo TV screen's filters.
enum RecordingFilter: String, CaseIterable, Identifiable {
    case all, upcoming, recording, completed, history

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .upcoming: String(localized: "Upcoming")
        case .recording: String(localized: "Recording")
        case .completed: String(localized: "Completed")
        case .history: String(localized: "History")
        }
    }

    /// The filter's empty state (Expo's "No recording recordings" read badly).
    var emptyText: String {
        switch self {
        case .all: String(localized: "No recordings")
        case .upcoming: String(localized: "Nothing scheduled")
        case .recording: String(localized: "Nothing recording right now")
        case .completed: String(localized: "No completed recordings")
        case .history: String(localized: "No failed or cancelled recordings")
        }
    }

    func matches(_ recording: Recording) -> Bool {
        switch self {
        case .all: true
        case .upcoming: recording.status == .pending
        case .recording: recording.status == .starting || recording.status == .running
        case .completed: recording.status == .completed
        case .history: [.failed, .cancelled, .unknown].contains(recording.status)
        }
    }
}

struct RecordingsResponse: Decodable {
    let recordings: [Recording]?
}

/// `GET /api/video/hls/start` for a recording.
struct RecordingHLSStart: Decodable {
    let sessionId: String?
    let playlistUrl: String?
    let growing: Bool?
}

/// `POST /api/video/hls/{id}/keepalive`: `growing` while the server follows the file.
struct RecordingHLSKeepAlive: Decodable {
    let growing: Bool?
    let duration: Double?
}
