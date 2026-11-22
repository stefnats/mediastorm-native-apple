import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class SpokenAudioCheckTests: XCTestCase {
    private func context(_ profile: String = "original") -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://synthetic.invalid/prefix")!, profileID: profile,
                            clientID: "original-client", sessionToken: "original-token", unlock: "original-proof")
    }
    private func options(supported: Bool = true) throws -> ReleaseReportOptions {
        let json = """
        {"sourceVersion":"selected-version","releaseName":"Synthetic","audioLanguage":"fra",
         "audioTracks":[{"index":7,"language":"fra"}],"selectedAudioTrack":7,"canShare":false,
         "hasEpisode":false,"canResetHistory":false,"audioLanguageCheckAvailable":\(supported)}
        """
        return try JSONDecoder().decode(ReleaseReportOptions.self, from: Data(json.utf8))
    }
    private func result(status: String = "likely_mismatch", wanted: String = "fra", detected: String? = "spa",
                        version: String = "selected-version", track: Int = 7, samples: Int = 2) -> SpokenAudioResult {
        SpokenAudioResult(status: status, reason: nil, requestedLanguage: wanted, detectedLanguage: detected,
                          confidence: status == "unknown" ? nil : 0.97, samples: samples,
                          sourceVersion: version, audioTrackIndex: track)
    }
    private final class API: SpokenAudioAPI {
        var original: SourceActionContext
        var pending: CheckedContinuation<SpokenAudioResult, Error>?
        var calls: [(String, Int, Double, SourceActionContext)] = []
        init(_ context: SourceActionContext) { original = context }
        func isCurrent(_ context: SourceActionContext) -> Bool { original == context }
        func checkSpokenAudio(_ id: String, options: ReleaseReportOptions, track: Int,
                              offset: Double, context: SourceActionContext) async throws -> SpokenAudioResult {
            calls.append((id, track, offset, context))
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
    }
    private func entered(_ api: API) async {
        for _ in 0..<100 where api.pending == nil { await Task.yield() }
        XCTAssertNotNil(api.pending)
    }
    func testActualRequestUsesOriginalProofAndExactBackendFields() throws {
        let request = try APIClient.spokenAudioRequest("original-id", options: options(), track: 7, offset: 45.5, context: context())
        XCTAssertEqual(request.url?.path, "/prefix/api/playback/prequeue/original-id/audio-language")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer original-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Unlock"), "original-proof")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "original")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["sourceVersion", "audioTrackIndex", "startOffset"]))
        XCTAssertEqual(body["audioTrackIndex"] as? Int, 7)
        XCTAssertEqual(body["startOffset"] as? Double, 45.5)
    }
    func testDisabledUnknownTrackAndInvalidOffsetsNeverCreateAnalysisRequest() throws {
        XCTAssertThrowsError(try APIClient.spokenAudioRequest("id", options: options(supported: false), track: 7, offset: 0, context: context()))
        XCTAssertThrowsError(try APIClient.spokenAudioRequest("id", options: options(), track: 1, offset: 0, context: context()))
        for offset in [Double.nan, Double.infinity, -1, 43_201] {
            XCTAssertThrowsError(try APIClient.spokenAudioRequest("id", options: options(), track: 7, offset: offset, context: context()))
        }
    }
    func testFrenchPreferenceSpanishMismatchAndUnknownAreDistinct() throws {
        try result().validate(options: options(), track: 7)
        try result(status: "likely_match", detected: "fre").validate(options: options(), track: 7)
        try result(status: "unknown", detected: nil, samples: 0).validate(options: options(), track: 7)
        XCTAssertThrowsError(try result(wanted: "eng").validate(options: options(), track: 7))
        XCTAssertThrowsError(try result(status: "likely_match", detected: "spa").validate(options: options(), track: 7))
        XCTAssertThrowsError(try result(samples: 1).validate(options: options(), track: 7))
        XCTAssertThrowsError(try result(version: "replacement").validate(options: options(), track: 7))
    }
    func testCurrentTrackIsSampledAndMismatchRequiresExplicitReview() async throws {
        let api = API(context())
        var selected: SpokenAudioModel.Selection? = .init(track: 7, position: 48)
        let model = SpokenAudioModel(id: "original-id", context: context(), api: api) { selected }
        model.check(try options()); await entered(api)
        selected = .init(track: 7, position: 71) // Ordinary playback advancement is valid.
        api.pending?.resume(returning: result()); api.pending = nil
        await model.waitForCompletion()
        XCTAssertEqual(api.calls.count, 1)
        XCTAssertEqual(api.calls[0].1, 7)
        XCTAssertEqual(api.calls[0].2, 48)
        XCTAssertEqual(model.result?.status, "likely_mismatch")
        XCTAssertTrue(model.message?.contains("Review") == true)
        model.close()
    }
    func testActualTrackChangeWhileHeldDiscardsLateEvidence() async throws {
        let api = API(context())
        var selected: SpokenAudioModel.Selection? = .init(track: 7, position: 48)
        let model = SpokenAudioModel(id: "id", context: context(), api: api) { selected }
        model.check(try options()); await entered(api)
        selected = .init(track: 8, position: 49)
        api.pending?.resume(returning: result()); api.pending = nil
        await model.waitForCompletion()
        XCTAssertNil(model.result); XCTAssertNil(model.message)
    }
    func testAlreadyDisplayedHintRetiresWhenActualSourceOrTrackChanges() async throws {
        let api = API(context())
        var selected: SpokenAudioModel.Selection? = .init(track: 7, position: 48)
        let model = SpokenAudioModel(id: "id", context: context(), api: api) { selected }
        model.check(try options()); await entered(api)
        api.pending?.resume(returning: result()); api.pending = nil
        await model.waitForCompletion()
        XCTAssertNotNil(model.result)
        selected = nil
        model.refreshCurrentSelection()
        XCTAssertNil(model.result); XCTAssertNil(model.message)
        XCTAssertEqual(api.calls.count, 1)
    }
    func testSourceDepartureAndProfileSwitchCannotPublishOrRepeat() async throws {
        for profileChange in [false, true] {
            let api = API(context())
            var selected: SpokenAudioModel.Selection? = .init(track: 7, position: 48)
            let model = SpokenAudioModel(id: "id", context: context(), api: api) { selected }
            model.check(try options()); await entered(api)
            if profileChange { api.original = context("other") } else { selected = nil }
            api.pending?.resume(returning: result()); api.pending = nil
            await model.waitForCompletion()
            XCTAssertEqual(api.calls.count, 1)
            XCTAssertNil(model.result); XCTAssertNil(model.message)
        }
    }
    func testCloseObservesHeldCompletionWithoutDisplayingLateHint() async throws {
        let api = API(context())
        let model = SpokenAudioModel(id: "id", context: context(), api: api) { .init(track: 7, position: 45) }
        model.check(try options()); await entered(api)
        model.close()
        api.pending?.resume(returning: result()); api.pending = nil
        await model.waitForCompletion()
        model.check(try options())
        XCTAssertEqual(api.calls.count, 1)
        XCTAssertNil(model.result); XCTAssertNil(model.message)
    }
    func testUnavailableCheckRemainsUnknownAndDoesNotRetry() async throws {
        let api = API(context())
        let model = SpokenAudioModel(id: "id", context: context(), api: api) { .init(track: 7, position: 45) }
        model.check(try options()); await entered(api)
        model.check(try options()) // A second press cannot admit concurrent work.
        api.pending?.resume(throwing: URLError(.timedOut)); api.pending = nil
        await model.waitForCompletion()
        XCTAssertEqual(api.calls.count, 1)
        XCTAssertNil(model.result)
        XCTAssertNotNil(model.message)
    }
}
