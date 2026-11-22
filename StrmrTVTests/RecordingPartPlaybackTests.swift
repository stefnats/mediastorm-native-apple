import XCTest
@testable import StrmrTV

@MainActor
final class RecordingPartPlaybackTests: XCTestCase {
    private func context(_ profile: String = "original", proof: String = "synthetic-original") -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://example.invalid/proxy")!, profileID: profile,
                            clientID: "client", sessionToken: "synthetic-session", unlock: proof)
    }
    private func recording(active: Bool = false, bytes: Int = 4096, updated: String = "2026-11-22T12:00:00Z") throws -> Recording {
        let end = active ? "" : ",\"endedAt\":\"2026-11-22T10:10:00Z\",\"endReason\":\"schedule\""
        return try JSONDecoder().decode(Recording.self, from: Data("""
        {"id":"rec","userId":"original","updatedAt":"\(updated)","status":"\(active ? "running" : "completed")","title":"Synthetic",
         "outputPath":"part-000001.ts","capture":{"version":1,"phase":"\(active ? "capturing" : "finished")","incomplete":false,"sourceChanges":0,
         "parts":[{"index":1,"startedAt":"2026-11-22T10:00:00Z","bytes":\(bytes),"streamPath":"recording:rec/parts/1","sourceId":"source-one"\(end)}],"gaps":[]}}
        """.utf8))
    }
    private func changed(_ value: Recording, replacing old: String, with new: String) throws -> Recording {
        // Fixtures are rebuilt from the same actual Go field set, never a second source model.
        let active = value.status == .running
        let end = active ? "" : ",\"endedAt\":\"2026-11-22T10:10:00Z\",\"endReason\":\"schedule\""
        let raw = """
        {"id":"rec","userId":"original","updatedAt":"2026-11-22T12:00:00Z","status":"\(active ? "running" : "completed")","title":"Synthetic",
         "outputPath":"part-000001.ts","capture":{"version":1,"phase":"\(active ? "capturing" : "finished")","incomplete":false,"sourceChanges":0,
         "parts":[{"index":1,"startedAt":"2026-11-22T10:00:00Z","bytes":4096,"streamPath":"recording:rec/parts/1","sourceId":"source-one"\(end)}],"gaps":[]}}
        """
        return try JSONDecoder().decode(Recording.self, from: Data(raw.replacingOccurrences(of: old, with: new).utf8))
    }

    private final class API: RecordingSourceAPI {
        var context: SourceActionContext
        var value: Recording
        var calls = 0
        var hold = false
        var pending: CheckedContinuation<Recording, Never>?
        init(context: SourceActionContext, value: Recording) { self.context = context; self.value = value }
        func sourceContext() -> SourceActionContext { context }
        func recording(_ id: String, context: SourceActionContext) async throws -> Recording {
            calls += 1
            if hold { return await withCheckedContinuation { pending = $0 } }
            return value
        }
        func finish() { let callback = pending; pending = nil; callback?.resume(returning: value) }
    }
    private func until(_ predicate: () -> Bool) async {
        for _ in 0..<1000 where !predicate() { await Task.yield() }
    }

    func testExplicitPartRequestUsesActualSelectorAndOriginalHeaders() throws {
        let source = try RecordingPlaybackSource.part(recording(), index: 1, context: context())
        let request = try source.partRequest()
        XCTAssertEqual(request.url?.path, "/proxy/api/live/recordings/rec/stream")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.filter { $0.name == "part" }.map(\.value), ["1"])
        XCTAssertEqual(query?.filter { $0.name == "profileId" }.map(\.value), ["original"])
        XCTAssertNil(query?.first { $0.name == "token" })
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Unlock"), "synthetic-original")
        XCTAssertThrowsError(try RecordingPlaybackSource.part(recording(), index: 2, context: context()))
    }

    func testPresentCaptureNeverAcquiresLegacyWholeSelection() throws {
        XCTAssertThrowsError(try RecordingPlaybackSource.legacy(recording(), context: context()))
        let legacy = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":"legacy","status":"running","outputPath":"legacy.ts"}"#.utf8))
        XCTAssertEqual(try RecordingPlaybackSource.legacy(legacy, context: context()).kind, .legacyGrowing)
    }

    func testActualConsumedGuardReadsFreshOriginalSourceBeforeOpen() async throws {
        let value = try recording(), original = context(), api = API(context: original, value: value)
        let guardValue = RecordingSourceGuard(try .part(value, index: 1, context: original), api: api)
        try await guardValue.validateForOpen()
        XCTAssertEqual(api.calls, 1)
        api.value = try changed(value, replacing: "source-one", with: "source-two")
        do { try await guardValue.validateForOpen(); XCTFail("Changed part was adopted") } catch {}
        XCTAssertEqual(api.calls, 2)
    }

    func testQueuedOldProfileAndRenewedProofCannotDemandAsReplacement() async throws {
        let value = try recording(), original = context(), api = API(context: context("replacement"), value: value)
        let guardValue = RecordingSourceGuard(try .part(value, index: 1, context: original), api: api)
        do { try await guardValue.validateForOpen(); XCTFail("Old profile demanded") } catch {}
        api.context = context(proof: "new-proof")
        do { try await guardValue.validateForOpen(); XCTFail("Old proof adopted new proof") } catch {}
        XCTAssertEqual(api.calls, 0)
    }

    func testClosedPlayerRejectsMaskedLateCaptureGET() async throws {
        let value = try recording(), original = context(), api = API(context: original, value: value)
        api.hold = true
        let guardValue = RecordingSourceGuard(try .part(value, index: 1, context: original), api: api)
        let work = Task { try await guardValue.validateForOpen() }
        await until { api.pending != nil }
        XCTAssertNotNil(api.pending)
        guardValue.close()
        api.finish()
        do { try await work.value; XCTFail("Closed player adopted late read") } catch {}
        XCTAssertEqual(api.calls, 1)
    }

    func testSingleActivePartRetainsExactGrowingIdentityAcrossFreshByteGrowth() async throws {
        let value = try recording(active: true), original = context(), api = API(context: original, value: value)
        let source = try RecordingPlaybackSource.singleActive(value, context: original)
        let guardValue = RecordingSourceGuard(source, api: api)
        try await guardValue.validateForOpen()
        api.value = try recording(active: true, bytes: 8192, updated: "2026-11-22T12:01:00Z")
        try await guardValue.validateForOpen()
        XCTAssertEqual(api.calls, 2, "Every open/reopen re-reads the actual current single part")
        let request = try source.growingRequest()
        XCTAssertEqual(request.url?.path, "/proxy/api/video/hls/start")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "path" }?.value, "recording:rec/parts/1")
        XCTAssertFalse(value.playableParts.contains { $0.index == 1 }, "Active bytes are not a completed part")
    }

    func testSingleActiveGuardRejectsNewPartGapRestoreOrSourceChangeBeforeReopen() async throws {
        let value = try recording(active: true), original = context()
        for replacement in [
            try changed(value, replacing: "source-one", with: "source-two"),
            try changed(value, replacing: "\"sourceChanges\":0", with: "\"sourceChanges\":1"),
            try changed(value, replacing: "\"version\":1", with: "\"version\":2"),
            try changed(value, replacing: "\"phase\":\"capturing\"", with: "\"phase\":\"capturing\",\"restored\":true"),
            try changed(value, replacing: "\"gaps\":[]", with: "\"gaps\":[{\"startedAt\":\"2026-11-22T10:00:00Z\",\"reason\":\"capacity\"}]"),
            try changed(value, replacing: "\"parts\":[", with: "\"parts\":[{\"index\":2,\"startedAt\":\"2026-11-22T10:01:00Z\",\"bytes\":1},"),
            try recording(active: false)
        ] {
            let api = API(context: original, value: replacement)
            let guardValue = RecordingSourceGuard(try .singleActive(value, context: original), api: api)
            do { try await guardValue.validateForOpen(); XCTFail("Active source changed but reopening continued") } catch {}
            XCTAssertEqual(api.calls, 1)
        }
    }

    func testSingleActivePartCannotUseAChangedOrUnknownStreamIdentity() throws {
        let value = try recording(active: true)
        for replacement in [try changed(value, replacing: "recording:rec/parts/1", with: "recording:other/parts/1"),
                            try changed(value, replacing: "\"bytes\":4096", with: "\"bytes\":0"),
                            try changed(value, replacing: "\"startedAt\":\"2026-11-22T10:00:00Z\"", with: "\"startedAt\":\"unknown\"")] {
            XCTAssertThrowsError(try RecordingPlaybackSource.singleActive(replacement, context: context()))
        }
    }
}
