import Foundation
import XCTest
@testable import StrmrTV

/// Source-authored regressions; no local Swift, HTTP or device execution is claimed.
@MainActor
final class EpisodeFixtureAPI: EpisodeAutoplayAPI {
    var context = PostPlayFixture.context()
    var value = EpisodeAutoplaySettings(enabled: true, skipCredits: false, detectCredits: false)
    var calls: [String] = []
    var readReturns = 0
    var readError: Error?
    var writeError: Error?
    var holdRead = false
    var holdWrite = false
    var read: CheckedContinuation<EpisodeAutoplaySettings, Error>?
    var write: CheckedContinuation<Bool, Error>?
    func sourceContext() -> SourceActionContext { context }
    func isCurrent(_ context: SourceActionContext) -> Bool { self.context == context }
    func episodeAutoplay(_ context: SourceActionContext) async throws -> EpisodeAutoplaySettings {
        defer { readReturns += 1 }
        calls.append("read:" + context.profileID)
        if let readError { throw readError }
        if holdRead { return try await withCheckedThrowingContinuation { read = $0 } }
        return value
    }
    func saveEpisodeAutoplay(_ enabled: Bool, context: SourceActionContext) async throws -> Bool {
        calls.append("write:" + context.profileID + ":" + String(enabled))
        if let writeError { throw writeError }
        if holdWrite { return try await withCheckedThrowingContinuation { write = $0 } }
        return enabled
    }
    func reply() { read?.resume(returning: value); read = nil }
}

@MainActor
enum EpisodeFixture {
    static func settle(_ predicate: () -> Bool) async { for _ in 0..<1000 { if !predicate() { await Task.yield() } } }
    static func data(_ raw: Any) throws -> Data { try JSONSerialization.data(withJSONObject: raw) }
    static func next() throws -> PlaybackRequest {
        let original = try PostPlayFixture.request(series: true, episodes: [PostPlayFixture.episode(1), PostPlayFixture.episode(2), PostPlayFixture.episode(3)])
        return try XCTUnwrap(original.nextEpisode)
    }
    static func denial() -> APIError { .http(HTTPFailure(status: 403, data: Data("{\"code\":\"profile_locked\"}".utf8))) }
}

@MainActor
final class EpisodeAutoplayContractTests: XCTestCase {
    func testProfileReadUsesActualNextEpisodeAutoPlayField() throws {
        let enabled = try EpisodeAutoplaySettings.decode(EpisodeFixture.data(["playback": ["nextEpisodeAutoPlay": true]]))
        let disabled = try EpisodeAutoplaySettings.decode(EpisodeFixture.data(["playback": ["nextEpisodeAutoPlay": false]]))
        let legacy = try EpisodeAutoplaySettings.decode(EpisodeFixture.data(["playback": [:]]))
        XCTAssertTrue(enabled.enabled); XCTAssertFalse(disabled.enabled); XCTAssertTrue(legacy.enabled)
        let request = try APIClient.episodeAutoplayRequest(PostPlayFixture.context())
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/proxy/api/users/original/settings")
    }
    func testFailedOrMalformedReadNeverEnablesAutoplay() async throws {
        for raw in [Data("{}".utf8), Data("{\"playback\":null}".utf8), Data("{\"playback\":{\"nextEpisodeAutoPlay\":\"yes\"}}".utf8)] {
            XCTAssertThrowsError(try EpisodeAutoplaySettings.decode(raw))
        }
        let api = EpisodeFixtureAPI(); api.readError = URLError(.networkConnectionLost)
        let model = EpisodeAutoplayModel(api: api); defer { model.close() }
        model.load(); await EpisodeFixture.settle { !model.busy }
        XCTAssertNil(model.enabled); XCTAssertNotNil(model.error)
    }
    func testPatchUsesOnlyActualNextEpisodeKeyAndRequiresExactBooleanEcho() throws {
        let request = try APIClient.episodeAutoplayRequest(PostPlayFixture.context(), value: false)
        XCTAssertEqual(request.httpMethod, "PATCH"); XCTAssertEqual(request.url?.path, "/proxy/api/users/original/settings/skipping")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Bool])
        XCTAssertEqual(body, ["nextEpisode": false])
        XCTAssertFalse(try APIClient.episodeAutoplayConfirmation(EpisodeFixture.data(body), expected: false))
        for raw in [["nextEpisode": true] as [String: Any], ["nextEpisode": "false"], [:]] {
            XCTAssertThrowsError(try APIClient.episodeAutoplayConfirmation(EpisodeFixture.data(raw), expected: false))
        }
    }
    func testRequestsRetainOriginalProxyProfileClientAndProof() throws {
        let original = PostPlayFixture.context("original profile")
        for request in [try APIClient.episodeAutoplayRequest(original), try APIClient.episodeAutoplayRequest(original, value: true)] {
            XCTAssertTrue(request.url!.path.hasPrefix("/proxy/api/users/original profile/settings"))
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "profileId" })?.value, original.profileID)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-ID"), "synthetic-client")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Unlock"), "synthetic-proof")
        }
    }
    func testEffectiveCreditsFlagsDoNotOverrideProfileAutoplay() throws {
        let user = try EpisodeFixture.data(["playback": ["nextEpisodeAutoPlay": false, "creditsAutoSkip": false, "creditsDetectionEnabled": false]])
        let device = try EpisodeFixture.data(["nextEpisodeAutoPlay": true, "creditsAutoSkip": true, "creditsDetectionEnabled": true])
        let value = try EpisodeAutoplaySettings.decode(user, device: device)
        XCTAssertFalse(value.enabled); XCTAssertTrue(value.skipCredits); XCTAssertTrue(value.detectCredits)
        let inverse = try EpisodeAutoplaySettings.decode(EpisodeFixture.data(["playback": ["nextEpisodeAutoPlay": true]]), device: EpisodeFixture.data(["nextEpisodeAutoPlay": false, "creditsAutoSkip": false]))
        XCTAssertTrue(inverse.enabled); XCTAssertFalse(inverse.skipCredits)
    }
    func testSettingSavePublishesOnlyConfirmedOriginalValue() async {
        let api = EpisodeFixtureAPI()
        let editor = EpisodeAutoplayModel(api: api); defer { editor.close() }
        editor.load(); await EpisodeFixture.settle { !editor.busy }
        api.holdWrite = true; editor.save(false); await EpisodeFixture.settle { api.write != nil }
        XCTAssertEqual(editor.enabled, true)
        api.write?.resume(returning: false); api.write = nil; await EpisodeFixture.settle { !editor.busy }
        XCTAssertEqual(editor.enabled, false); XCTAssertEqual(EpisodeAutoplayChanges.latest?.context, editor.context)
        XCTAssertEqual(EpisodeAutoplayChanges.latest?.enabled, false)
    }
    func testUnknownWriteRequiresExplicitReadBeforeAnotherWrite() async {
        let api = EpisodeFixtureAPI(), model = EpisodeAutoplayModel(api: api); defer { model.close() }
        model.load(); await EpisodeFixture.settle { !model.busy }
        api.writeError = URLError(.networkConnectionLost); model.save(false); await EpisodeFixture.settle { !model.busy }
        XCTAssertNil(model.enabled); model.save(true); XCTAssertEqual(api.calls.filter { $0.hasPrefix("write:") }.count, 1)
        api.value = .init(enabled: false, skipCredits: false, detectCredits: false); api.writeError = nil
        model.load(); await EpisodeFixture.settle { !model.busy }; XCTAssertEqual(model.enabled, false)
        model.save(true); await EpisodeFixture.settle { !model.busy }; XCTAssertEqual(model.enabled, true)
    }
    func testLateReadCannotOverwriteNewerConfirmedSetting() async {
        let api = EpisodeFixtureAPI(); api.holdRead = true
        let model = EpisodeAutoplayModel(api: api); defer { model.close() }
        model.load(); await EpisodeFixture.settle { api.read != nil }
        EpisodeAutoplayChanges.saved(false, context: model.context)
        api.reply(); await EpisodeFixture.settle { !model.busy }; XCTAssertEqual(model.enabled, false)
    }
    func testClosedOrChangedSettingsFrameCannotPublish() async {
        for close in [false, true] {
            let api = EpisodeFixtureAPI(); api.holdRead = true
            let model = EpisodeAutoplayModel(api: api); model.load(); await EpisodeFixture.settle { api.read != nil }
            if close { model.close() } else { api.context = PostPlayFixture.context("replacement") }
            api.reply(); await EpisodeFixture.settle { api.readReturns > 0 }; await Task.yield()
            XCTAssertNil(model.enabled); XCTAssertFalse(model.current); model.close()
        }
    }
    func testKnownDenialIsNotLegacyAutoplayGrant() async {
        let api = EpisodeFixtureAPI(); api.readError = EpisodeFixture.denial()
        let model = EpisodeAutoplayModel(api: api); defer { model.close() }
        model.load(); await EpisodeFixture.settle { !model.busy }
        XCTAssertNil(model.enabled); XCTAssertFalse(model.current); model.save(true); XCTAssertEqual(api.calls.count, 1)
    }
}
