import Foundation

enum RecordingDataError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Current recording data is unavailable. Read status or progress explicitly." }
}

/// A bounded JSON reader retains duplicate-key and exact integer errors.
indirect enum RecordingJSON: Equatable {
    case object([String: RecordingJSON]), array([RecordingJSON]), text(String), number(Int64), flag(Bool)

    static func parse(_ data: Data) throws -> RecordingJSON {
        guard data.count <= 65_536 else { throw RecordingDataError.unavailable }
        var reader = Reader(bytes: Array(data))
        let value = try reader.value(depth: 0)
        reader.space()
        guard reader.at == reader.bytes.count else { throw RecordingDataError.unavailable }
        return value
    }
    var objectValue: [String: RecordingJSON] {
        get throws { guard case let .object(value) = self else { throw RecordingDataError.unavailable }; return value }
    }
    var arrayValue: [RecordingJSON] {
        get throws { guard case let .array(value) = self else { throw RecordingDataError.unavailable }; return value }
    }
    var stringValue: String {
        get throws { guard case let .text(value) = self, !value.isEmpty else { throw RecordingDataError.unavailable }; return value }
    }
    var integerValue: Int64 {
        get throws { guard case let .number(value) = self else { throw RecordingDataError.unavailable }; return value }
    }
    var boolValue: Bool {
        get throws { guard case let .flag(value) = self else { throw RecordingDataError.unavailable }; return value }
    }
    var foundation: Any {
        switch self {
        case let .object(value): value.mapValues(\.foundation)
        case let .array(value): value.map(\.foundation)
        case let .text(value): value
        case let .number(value): NSNumber(value: value)
        case let .flag(value): value
        }
    }
    private struct Reader {
        let bytes: [UInt8]
        var at = 0
        mutating func space() { while at < bytes.count, [9, 10, 13, 32].contains(bytes[at]) { at += 1 } }
        mutating func take(_ byte: UInt8) throws { space(); guard at < bytes.count, bytes[at] == byte else { throw RecordingDataError.unavailable }; at += 1 }
        mutating func string() throws -> String {
            space(); let start = at; try take(34); var escaped = false
            while at < bytes.count {
                let c = bytes[at]; at += 1
                if !escaped, c == 34 {
                    let value = try JSONDecoder().decode(String.self, from: Data(bytes[start..<at]))
                    guard value.utf8.count <= 2048, value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw RecordingDataError.unavailable }
                    return value
                }
                escaped = !escaped && c == 92
            }
            throw RecordingDataError.unavailable
        }
        mutating func value(depth: Int) throws -> RecordingJSON {
            space(); guard depth <= 4, at < bytes.count else { throw RecordingDataError.unavailable }
            if bytes[at] == 123 {
                at += 1; var result: [String: RecordingJSON] = [:]; space()
                if at < bytes.count, bytes[at] == 125 { at += 1; return .object(result) }
                while true {
                    let key = try string()
                    guard result[key] == nil, result.count < 24 else { throw RecordingDataError.unavailable }
                    try take(58); result[key] = try value(depth: depth + 1); space()
                    guard at < bytes.count else { throw RecordingDataError.unavailable }
                    let separator = bytes[at]; at += 1
                    if separator == 125 { return .object(result) }
                    guard separator == 44 else { throw RecordingDataError.unavailable }
                }
            }
            if bytes[at] == 91 {
                at += 1; var result: [RecordingJSON] = []; space()
                if at < bytes.count, bytes[at] == 93 { at += 1; return .array(result) }
                while true {
                    guard result.count < 256 else { throw RecordingDataError.unavailable }
                    result.append(try value(depth: depth + 1)); space()
                    guard at < bytes.count else { throw RecordingDataError.unavailable }
                    let separator = bytes[at]; at += 1
                    if separator == 93 { return .array(result) }
                    guard separator == 44 else { throw RecordingDataError.unavailable }
                }
            }
            if bytes[at] == 34 { return .text(try string()) }
            let start = at
            while at < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[at]) { at += 1 }
            let token = String(decoding: bytes[start..<at], as: UTF8.self)
            if token == "true" { return .flag(true) }
            if token == "false" { return .flag(false) }
            guard let number = Int64(token), number >= 0, String(number) == token else { throw RecordingDataError.unavailable }
            return .number(number)
        }
    }
}

extension Dictionary where Key == String, Value == RecordingJSON {
    func exact(_ names: Set<String>) throws { guard Set(keys) == names else { throw RecordingDataError.unavailable } }
    func field(_ name: String) throws -> RecordingJSON { guard let value = self[name] else { throw RecordingDataError.unavailable }; return value }
    func text(_ name: String) throws -> String { try field(name).stringValue }
    func number(_ name: String) throws -> Int64 { try field(name).integerValue }
    func flag(_ name: String) throws -> Bool { try field(name).boolValue }
}

enum RecordingWire {
    static func check(_ condition: Bool) throws { guard condition else { throw RecordingDataError.unavailable } }
    static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func uuid(_ value: String) throws {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value,
              value != "00000000-0000-0000-0000-000000000000" else { throw RecordingDataError.unavailable }
    }
    static func utc(_ raw: String) throws -> Double {
        guard raw.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"#, options: .regularExpression) != nil,
              !raw.hasSuffix("0Z") || !raw.contains("."), let date = RecordingCapture.date(String(raw.prefix(19)) + "Z") else { throw RecordingDataError.unavailable }
        let whole = DateFormatter()
        whole.locale = Locale(identifier: "en_US_POSIX"); whole.timeZone = TimeZone(secondsFromGMT: 0)
        whole.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard whole.string(from: date) == String(raw.prefix(19)), !raw.hasPrefix("0000") else { throw RecordingDataError.unavailable }
        let fraction = raw.contains(".") ? Double("0." + raw.dropFirst(20).dropLast()) ?? 0 : 0
        return date.timeIntervalSince1970 * 1000 + fraction * 1000
    }
    static func milliseconds(_ value: Duration) -> Double {
        let c = value.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }
}

/// Immutable response receipt anchor; no device wall clock is consulted.
struct RecordingResponseClock {
    let upperAtReceiptMS: Double
    let received: ContinuousClock.Instant
    let serverDateMS: Double

    init(date: String, started: ContinuousClock.Instant, received: ContinuousClock.Instant, budgetMS: Int) throws {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        format.isLenient = false
        guard let value = format.date(from: date), format.string(from: value) == date else { throw RecordingDataError.unavailable }
        guard received >= started else { throw RecordingDataError.unavailable }
        let rtt = ceil(RecordingWire.milliseconds(started.duration(to: received))) + 1
        guard rtt >= 1, rtt <= Double(budgetMS) else { throw RecordingDataError.unavailable }
        self.received = received
        serverDateMS = value.timeIntervalSince1970 * 1000
        upperAtReceiptMS = serverDateMS + 1000 + rtt
    }
    func deadline(_ expires: String, maximumMS: Double) throws -> ContinuousClock.Instant {
        let remaining = floor(try RecordingWire.utc(expires)) - upperAtReceiptMS
        guard remaining > 0, remaining <= maximumMS else { throw RecordingDataError.unavailable }
        return received.advanced(by: .milliseconds(Int64(remaining)))
    }
}

struct RecordingDerivedSource: Equatable {
    let recording: Recording
    let context: SourceActionContext
    init(_ recording: Recording, context: SourceActionContext) throws {
        guard recording.id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil,
              recording.userId == context.profileID, [.completed, .failed, .cancelled].contains(recording.status),
              recording.updatedAt.flatMap(RecordingCapture.date) != nil,
              let capture = recording.capture, capture.supported, !capture.restored,
              ["finished", "interrupted"].contains(capture.phase), (2...256).contains(capture.parts.count),
              recording.playableParts.count == capture.parts.count,
              recording.playableParts.enumerated().allSatisfy({ $0.element.index == $0.offset + 1 }),
              capture.gaps.allSatisfy({ $0.endedAt != nil && ["source_retry", "capacity"].contains($0.reason) }) else { throw RecordingDataError.unavailable }
        let parts = recording.playableParts
        for index in 1..<parts.count {
            guard let end = parts[index - 1].endedAt.flatMap(RecordingCapture.date),
                  let start = RecordingCapture.date(parts[index].startedAt), start >= end else { throw RecordingDataError.unavailable }
            if start.timeIntervalSince(end) > 0.25 {
                guard capture.gaps.contains(where: { gap in
                    guard let a = RecordingCapture.date(gap.startedAt), let b = gap.endedAt.flatMap(RecordingCapture.date) else { return false }
                    return a.timeIntervalSince(end) <= 0.25 && start.timeIntervalSince(b) <= 0.25
                }) else { throw RecordingDataError.unavailable }
            }
        }
        self.recording = recording; self.context = context
    }
}

struct RecordingDerivedDescriptor: Equatable {
    struct Span: Equatable {
        let partIndex: Int64
        let startMs: Int64
        let durationMs: Int64
        var tuple: RecordingJSON { .array([.number(partIndex), .number(startMs), .number(durationMs)]) }
    }
    let recordingId: String
    let state: String
    let sourceStatus: String
    let sourceIncomplete: Bool
    let gapsOmitted: Bool
    let partOffsets: [Span]
    let reason: String?
    let id: String?
    let durationMs: Int64?
    let bytes: Int64?
    let observedAt: String?
    let expiresAt: String?

    static func decode(_ data: Data, source: RecordingDerivedSource) throws -> Self {
        let root = try RecordingJSON.parse(data).objectValue
        let state = try root.text("state")
        let common: Set<String> = ["recordingId", "state", "sourceStatus", "sourceIncomplete", "gapsOmitted", "partOffsets"]
        try root.exact(common.union(state == "unknown" ? ["reason"] : ["id", "durationMs", "bytes", "observedAt", "expiresAt"]))
        let id = try root.text("recordingId"), status = try root.text("sourceStatus")
        let incomplete = try root.flag("sourceIncomplete"), gaps = try root.flag("gapsOmitted")
        try RecordingWire.check(id == source.recording.id && status == source.recording.status.rawValue && (!gaps || incomplete))
        try RecordingWire.check(source.recording.capture?.incomplete != true || incomplete)
        let parts = try root.field("partOffsets").arrayValue
        if state == "unknown" {
            let reason = try root.text("reason")
            try RecordingWire.check(parts.isEmpty && ["not_prepared", "configuration_changed", "source_changed", "expired"].contains(reason))
            return Self(recordingId: id, state: state, sourceStatus: status, sourceIncomplete: incomplete, gapsOmitted: gaps,
                partOffsets: [], reason: reason, id: nil, durationMs: nil, bytes: nil, observedAt: nil, expiresAt: nil)
        }
        let artifact = try root.text("id"), duration = try root.number("durationMs"), bytes = try root.number("bytes")
        try RecordingWire.check(state == "ready" && RecordingWire.hex(artifact, count: 32) && (1...43_200_000).contains(duration) && (1...17_179_869_184).contains(bytes) && parts.count == source.recording.capture?.parts.count)
        try RecordingWire.check(source.recording.capture?.gaps.isEmpty == true || incomplete && gaps)
        var end: Int64 = 0
        let spans = try parts.enumerated().map { index, raw -> Span in
            let p = try raw.objectValue; try p.exact(["partIndex", "startMs", "durationMs"])
            let span = Span(partIndex: try p.number("partIndex"), startMs: try p.number("startMs"), durationMs: try p.number("durationMs"))
            try RecordingWire.check(span.partIndex == Int64(index + 1) && span.startMs == end && (1...43_200_000).contains(span.durationMs))
            end += span.durationMs; return span
        }
        let observed = try root.text("observedAt"), expires = try root.text("expiresAt")
        let lifetime = try RecordingWire.utc(expires) - RecordingWire.utc(observed)
        try RecordingWire.check(end == duration && lifetime > 0 && lifetime <= 86_400_000)
        return Self(recordingId: id, state: state, sourceStatus: status, sourceIncomplete: incomplete, gapsOmitted: gaps,
            partOffsets: spans, reason: nil, id: artifact, durationMs: duration, bytes: bytes, observedAt: observed, expiresAt: expires)
    }
}

/// Descriptor identity and receipt lifetime only, never source or writer authority.
final class RecordingDerivedObservation {
    let source: RecordingDerivedSource
    let descriptor: RecordingDerivedDescriptor
    let clock: RecordingResponseClock
    let deadline: ContinuousClock.Instant?
    init(source: RecordingDerivedSource, descriptor: RecordingDerivedDescriptor, clock: RecordingResponseClock,
         previous: RecordingDerivedObservation? = nil) throws {
        self.source = source; self.descriptor = descriptor; self.clock = clock
        if descriptor.state == "ready", let observed = descriptor.observedAt, let expires = descriptor.expiresAt {
            try RecordingWire.check(try ceil(RecordingWire.utc(observed)) <= clock.upperAtReceiptMS)
            let current = try clock.deadline(expires, maximumMS: 86_400_000)
            if let previous {
                try RecordingWire.check(clock.serverDateMS >= previous.clock.serverDateMS)
                deadline = previous.descriptor.id == descriptor.id ? min(current, previous.deadline ?? current) : current
            } else { deadline = current }
        } else { deadline = nil }
    }
    func ready(now: ContinuousClock.Instant = .now) -> Bool { descriptor.state == "ready" && deadline.map { now < $0 } == true }
}
