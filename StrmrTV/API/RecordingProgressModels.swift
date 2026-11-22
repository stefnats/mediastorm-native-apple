import CryptoKit
import Foundation

struct RecordingProgressCounter: Equatable {
    let value: Int64
    var wire: String { String(value) }
    init(_ raw: String) throws {
        guard let value = Int64(raw), value >= 0, String(value) == raw else { throw RecordingDataError.unavailable }
        self.value = value
    }
    func next() throws -> Int64 {
        let (value, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw RecordingDataError.unavailable }; return value
    }
}

struct RecordingProgressIdentity: Equatable {
    let recordingId: String
    let incarnation: String
    let artifactId: String
    let mappingSha256: String
    let durationMs: Int64

    init(_ value: [String: RecordingJSON]) throws {
        recordingId = try value.text("recordingId"); incarnation = try value.text("incarnation")
        artifactId = try value.text("artifactId"); mappingSha256 = try value.text("mappingSha256")
        durationMs = try value.number("durationMs")
        try RecordingWire.uuid(incarnation)
        try RecordingWire.check(recordingId.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil &&
            RecordingWire.hex(artifactId, count: 32) && RecordingWire.hex(mappingSha256, count: 64) && (1...43_200_000).contains(durationMs))
    }
}

enum RecordingProgressWire {
    static func mapping(_ original: RecordingDerivedObservation, incarnation: String) throws -> String {
        try RecordingWire.uuid(incarnation)
        let d = original.descriptor
        guard let id = d.id, let duration = d.durationMs, let bytes = d.bytes, let observed = d.observedAt,
              let expires = d.expiresAt else { throw RecordingDataError.unavailable }
        let tuple: RecordingJSON = .array([.text("recording-derived-timeline/v1"), .text(d.recordingId), .text(incarnation),
            .text(id), .number(duration), .number(bytes), .text(d.sourceStatus), .flag(d.sourceIncomplete), .flag(d.gapsOmitted),
            .text(observed), .text(expires), .array(d.partOffsets.map(\.tuple))])
        let raw = try JSONSerialization.data(withJSONObject: tuple.foundation, options: [.withoutEscapingSlashes])
        return SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }
    static func deadline(_ original: RecordingDerivedObservation, until: String, clock: RecordingResponseClock) throws -> ContinuousClock.Instant {
        guard original.ready(), let expires = original.descriptor.expiresAt, let limit = original.deadline else { throw RecordingDataError.unavailable }
        try RecordingWire.check(try RecordingWire.utc(until) <= RecordingWire.utc(expires))
        try RecordingWire.check(clock.serverDateMS >= original.clock.serverDateMS)
        let deadline = try min(limit, clock.deadline(until, maximumMS: 30_000))
        try RecordingWire.check(ContinuousClock.now < deadline)
        return deadline
    }
    static func timeline(_ original: RecordingDerivedObservation, value: [String: RecordingJSON], clock: RecordingResponseClock) throws -> RecordingProgressIdentity {
        try value.exact(["schemaVersion", "recordingId", "state", "coordinateSystem", "incarnation", "artifactId", "mappingRevision", "durationMs", "spans", "sourceStatus", "sourceIncomplete", "gapsOmitted", "observedAt", "expiresAt"])
        let d = original.descriptor
        try RecordingWire.check(try value.number("schemaVersion") == 1 && value.text("state") == "known" && value.text("coordinateSystem") == "derived-media")
        try RecordingWire.check(try value.text("recordingId") == d.recordingId && value.text("artifactId") == d.id && value.number("durationMs") == d.durationMs)
        try RecordingWire.check(try value.text("sourceStatus") == d.sourceStatus && value.flag("sourceIncomplete") == d.sourceIncomplete && value.flag("gapsOmitted") == d.gapsOmitted)
        try RecordingWire.check(try value.text("observedAt") == d.observedAt && value.text("expiresAt") == d.expiresAt)
        guard let observed = d.observedAt else { throw RecordingDataError.unavailable }
        try RecordingWire.check(try ceil(RecordingWire.utc(observed)) <= clock.upperAtReceiptMS)
        let spans = try value.field("spans").arrayValue
        try RecordingWire.check(spans.count == d.partOffsets.count)
        for (index, raw) in spans.enumerated() {
            let span = try raw.objectValue; try span.exact(["partIndex", "startMs", "durationMs"])
            let expected = d.partOffsets[index]
            try RecordingWire.check(try span.number("partIndex") == expected.partIndex && span.number("startMs") == expected.startMs && span.number("durationMs") == expected.durationMs)
        }
        let incarnation = try value.text("incarnation"), hash = try mapping(original, incarnation: incarnation)
        try RecordingWire.check(try value.text("mappingRevision") == hash)
        var identity = value
        identity["mappingSha256"] = .text(hash)
        return try RecordingProgressIdentity(identity)
    }
}

final class RecordingProgressSnapshot {
    let original: RecordingDerivedObservation
    let identity: RecordingProgressIdentity
    let revision: RecordingProgressCounter
    let writerGeneration: RecordingProgressCounter
    let positionState: String
    let positionMs: Int64?
    let historyState: String?
    let historicalPositionMs: Int64?
    let deadline: ContinuousClock.Instant
    func adoptable(now: ContinuousClock.Instant = .now) -> Bool { original.ready(now: now) && now < deadline }

    init(original: RecordingDerivedObservation, raw: RecordingObservedData, history: Bool) throws {
        let root = try RecordingJSON.parse(raw.data).objectValue
        try root.exact(["schemaVersion", "timeline", "progress"])
        try RecordingWire.check(try root.number("schemaVersion") == 1)
        let clock = try raw.clock()
        let identity = try RecordingProgressWire.timeline(original, value: root.field("timeline").objectValue, clock: clock)
        let value = try root.field("progress").objectValue
        let positionState = try value.text("positionState")
        try RecordingWire.check(["none", "matching", "conflict"].contains(positionState))
        let historyState: String? = history ? try value.text("historyState") : nil
        try RecordingWire.check(!history || ["absent", "unverifiable", "compatible"].contains(historyState ?? ""))
        var keys: Set<String> = ["validUntil", "recordingId", "incarnation", "artifactId", "mappingSha256", "durationMs", "revision", "writerGeneration", "positionState"]
        if positionState == "matching" { keys.formUnion(["positionMs", "atDerivedEnd"]) }
        if history { keys.insert("historyState") }
        if historyState == "compatible" { keys.formUnion(["historicalPositionMs", "historicalAtDerivedEnd"]) }
        try value.exact(keys)
        try RecordingWire.check(try RecordingProgressIdentity(value) == identity)
        let positionMs: Int64? = positionState == "matching" ? try value.number("positionMs") : nil
        let historicalPositionMs: Int64? = historyState == "compatible" ? try value.number("historicalPositionMs") : nil
        if let positionMs { try Self.position(value, key: "atDerivedEnd", position: positionMs, duration: identity.durationMs) }
        if let historicalPositionMs { try Self.position(value, key: "historicalAtDerivedEnd", position: historicalPositionMs, duration: identity.durationMs) }
        let revision = try RecordingProgressCounter(value.text("revision"))
        let writerGeneration = try RecordingProgressCounter(value.text("writerGeneration"))
        let deadline = try RecordingProgressWire.deadline(original, until: value.text("validUntil"), clock: clock)
        self.original = original; self.identity = identity; self.positionState = positionState
        self.historyState = historyState; self.positionMs = positionMs; self.historicalPositionMs = historicalPositionMs
        self.revision = revision; self.writerGeneration = writerGeneration; self.deadline = deadline
    }
    private static func position(_ value: [String: RecordingJSON], key: String, position: Int64, duration: Int64) throws {
        try RecordingWire.check(try (0...duration).contains(position) && value.flag(key) == (position == duration))
    }
}

/// A local one-attempt command. The backend independently checks authorization and CAS.
@MainActor
final class RecordingProgressCommand {
    let original: RecordingDerivedObservation
    let identity: RecordingProgressIdentity
    let revision: RecordingProgressCounter
    let writerGeneration: RecordingProgressCounter
    let action: String
    let positionMs: Int64
    let expectedPositionMs: Int64
    private var attempted = false
    private init(original: RecordingDerivedObservation, identity: RecordingProgressIdentity, revision: RecordingProgressCounter,
                 generation: RecordingProgressCounter, action: String, position: Int64, expected: Int64) {
        self.original = original; self.identity = identity; self.revision = revision; writerGeneration = generation
        self.action = action; positionMs = position; expectedPositionMs = expected
    }
    static func claim(_ snapshot: RecordingProgressSnapshot, action: String) throws -> RecordingProgressCommand {
        guard snapshot.adoptable() else { throw RecordingDataError.unavailable }
        let expected: Int64
        switch action {
        case "from-start": expected = 0
        case "resume": guard let value = snapshot.positionMs, snapshot.positionState == "matching" else { throw RecordingDataError.unavailable }; expected = value
        case "resume-history": guard let value = snapshot.historicalPositionMs, snapshot.historyState == "compatible" else { throw RecordingDataError.unavailable }; expected = value
        default: throw RecordingDataError.unavailable
        }
        return Self(original: snapshot.original, identity: snapshot.identity, revision: snapshot.revision,
            generation: snapshot.writerGeneration, action: action, position: 0, expected: expected)
    }
    static func touch(_ previous: RecordingProgressReceipt, position: Int64) throws -> RecordingProgressCommand {
        guard previous.original.ready(), (0...previous.identity.durationMs).contains(position) else { throw RecordingDataError.unavailable }
        return Self(original: previous.original, identity: previous.identity, revision: previous.revision,
            generation: previous.writerGeneration, action: "touch", position: position, expected: position)
    }
    func beginAttempt() throws {
        guard !attempted, original.ready() else { throw RecordingDataError.unavailable }
        _ = try revision.next()
        if action != "touch" { _ = try writerGeneration.next() }
        attempted = true
    }
    func body() -> [String: Any] {
        ["action": action, "expectedRevision": revision.wire, "writerGeneration": writerGeneration.wire,
         "incarnation": identity.incarnation, "artifactId": identity.artifactId, "mappingSha256": identity.mappingSha256,
         "durationMs": identity.durationMs, "positionMs": positionMs]
    }
}

@MainActor
final class RecordingProgressReceipt {
    let original: RecordingDerivedObservation
    let identity: RecordingProgressIdentity
    let revision: RecordingProgressCounter
    let writerGeneration: RecordingProgressCounter
    let positionMs: Int64
    let operationId: String
    let deadline: ContinuousClock.Instant
    private var assigned = false
    func adoptable(now: ContinuousClock.Instant = .now) -> Bool { original.ready(now: now) && now < deadline }
    func assignPlayer() throws {
        guard !assigned, adoptable() else { throw RecordingDataError.unavailable }; assigned = true
    }
    init(command: RecordingProgressCommand, raw: RecordingObservedData) throws {
        let root = try RecordingJSON.parse(raw.data).objectValue
        try root.exact(["schemaVersion", "result"]); try RecordingWire.check(try root.number("schemaVersion") == 1)
        let value = try root.field("result").objectValue
        try value.exact(["validUntil", "recordingId", "incarnation", "artifactId", "mappingSha256", "durationMs", "positionMs", "atDerivedEnd", "revision", "writerGeneration", "operationId"])
        let identity = try RecordingProgressIdentity(value)
        try RecordingWire.check(identity == command.identity)
        let revision = try RecordingProgressCounter(value.text("revision")); let writerGeneration = try RecordingProgressCounter(value.text("writerGeneration"))
        try RecordingWire.check(try revision.value == command.revision.next() && writerGeneration.value == (command.action == "touch" ? command.writerGeneration.value : command.writerGeneration.next()))
        let positionMs = try value.number("positionMs")
        try RecordingWire.check(try positionMs == command.expectedPositionMs && (0...identity.durationMs).contains(positionMs) && value.flag("atDerivedEnd") == (positionMs == identity.durationMs))
        let operationId = try value.text("operationId"); try RecordingWire.uuid(operationId)
        let deadline = try RecordingProgressWire.deadline(command.original, until: value.text("validUntil"), clock: raw.clock())
        original = command.original; self.identity = identity; self.revision = revision
        self.writerGeneration = writerGeneration; self.positionMs = positionMs; self.operationId = operationId; self.deadline = deadline
    }
}
