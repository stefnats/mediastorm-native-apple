import XCTest
@testable import StrmrTV

final class RecordingCaptureTests: XCTestCase {
    private func recording(_ capture: String? = nil, status: String = "completed") throws -> Recording {
        let field = capture.map { ",\"capture\":\($0)" } ?? ""
        return try JSONDecoder().decode(Recording.self, from: Data("""
        {"id":"rec","userId":"original","updatedAt":"2026-11-22T12:00:00Z","status":"\(status)",
         "title":"Synthetic recording","outputPath":"part-000001.ts",
         "startAt":"2026-11-22T10:00:00Z","endAt":"2026-11-22T10:20:00Z"\(field)}
        """.utf8))
    }
    private func capture(parts: String? = nil, extras: String = "", phase: String = "finished") -> String {
        let parts = parts ?? """
        [{"index":1,"startedAt":"2026-11-22T10:00:00Z","endedAt":"2026-11-22T10:10:00Z","bytes":4096,"endReason":"source_ended","streamPath":"recording:rec/parts/1"},
         {"index":2,"startedAt":"2026-11-22T10:11:00Z","endedAt":"2026-11-22T10:20:00Z","bytes":8192,"endReason":"schedule","streamPath":"recording:rec/parts/2"}]
        """
        return """
        {"version":1,"phase":"\(phase)","incomplete":true,"sourceChanges":1,"parts":\(parts),
         "gaps":[{"startedAt":"2026-11-22T10:10:00Z","endedAt":"2026-11-22T10:11:00Z","reason":"source_retry"}]\(extras)}
        """
    }

    func testActualCaptureDTOShowsSeparateClosedPartsAndWallClockGap() throws {
        let value = try recording(capture())
        XCTAssertTrue(value.capturePresent)
        XCTAssertEqual(value.userId, "original")
        XCTAssertEqual(value.updatedAt, "2026-11-22T12:00:00Z")
        XCTAssertEqual(value.playableParts.map(\.index), [1, 2])
        XCTAssertEqual(value.capture?.gaps.count, 1)
        XCTAssertTrue(value.capture?.gaps.first?.label.contains("wall clock") == true)
        XCTAssertTrue(value.captureNotice?.contains("independently") == true)
        XCTAssertNil(value.singleActivePart)
    }

    func testByteCountsAndScheduleRemainObservationsNotMediaDuration() throws {
        let value = try recording(capture())
        XCTAssertEqual(value.durationText, "20m", "This is the separately labelled schedule window only")
        XCTAssertEqual(value.playableParts.map(\.bytes), [4096, 8192])
        XCTAssertEqual(value.playableParts[1].streamPath, "recording:rec/parts/2")
        XCTAssertTrue(value.captureNotice?.contains("not playable media time") == true)
    }

    func testUnknownVersionDoesNotFallBackToWholeOutputPath() throws {
        let value = try recording(capture().replacingOccurrences(of: "\"version\":1", with: "\"version\":2"))
        XCTAssertNotNil(value.outputPath)
        XCTAssertFalse(value.canPlay)
        XCTAssertTrue(value.playableParts.isEmpty)
    }

    func testNullMalformedAndMissingCaptureAreDifferent() throws {
        for raw in ["null", "{}", "\"malformed\""] {
            let value = try recording(raw)
            XCTAssertTrue(value.capturePresent)
            XCTAssertNil(value.capture)
            XCTAssertFalse(value.canPlay)
        }
        let legacy = try recording()
        XCTAssertFalse(legacy.capturePresent)
        XCTAssertTrue(legacy.canPlay)
    }

    func testRestoredOrDuplicateLedgerCannotSupplyPlayableParts() throws {
        let restored = try recording(capture(extras: ",\"restored\":true"))
        XCTAssertFalse(restored.canPlay)
        XCTAssertTrue(restored.captureNotice?.contains("Restored") == true)
        let duplicate = try recording(capture().replacingOccurrences(of: "\"index\":2", with: "\"index\":1"))
        XCTAssertFalse(duplicate.canPlay)
    }

    func testEmptyActiveUnknownAndForeignPartsNeverBecomeFinishedFiles() throws {
        let closed = capture()
        for changed in [closed.replacingOccurrences(of: "\"bytes\":4096", with: "\"bytes\":0"),
                        closed.replacingOccurrences(of: "recording:rec/parts/1", with: "recording:foreign/parts/1"),
                        closed.replacingOccurrences(of: "source_ended", with: "unknown_reason")] {
            XCTAssertEqual(try recording(changed).playableParts.map(\.index), [2])
        }
        let reversed = try recording(closed.replacingOccurrences(of: "2026-11-22T10:10:00Z", with: "2026-11-21T10:10:00Z"))
        XCTAssertFalse(reversed.canPlay)
    }

    func testCaptureBoundsAndUnknownPhaseRemainUnsupported() throws {
        for changed in [capture(phase: "future_phase"), capture().replacingOccurrences(of: "\"sourceChanges\":1", with: "\"sourceChanges\":257"),
                        capture().replacingOccurrences(of: "\"index\":2", with: "\"index\":257")] {
            XCTAssertFalse(try recording(changed).canPlay)
        }
    }

    func testTrueLegacyWholeAndGrowingPlaybackStayAvailable() throws {
        for status in ["completed", "cancelled", "failed", "running"] {
            let value = try recording(status: status)
            XCTAssertFalse(value.capturePresent)
            XCTAssertTrue(value.canPlay)
        }
        XCTAssertFalse(try recording(status: "pending").canPlay)
    }
}
