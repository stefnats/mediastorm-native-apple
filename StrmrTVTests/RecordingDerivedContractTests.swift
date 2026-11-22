import Foundation
import XCTest
@testable import StrmrTV

/// Real Go field sets; media times deliberately differ from capture wall clocks.
/// These tests are source-only until the pinned Mac build is authorized.
@MainActor
enum RecordingDVRFixture {
    static let incarnation = "11111111-1111-4111-8111-111111111111"
    static let artifact = String(repeating: "a", count: 32)
    static let observed = "2026-11-22T11:59:00.123456789Z"
    static let expires = "2026-11-22T13:00:00.123456789Z"
    static func context(_ profile: String = "original", proof: String = "synthetic-original") -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://example.invalid/proxy")!, profileID: profile,
            clientID: "client", sessionToken: "synthetic-session", unlock: proof)
    }
    static func source() throws -> RecordingDerivedSource {
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":"rec","userId":"original","updatedAt":"2026-11-22T11:58:00Z","status":"completed","title":"Synthetic","capture":{"version":1,"phase":"finished","incomplete":false,"sourceChanges":0,"parts":[{"index":1,"startedAt":"2026-11-22T10:00:00Z","endedAt":"2026-11-22T10:10:00Z","endReason":"schedule","bytes":1000,"streamPath":"recording:rec/parts/1"},{"index":2,"startedAt":"2026-11-22T10:10:00Z","endedAt":"2026-11-22T10:15:00Z","endReason":"schedule","bytes":2000,"streamPath":"recording:rec/parts/2"}],"gaps":[]}}"#.utf8))
        return try RecordingDerivedSource(recording, context: context())
    }
    static var spans: [[String: Any]] {
        [["partIndex": 1, "startMs": 0, "durationMs": 20_000], ["partIndex": 2, "startMs": 20_000, "durationMs": 40_000]]
    }
    static func descriptor() -> [String: Any] {
        ["recordingId": "rec", "state": "ready", "id": artifact, "durationMs": 60_000, "bytes": 4096,
         "sourceStatus": "completed", "sourceIncomplete": false, "gapsOmitted": false, "partOffsets": spans,
         "observedAt": observed, "expiresAt": expires]
    }
    static func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes, .sortedKeys]) }
    static func raw(_ value: [String: Any], date: String = "Sun, 22 Nov 2026 12:00:00 GMT") throws -> RecordingObservedData {
        let received = ContinuousClock.now
        return RecordingObservedData(data: try data(value), date: date, started: received.advanced(by: .milliseconds(-10)), received: received, budgetMS: 15_000)
    }
    static func observation() throws -> RecordingDerivedObservation {
        let source = try Self.source(), raw = try Self.raw(descriptor())
        return try RecordingDerivedObservation(source: source, descriptor: RecordingDerivedDescriptor.decode(raw.data, source: source), clock: raw.clock())
    }
    static func identity(_ original: RecordingDerivedObservation) throws -> [String: Any] {
        ["recordingId": "rec", "incarnation": incarnation, "artifactId": artifact,
         "mappingSha256": try RecordingProgressWire.mapping(original, incarnation: incarnation), "durationMs": 60_000]
    }
    static func snapshot(_ original: RecordingDerivedObservation, revision: String = "0", generation: String = "0", position: Int64? = nil,
                         history: Bool = false, historical: Int64? = nil) throws -> RecordingProgressSnapshot {
        try RecordingProgressSnapshot(original: original, raw: raw(snapshotFields(original, revision: revision, generation: generation, position: position,
            history: history, historical: historical)), history: history)
    }
    static func snapshotFields(_ original: RecordingDerivedObservation, revision: String = "0", generation: String = "0", position: Int64? = nil,
                               history: Bool = false, historical: Int64? = nil) throws -> [String: Any] {
        let d = original.descriptor
        var timeline: [String: Any] = ["schemaVersion": 1, "recordingId": "rec", "state": "known", "coordinateSystem": "derived-media",
            "incarnation": incarnation, "artifactId": artifact, "mappingRevision": try RecordingProgressWire.mapping(original, incarnation: incarnation),
            "durationMs": 60_000, "spans": spans, "sourceStatus": "completed", "sourceIncomplete": false, "gapsOmitted": false]
        timeline["observedAt"] = d.observedAt; timeline["expiresAt"] = d.expiresAt
        var progress = try identity(original)
        progress["validUntil"] = "2026-11-22T12:00:29Z"; progress["revision"] = revision; progress["writerGeneration"] = generation
        progress["positionState"] = position == nil ? "none" : "matching"
        if let position { progress["positionMs"] = position; progress["atDerivedEnd"] = position == 60_000 }
        if history { progress["historyState"] = historical == nil ? "absent" : "compatible" }
        if let historical { progress["historicalPositionMs"] = historical; progress["historicalAtDerivedEnd"] = historical == 60_000 }
        return ["schemaVersion": 1, "timeline": timeline, "progress": progress]
    }
    static func result(_ command: RecordingProgressCommand, position: Int64? = nil, revision: Int64? = nil, generation: Int64? = nil) throws -> RecordingProgressReceipt {
        var value = try identity(command.original)
        let actual = position ?? command.expectedPositionMs
        value["validUntil"] = "2026-11-22T12:00:29Z"; value["positionMs"] = actual; value["atDerivedEnd"] = actual == 60_000
        value["revision"] = String(try revision ?? command.revision.next())
        value["writerGeneration"] = String(try generation ?? (command.action == "touch" ? command.writerGeneration.value : command.writerGeneration.next()))
        value["operationId"] = "22222222-2222-4222-8222-222222222222"
        return try RecordingProgressReceipt(command: command, raw: raw(["schemaVersion": 1, "result": value]))
    }
    static func receipt(position: Int64 = 0) throws -> RecordingProgressReceipt {
        let original = try observation(), snapshot = try Self.snapshot(original, position: position)
        return try result(RecordingProgressCommand.claim(snapshot, action: "resume"))
    }
}

@MainActor
final class RecordingDerivedContractTests: XCTestCase {
    func testActualGoDescriptorPreservesMeasuredSpansAndNanoseconds() throws {
        let value = try RecordingDVRFixture.observation()
        XCTAssertEqual(value.descriptor.durationMs, 60_000)
        XCTAssertEqual(value.descriptor.partOffsets.map(\.durationMs), [20_000, 40_000])
        XCTAssertEqual(value.descriptor.observedAt, RecordingDVRFixture.observed)
        XCTAssertTrue(value.ready())
        XCTAssertEqual(try RecordingProgressWire.mapping(value, incarnation: RecordingDVRFixture.incarnation), "47641160c63772f05ba6252fc8be7921010977e1f47bcca050aafaeadf7d6ae7")
    }
    func testCanonicalInt64CountersNeverPassThroughDouble() throws {
        let value = try RecordingProgressCounter("9007199254740993")
        XCTAssertEqual(value.wire, "9007199254740993")
        XCTAssertEqual(try value.next(), 9_007_199_254_740_994)
        for raw in ["", "00", "01", "-1", "1.0", "1e2", "9223372036854775808"] { XCTAssertThrowsError(try RecordingProgressCounter(raw)) }
        XCTAssertThrowsError(try RecordingProgressCounter("9223372036854775807").next())
    }
    func testDuplicateEscapedDuplicateNullAndFractionalIntegersAreRejected() {
        for raw in [#"{"revision":"1","revision":"2"}"#, #"{"revision":"1","\u0072evision":"2"}"#,
                    #"{"durationMs":1.5}"#, #"{"durationMs":null}"#, #"{"durationMs":01}"#,
                    #"{"durationMs":9223372036854775808}"#, #"{}{}"#] {
            XCTAssertThrowsError(try RecordingJSON.parse(Data(raw.utf8)))
        }
    }
    func testUnknownDescriptorHasNoFabricatedReadyIdentity() throws {
        var fields = RecordingDVRFixture.descriptor()
        for key in ["id", "durationMs", "bytes", "observedAt", "expiresAt"] { fields[key] = nil }
        fields["state"] = "unknown"; fields["reason"] = "not_prepared"; fields["partOffsets"] = []
        let source = try RecordingDVRFixture.source(), raw = try RecordingDVRFixture.raw(fields)
        let value = try RecordingDerivedObservation(source: source, descriptor: RecordingDerivedDescriptor.decode(raw.data, source: source), clock: raw.clock())
        XCTAssertFalse(value.ready()); XCTAssertNil(value.descriptor.durationMs)
        fields["durationMs"] = 60_000
        XCTAssertThrowsError(try RecordingDerivedDescriptor.decode(RecordingDVRFixture.data(fields), source: source))
    }
    func testActualOffsetsMustBeContiguousCompleteAndExactlyMeasured() throws {
        let source = try RecordingDVRFixture.source()
        for part in [["partIndex": 2, "startMs": 19_999, "durationMs": 40_000], ["partIndex": 3, "startMs": 20_000, "durationMs": 40_000],
                     ["partIndex": 2, "startMs": 20_000, "durationMs": 0]] {
            var fields = RecordingDVRFixture.descriptor(); fields["partOffsets"] = [RecordingDVRFixture.spans[0], part]
            XCTAssertThrowsError(try RecordingDerivedDescriptor.decode(RecordingDVRFixture.data(fields), source: source))
        }
    }
    func testClockUsesResponseDateAndRTTAndDoesNotExtendSameArtifact() throws {
        let first = try RecordingDVRFixture.observation()
        let raw = try RecordingDVRFixture.raw(RecordingDVRFixture.descriptor())
        let next = try RecordingDerivedObservation(source: first.source, descriptor: first.descriptor, clock: raw.clock(), previous: first)
        XCTAssertLessThanOrEqual(try XCTUnwrap(next.deadline), try XCTUnwrap(first.deadline))
        XCTAssertFalse(first.ready(now: try XCTUnwrap(first.deadline)))
        XCTAssertThrowsError(try RecordingDVRFixture.raw([:], date: "").clock())
        XCTAssertThrowsError(try RecordingWire.utc("2026-02-30T12:00:00Z"))
        XCTAssertThrowsError(try RecordingWire.utc("2026-11-22T12:00:00.120Z"))
        XCTAssertNoThrow(try RecordingWire.utc("2026-11-22T12:00:00.999999999Z"))
    }
    func testRealURLSessionConfigurationSetsResourceRatherThanOnlyIdleTimeout() {
        for seconds in [15, 330] {
            let value = RecordingBoundedRequest.configuration(seconds: seconds)
            XCTAssertEqual(value.timeoutIntervalForResource, TimeInterval(seconds))
            XCTAssertEqual(value.timeoutIntervalForRequest, TimeInterval(seconds))
            XCTAssertNil(value.urlCache); XCTAssertNil(value.httpCookieStorage); XCTAssertFalse(value.waitsForConnectivity)
        }
    }
    func testActualProgressRequestHasNoSelectorQueryAndClaimPositionIsZero() throws {
        let original = try RecordingDVRFixture.observation(), snapshot = try RecordingDVRFixture.snapshot(original, position: 7000)
        let command = try RecordingProgressCommand.claim(snapshot, action: "resume")
        let request = try APIClient.recordingProgressRequest(original, command: command)
        XCTAssertEqual(request.url?.path, "/proxy/api/live/recordings/rec/progress"); XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Unlock"), "synthetic-original")
        let body = try RecordingJSON.parse(XCTUnwrap(request.httpBody)).objectValue
        XCTAssertEqual(try body.number("positionMs"), 0); XCTAssertEqual(command.expectedPositionMs, 7000)
        XCTAssertEqual(try body.text("expectedRevision"), "0")
        let history = try APIClient.recordingProgressRequest(original, history: true)
        XCTAssertEqual(history.url?.query, "includeHistory=true"); XCTAssertNil(history.httpBody)
        let media = try APIClient.recordingDerivedMediaRequest(original)
        XCTAssertEqual(media.url?.path, "/proxy/api/live/recordings/rec/derived/\(RecordingDVRFixture.artifact)/stream")
        XCTAssertFalse(media.url?.absoluteString.contains("synthetic") ?? true)
        let join = try APIClient.recordingDerivedRequest(original.source, prepare: true)
        XCTAssertEqual(join.httpMethod, "POST"); XCTAssertNil(join.httpBody)
        XCTAssertNil(join.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(join.url?.path, "/proxy/api/live/recordings/rec/derived/join")
        XCTAssertEqual(join.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session")
    }
    func testClaimIsOneAttemptAndReceiptIsOnePlayerOnly() throws {
        let original = try RecordingDVRFixture.observation(), snapshot = try RecordingDVRFixture.snapshot(original, revision: "9007199254740993", generation: "9007199254740993", position: 7000)
        let command = try RecordingProgressCommand.claim(snapshot, action: "resume")
        try command.beginAttempt(); XCTAssertThrowsError(try command.beginAttempt())
        let receipt = try RecordingDVRFixture.result(command)
        XCTAssertEqual(receipt.revision.wire, "9007199254740994"); XCTAssertEqual(receipt.positionMs, 7000)
        try receipt.assignPlayer(); XCTAssertThrowsError(try receipt.assignPlayer())
        XCTAssertThrowsError(try RecordingDVRFixture.result(command, position: 0))
        XCTAssertThrowsError(try RecordingDVRFixture.result(command, revision: 1))
    }
    func testHistoryResumeOnlyUsesExplicitCompatibleServerPosition() throws {
        let original = try RecordingDVRFixture.observation(), snapshot = try RecordingDVRFixture.snapshot(original, history: true, historical: 12_345)
        XCTAssertNil(snapshot.positionMs)
        let command = try RecordingProgressCommand.claim(snapshot, action: "resume-history")
        XCTAssertEqual(command.positionMs, 0); XCTAssertEqual(try RecordingDVRFixture.result(command).positionMs, 12_345)
        XCTAssertThrowsError(try RecordingProgressCommand.claim(snapshot, action: "resume"))
    }
    func testActualSnapshotRejectsNumericCounterWrongTimelineAndUnverifiablePosition() throws {
        let original = try RecordingDVRFixture.observation()
        for (key, replacement) in [("revision", 1 as Any), ("writerGeneration", "01" as Any), ("mappingSha256", String(repeating: "f", count: 64) as Any),
                                   ("durationMs", 60_001 as Any), ("positionMs", 60_001 as Any), ("atDerivedEnd", true as Any),
                                   ("validUntil", "2026-11-22T12:01:00Z" as Any)] {
            var root = try RecordingDVRFixture.snapshotFields(original, position: 7000)
            var value = try XCTUnwrap(root["progress"] as? [String: Any]); value[key] = replacement; root["progress"] = value
            XCTAssertThrowsError(try RecordingProgressSnapshot(original: original, raw: RecordingDVRFixture.raw(root), history: false), key)
        }
        var root = try RecordingDVRFixture.snapshotFields(original)
        var timeline = try XCTUnwrap(root["timeline"] as? [String: Any])
        timeline["mappingRevision"] = String(repeating: "f", count: 64); root["timeline"] = timeline
        XCTAssertThrowsError(try RecordingProgressSnapshot(original: original, raw: RecordingDVRFixture.raw(root), history: false))
    }
}
