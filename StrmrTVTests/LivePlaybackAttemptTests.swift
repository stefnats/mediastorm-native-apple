import XCTest
@testable import StrmrTV

@MainActor
final class LivePlaybackAttemptTests: XCTestCase {
    private func context() -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://synthetic.invalid/base")!, profileID: "original-profile",
            clientID: "original-client", sessionToken: "original-token")
    }
    private func channel(_ url: String = "https://provider.invalid/never-open") throws -> LiveChannel {
        try JSONDecoder().decode(LiveChannel.self, from: JSONSerialization.data(withJSONObject:
            ["id":"source:channel","name":"Synthetic","url":url,"sourceId":"source"]))
    }
    private func reply() throws -> LiveStart {
        try JSONDecoder().decode(LiveStart.self, from: Data(#"{"sessionId":"owned","playlistUrl":"/video/hls/owned/stream.m3u8","isDirect":false}"#.utf8))
    }
    private func challenge() -> APIError {
        APIError.http(HTTPFailure(status: 409, data: Data(("{\"code\":\"LIVE_RECORDING_CONFIRMATION_REQUIRED\",\"confirmationToken\":\"" + String(repeating:"a",count:48) + "\",\"recordingCount\":1,\"expiresInSeconds\":30}").utf8)))
    }
    func testConfirmedStartAndRetuneKeepOneAttemptButNeverReplayConfirmation() async throws {
        let attempt = LivePlaybackAttempt(context: context(), id: "original-attempt-id", current: { true })
        var calls: [(String,String?,Bool)] = []
        var prompts = 0
        let value = try reply()
        let fetch: (String,String?,Bool) async throws -> LiveStart = { id, token, automatic in
            calls.append((id,token,automatic))
            if calls.count == 1 { throw self.challenge() }
            return value
        }
        _ = try await attempt.open(channel(), confirm: { _, _ in prompts += 1; return true }, fetch: fetch, retire: { _ in XCTFail("Unexpected cleanup") })
        _ = try await attempt.open(channel(), confirm: { _, _ in XCTFail("Retune prompted again"); return false }, fetch: fetch, retire: { _ in })
        XCTAssertTrue(attempt.admitted)
        XCTAssertEqual(prompts,1)
        XCTAssertEqual(calls.map(\.0),Array(repeating:"original-attempt-id",count:3))
        XCTAssertEqual(calls.map(\.2),[false,false,true])
        XCTAssertNil(calls[0].1)
        XCTAssertEqual(calls[1].1,String(repeating:"a",count:48))
        XCTAssertNil(calls[2].1)
    }
    func testAutomaticRestoreAndPreAdmissionRecoveryCannotRequestTakeoverConsent() async throws {
        for permits in [false,true] {
            let attempt = LivePlaybackAttempt(context: context(), permitsTakeover: permits, current: { true })
            var calls = 0
            do {
                _ = try await attempt.open(channel(), automaticIntent: true,
                    confirm: { _, _ in XCTFail("Automatic restore escalated to confirmation");return true },
                    fetch: { _,token,automatic in calls += 1;XCTAssertTrue(automatic);XCTAssertNil(token);throw self.challenge() }, retire: { _ in })
                XCTFail("Automatic challenge was accepted")
            } catch { XCTAssertTrue(attempt.blocksRetry(error)) }
            XCTAssertEqual(calls,1)
        }
    }
    func testOriginalRequestDeadlineCannotBeRenewedByLateChallengeOrPrompt() async throws {
        var time = Duration.zero
        let attempt = LivePlaybackAttempt(context: context(), now: { time }, current: { true })
        var calls = 0
        do {
            _ = try await attempt.open(channel(),confirm:{ _,_ in time = .seconds(31);return true },fetch:{ _,_,_ in
                calls += 1;throw self.challenge()
            },retire:{ _ in })
            XCTFail("Expired original confirmation was retried")
        } catch { }
        XCTAssertEqual(calls,1)
    }
    func testDifferentChannelInputCannotReuseOriginalAttemptButStremioIndexCanRetune() async throws {
        let attempt = LivePlaybackAttempt(context:context(),current:{true})
        let value = try reply()
        var calls = 0
        let fetch: (String,String?,Bool) async throws -> LiveStart = { _,_,_ in calls += 1;return value }
        var selected = try channel(); selected.stremioStreamIndex = 1
        _ = try await attempt.open(selected,confirm:{_,_ in false},fetch:fetch,retire:{_ in})
        selected.stremioStreamIndex = 7
        _ = try await attempt.open(selected,confirm:{_,_ in false},fetch:fetch,retire:{_ in})
        do {_ = try await attempt.open(channel("https://other.invalid/never-open"),confirm:{_,_ in false},fetch:fetch,retire:{_ in});XCTFail("Changed URL adopted") } catch { }
        XCTAssertEqual(calls,2)
    }
    func testUnknownTransportOutcomeCannotAutomaticallyOpenAnotherProvider() async throws {
        let attempt=LivePlaybackAttempt(context:context(),current:{true})
        var calls=0
        let fetch: (String,String?,Bool) async throws -> LiveStart={ _,_,_ in calls += 1;throw URLError(.networkConnectionLost) }
        do {_ = try await attempt.open(channel(),confirm:{_,_ in false},fetch:fetch,retire:{_ in});XCTFail("Unknown ignored")}catch{XCTAssertTrue(attempt.blocksRetry(error))}
        do {_ = try await attempt.open(channel(),automaticIntent:true,confirm:{_,_ in false},fetch:fetch,retire:{_ in});XCTFail("Unknown retried")}catch{}
        XCTAssertEqual(calls,1)
    }
    func testCancelledActualOpenStillRetiresItsKnownLateReceipt() async throws {
        let attempt=LivePlaybackAttempt(context:context(),current:{true})
        var pending:CheckedContinuation<LiveStart,Error>?
        var cleaned:[String]=[]
        let task=Task {try await attempt.open(channel(),confirm:{_,_ in false},fetch:{_,_,_ in
            try await withCheckedThrowingContinuation {pending=$0}
        },retire:{value in cleaned.append(value.sessionId ?? "")})}
        for _ in 0..<100 where pending == nil {await Task.yield()}
        XCTAssertNotNil(pending)
        task.cancel();attempt.close()
        pending?.resume(returning:try reply());pending=nil
        do {_ = try await task.value;XCTFail("Cancelled open adopted")}catch{}
        XCTAssertEqual(cleaned,["owned"])
    }
    func testCancelAndMalformedChallengeNeverSendAConfirmationRetry() async throws {
        let valid = challenge()
        let malformed = APIError.http(HTTPFailure(status:409,data:Data(#"{"code":"LIVE_RECORDING_CONFIRMATION_REQUIRED","confirmationToken":"invalid","recordingCount":1,"expiresInSeconds":30}"#.utf8)))
        for error in [valid,malformed] {
            let attempt=LivePlaybackAttempt(context:context(),current:{true})
            var calls=0
            do {_ = try await attempt.open(channel(),confirm:{_,_ in false},fetch:{_,_,_ in calls += 1;throw error},retire:{_ in XCTFail("No session was created")});XCTFail("Cancelled challenge accepted")}catch{}
            XCTAssertEqual(calls,1)
        }
    }
    func testBoundWireContainsOriginalProfileAndOnlyExplicitHeader() throws {
        let query=["profileId":"foreign","clientId":"foreign","url":"https://provider.invalid/never-open","playAttemptId":"same-original-attempt","automaticRetry":"true"]
        let request=try APIClient.liveStartRequest(context:context(),query:query,confirmation:nil)
        let items=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertEqual(request.url?.path,"/base/api/live/hls/start")
        XCTAssertEqual(items.first{$0.name=="profileId"}?.value,"original-profile")
        XCTAssertEqual(items.first{$0.name=="clientId"}?.value,"original-client")
        XCTAssertNil(request.value(forHTTPHeaderField:"X-Live-Recording-Confirmation"))
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer original-token")
    }
}
