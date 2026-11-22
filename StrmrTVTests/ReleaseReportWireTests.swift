import XCTest
@testable import StrmrTV

final class ReleaseReportWireTests: XCTestCase {
    private func options(episode: Bool = true, language: String = "deu") throws -> ReleaseReportOptions {
        try JSONDecoder().decode(ReleaseReportOptions.self, from: Data("""
        {"sourceVersion":"original-version","releaseName":"Synthetic.Release","audioLanguage":"\(language)",
         "audioTracks":[{"index":2,"language":"eng","codec":"aac"},{"index":5,"language":"deu","codec":"aac"}],
         "selectedAudioTrack":5,"canShare":false,"hasEpisode":\(episode),"canResetHistory":true}
        """.utf8))
    }

    func testMissingLanguageUsesOriginalServerRequestNotPlayingTrack() throws {
        let value = try options()
        let body = try ReleaseReportSubmission(reason: .missingLanguage, retry: false, resetHistory: false,
                                               audioTrackIndex: nil, position: 42).body(options: value, clientID: "client")
        XCTAssertEqual(body["audioLanguage"] as? String, "deu")
        XCTAssertEqual(body["sourceVersion"] as? String, "original-version")
        XCTAssertNil(body["audioTrackIndex"])
        XCTAssertNil(body["result"])
        XCTAssertNil(body["releaseName"])
        XCTAssertNil(body["shared"])
    }

    func testAudioReportAcceptsOnlyActualContainerTrack() throws {
        let value = try options()
        let valid = ReleaseReportSubmission(reason: .audioProblem, retry: false, resetHistory: false,
                                            audioTrackIndex: 5, position: 0)
        XCTAssertEqual(try valid.body(options: value, clientID: "c")["audioTrackIndex"] as? Int, 5)
        XCTAssertThrowsError(try ReleaseReportSubmission(reason: .audioProblem, retry: true, resetHistory: false,
            audioTrackIndex: 99, position: 0).body(options: value, clientID: "c"))
    }

    func testWrongEpisodeRequiresEpisodeAndResetIsExplicit() throws {
        XCTAssertFalse(try options(episode: false).allows(.wrongEpisode))
        let body = try ReleaseReportSubmission(reason: .wrongEpisode, retry: true, resetHistory: false,
            audioTrackIndex: nil, position: 200).body(options: options(), clientID: "c")
        XCTAssertEqual(body["startOffset"] as? Double, 0)
        XCTAssertEqual(body["resetHistory"] as? Bool, false)
        XCTAssertThrowsError(try ReleaseReportSubmission(reason: .deviceProblem, retry: false, resetHistory: true,
            audioTrackIndex: nil, position: 0).body(options: options(), clientID: "c"))
    }

    func testManualRetryDoesNotSubmitReportAndRetainsOffset() throws {
        let body = try ReleaseReportSubmission(reason: nil, retry: true, resetHistory: false,
            audioTrackIndex: nil, position: 125).body(options: options(), clientID: "c")
        XCTAssertNil(body["reason"])
        XCTAssertEqual(body["startOffset"] as? Double, 125)
        XCTAssertThrowsError(try ReleaseReportSubmission(reason: nil, retry: true, resetHistory: false,
            audioTrackIndex: nil, position: .infinity).body(options: options(), clientID: "c"))
    }

    func testPartialAcknowledgementKeepsSavedReportDistinctFromRetry() throws {
        let data = Data(#"{"report":{"id":"report-one"},"historyReset":false,"historyResetError":"history_reset_failed"}"#.utf8)
        let reply = try JSONDecoder().decode(ReleaseReportReply.self, from: data)
        XCTAssertEqual(reply.report?.id, "report-one")
        XCTAssertNotNil(reply.partialFailure)
        XCTAssertNil(reply.replacement)
        XCTAssertNil(reply.resumePosition)
    }

    func testUnavailableRequestedLanguageIsNotInvented() throws {
        XCTAssertFalse(try options(language: "und").allows(.missingLanguage))
        XCTAssertThrowsError(try ReleaseReportSubmission(reason: .missingLanguage, retry: false, resetHistory: false,
            audioTrackIndex: nil, position: 0).body(options: options(language: ""), clientID: "c"))
    }
}
