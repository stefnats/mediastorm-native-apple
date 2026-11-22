import XCTest
@testable import StrmrTV

@MainActor
final class KidsLivePlayerTests: XCTestCase {
    private func context(_ profile: String = "child") -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://synthetic.invalid/base")!, profileID: profile,
            clientID: "original-client", sessionToken: "original-session")
    }
    private func reply(direct: Bool = false) throws -> KidsLiveStartReply {
        let raw = #"{"sessionId":"actual-session","playlistUrl":"/video/hls/actual-session/stream.m3u8","programmeEndsAt":"2026-11-22T12:00:00Z","programmeRemainingMillis":1000,"isDirect":DIRECT,"timeshiftWindowSeconds":0,"programme":{"title":"Synthetic programme","startsAt":"2026-11-22T11:30:00Z","endsAt":"2026-11-22T12:00:00Z","age":6,"country":"DE","classificationBasis":"selected_guide_claim","guide":{"id":"selected","type":"xmltv","observedAt":"2026-11-22T11:00:00Z"}}}"#
        return try JSONDecoder().decode(KidsLiveStartReply.self, from: Data(raw.replacingOccurrences(of: "DIRECT", with: String(direct)).utf8))
    }

    private final class API: KidsLiveAPI {
        var context: SourceActionContext
        var pending: CheckedContinuation<KidsLiveStartReply, Error>?
        var channelsPending: CheckedContinuation<[KidsLiveChannel], Error>?
        var result: KidsLiveStartReply
        var hold = false
        var holdChannels = false
        var opened: [SourceActionContext] = []
        var stopped: [(String, SourceActionContext)] = []
        init(context: SourceActionContext, result: KidsLiveStartReply) { self.context = context; self.result = result }
        func sourceContext() -> SourceActionContext { context }
        func isCurrent(_ value: SourceActionContext) -> Bool { value == context }
        func kidsLivePolicy(context: SourceActionContext) async throws -> KidsLivePolicy {
            try JSONDecoder().decode(KidsLivePolicy.self, from: Data(#"{"enabled":true,"country":"DE","maximumAge":6,"guideSourceId":"selected"}"#.utf8))
        }
        func kidsLiveChannels(context: SourceActionContext) async throws -> [KidsLiveChannel] {
            if holdChannels { return try await withCheckedThrowingContinuation { channelsPending = $0 } }
            return []
        }
        func kidsLiveStart(_ id: String, context: SourceActionContext) async throws -> KidsLiveStartReply {
            opened.append(context)
            if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
            return result
        }
        func keepKidsLive(_ session: String, context: SourceActionContext) async throws { }
        func stopKidsLive(_ session: String, context: SourceActionContext) async throws { stopped.append((session, context)) }
        func acknowledge() { pending?.resume(returning: result); pending = nil }
    }

    func testClosingBeforeActualOpenReceiptJoinsAndStopsOnlyOriginalSession() async throws {
        let original = context()
        let api = API(context: original, result: try reply()); api.hold = true
        let operation = KidsLivePlaybackOperation(context: original, api: api, now: { .zero })
        let opening = Task { try await operation.open(channelID: "catalogue-id") }
        for _ in 0..<100 where api.pending == nil { await Task.yield() }
        XCTAssertNotNil(api.pending)
        operation.close()
        var joined = false
        let cleanup = Task { await operation.waitForCleanup(); joined = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(joined)
        XCTAssertTrue(api.stopped.isEmpty)
        api.context = context("other-child")
        api.acknowledge()
        do { _ = try await opening.value; XCTFail("Closed operation adopted late playback") } catch { }
        await cleanup.value
        XCTAssertTrue(joined)
        XCTAssertEqual(api.opened, [original])
        XCTAssertEqual(api.stopped.count, 1)
        XCTAssertEqual(api.stopped.first?.0, "actual-session")
        XCTAssertEqual(api.stopped.first?.1, original)
        operation.close(); await operation.waitForCleanup()
        XCTAssertEqual(api.stopped.count, 1)
    }

    func testChangedProfileDuringOpenCannotAdoptItsLateResponse() async throws {
        let original = context()
        let api = API(context: original, result: try reply()); api.hold = true
        let operation = KidsLivePlaybackOperation(context: original, api: api, now: { .zero })
        let opening = Task { try await operation.open(channelID: "catalogue-id") }
        for _ in 0..<100 where api.pending == nil { await Task.yield() }
        XCTAssertNotNil(api.pending)
        api.context = context("replacement")
        api.acknowledge()
        do { _ = try await opening.value; XCTFail("Changed profile received original programme") } catch { }
        await operation.waitForCleanup()
        XCTAssertEqual(api.opened.count, 1)
        XCTAssertEqual(api.stopped.first?.1, original)
    }

    func testKnownInvalidDirectReceiptIsRetiredWithoutAdultFallbackOrRetry() async throws {
        let original = context()
        let api = API(context: original, result: try reply(direct: true))
        let operation = KidsLivePlaybackOperation(context: original, api: api, now: { .zero })
        do { _ = try await operation.open(channelID: "catalogue-id"); XCTFail("Direct child stream accepted") } catch { }
        await operation.waitForCleanup()
        XCTAssertEqual(api.opened, [original])
        XCTAssertEqual(api.stopped.first?.0, "actual-session")
    }

    func testFixedClockStopsOnceAcrossPausedLoadAndLateKeepaliveTime() {
        var elapsed = Duration.zero
        var stops = 0
        let clock = KidsLiveProgrammeClock(deadline: .seconds(1), now: { elapsed }, current: { true }, ended: { stops += 1 })
        elapsed = .milliseconds(999)
        XCTAssertTrue(clock.check())
        // There is no setter accepting a keepalive's later programme deadline.
        elapsed = .seconds(1)
        XCTAssertFalse(clock.check())
        elapsed = .seconds(99)
        XCTAssertFalse(clock.check())
        XCTAssertEqual(stops, 1)
    }

    func testProgrammeClockStopsOnActualViewerChangeBeforeOriginalEnd() {
        var current = true
        var stops = 0
        let clock = KidsLiveProgrammeClock(deadline: .seconds(100), now: { .zero }, current: { current }, ended: { stops += 1 })
        XCTAssertTrue(clock.check())
        current = false
        XCTAssertFalse(clock.check())
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(AppSession.isProtectedPlaybackType(KidsLivePlayerViewController.self))
    }

    func testStopJoinsOriginalAdmittedKeepaliveBeforeItsSingleStop() async throws {
        let original = context()
        let api = API(context: original, result: try reply())
        let operation = KidsLivePlaybackOperation(context: original, api: api, now: { .zero })
        _ = try await operation.open(channelID: "catalogue-id")
        var release: CheckedContinuation<Void, Never>?
        let keepalive = Task { await withCheckedContinuation { release = $0 } }
        for _ in 0..<100 where release == nil { await Task.yield() }
        XCTAssertNotNil(release)
        operation.close(after: keepalive)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(api.stopped.isEmpty)
        release?.resume(); release = nil
        await operation.waitForCleanup()
        XCTAssertEqual(api.stopped.count, 1)
    }

    func testProviderFreeReadCannotPublishIntoReplacementProfile() async throws {
        let original = context()
        let api = API(context: original, result: try reply()); api.holdChannels = true
        let store = KidsLiveStore(context: original, api: api)
        let loading = Task { await store.load() }
        for _ in 0..<100 where api.channelsPending == nil { await Task.yield() }
        XCTAssertNotNil(api.channelsPending)
        api.context = context("other")
        api.channelsPending?.resume(returning: [])
        api.channelsPending = nil
        await loading.value
        XCTAssertTrue(store.channels.isEmpty)
        XCTAssertNil(store.message)
    }
}
