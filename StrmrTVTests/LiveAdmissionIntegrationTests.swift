import Foundation
import XCTest
@testable import StrmrTV

private final class LiveHTTPExchange: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Actual URLSession live start entered")
    private let lock = NSLock()
    private var pending: URLProtocol?
    private var cancelled = false
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private var requests: [URLRequest] = []
    func receive(_ handler: URLProtocol) {
        lock.lock(); requests.append(handler.request)
        let start = handler.request.url?.path.hasSuffix("/start") == true
        if start { pending = handler }
        lock.unlock()
        if start { entered.fulfill() } else { respond(handler, data: Data(), status: 204) }
    }
    func cancel(_ handler: URLProtocol) {
        lock.lock(); defer { lock.unlock() }
        if pending === handler { cancelled = true; pending = nil }
    }
    func acknowledge() {
        lock.lock(); let handler = pending; pending = nil; lock.unlock()
        if let handler { respond(handler, data: Data(#"{"sessionId":"late-owned","playlistUrl":"/video/hls/late-owned/stream.m3u8","isDirect":false}"#.utf8), status: 200) }
    }
    var recorded: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    private func respond(_ handler: URLProtocol, data: Data, status: Int) {
        handler.client?.urlProtocol(handler, didReceive: HTTPURLResponse(url: handler.request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        handler.client?.urlProtocol(handler, didLoad: data)
        handler.client?.urlProtocolDidFinishLoading(handler)
    }
}
private final class LiveHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String:LiveHTTPExchange] = [:]
    func install(_ value: LiveHTTPExchange?, key: String) { lock.lock(); values[key] = value; lock.unlock() }
    func get(_ key: String) -> LiveHTTPExchange? { lock.lock(); defer {lock.unlock()}; return values[key] }
}
private final class LiveHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = LiveHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.registry.get(request.url?.host ?? "")?.receive(self) }
    override func stopLoading() { Self.registry.get(request.url?.host ?? "")?.cancel(self) }
}

@MainActor
final class LiveAdmissionIntegrationTests: XCTestCase {
    private func context(_ profile: String = "original", host: String = "synthetic.invalid") -> SourceActionContext {
        SourceActionContext(baseURL: URL(string: "https://\(host)/base")!, profileID: profile,
            clientID: "original-client", sessionToken: "original-token")
    }
    private func channel() throws -> LiveChannel {
        try JSONDecoder().decode(LiveChannel.self, from: Data(#"{"id":"original-channel","name":"Synthetic","url":"https://provider.invalid/never-open","sourceId":"original-source"}"#.utf8))
    }
    private final class API: LiveMultiscreenAPI {
        var current: SourceActionContext
        var starts: [(String,Bool)] = []
        var stops: [SourceActionContext] = []
        var pendingStop: CheckedContinuation<Void, Error>?
        var holdStop = false
        var challenge = false
        var confirmations = 0
        init(_ context: SourceActionContext) { current = context }
        func sourceContext() -> SourceActionContext { current }
        func isCurrent(_ context: SourceActionContext) -> Bool { current == context }
        func startLiveHLS(_ channel: LiveChannel, attempt: LivePlaybackAttempt) async throws -> (sessionID: String?, url: URL?) {
            let reply = try await attempt.open(channel, confirm: {_,_ in self.confirmations += 1;return true}, fetch: { id,token,automatic in
                self.starts.append((id,automatic))
                XCTAssertNil(token)
                if self.challenge {
                    let raw="{\"code\":\"LIVE_RECORDING_CONFIRMATION_REQUIRED\",\"confirmationToken\":\""+String(repeating:"a",count:48)+"\",\"recordingCount\":1,\"expiresInSeconds\":30}"
                    throw APIError.http(HTTPFailure(status:409,data:Data(raw.utf8)))
                }
                return try JSONDecoder().decode(LiveStart.self, from: Data(#"{"sessionId":"owned","playlistUrl":"/video/hls/owned/stream.m3u8","isDirect":false}"#.utf8))
            },retire:{_ in try await self.stopLiveSessionStrict("owned",context:attempt.context)})
            return (reply.sessionId,URL(string:"https://synthetic.invalid/never-open"))
        }
        func stopLiveSessionStrict(_ session: String, context: SourceActionContext?) async throws {
            guard let context else { return XCTFail("Actual live stop lost its original context") }
            stops.append(context)
            if holdStop { try await withCheckedThrowingContinuation { pendingStop = $0 } }
        }
    }
    func testActualQueuedAutomaticRestoreNeverRequestsConfirmation() async throws {
        let original = context()
        let api = API(original); api.challenge = true
        let transport = MultiscreenAPITransport(context:original,api:api)
        let session = MultiscreenSession(transport:transport)
        await session.tune(0,to:try channel(),automatic:true).value
        XCTAssertEqual(api.starts.count,1)
        XCTAssertEqual(api.starts.first?.1,true)
        XCTAssertEqual(api.confirmations,0)
        XCTAssertNotNil(session.slots[0].error)
    }
    func testActualQueueJoinsKnownStopBeforeAnyReplacementStart() async throws {
        let original = context()
        let api = API(original)
        let session = MultiscreenSession(transport:MultiscreenAPITransport(context:original,api:api))
        let selected = try channel()
        await session.tune(0,to:selected).value
        api.holdStop = true
        let replacing = session.tune(0,to:selected)
        for _ in 0..<100 where api.pendingStop == nil { await Task.yield() }
        XCTAssertNotNil(api.pendingStop)
        XCTAssertEqual(api.starts.count,1)
        XCTAssertEqual(api.stops,[original])
        api.holdStop = false
        api.pendingStop?.resume();api.pendingStop = nil
        await replacing.value
        XCTAssertEqual(api.starts.count,2)
        try await session.close()
    }
    func testUnknownStopKeepsOwnedSlotAndCannotAdmitReplacement() async throws {
        let original=context()
        let api=API(original)
        let session=MultiscreenSession(transport:MultiscreenAPITransport(context:original,api:api))
        let selected=try channel()
        await session.tune(0,to:selected).value
        api.holdStop=true
        let replacing=session.tune(0,to:selected)
        for _ in 0..<100 where api.pendingStop == nil {await Task.yield()}
        XCTAssertNotNil(api.pendingStop)
        api.pendingStop?.resume(throwing:URLError(.networkConnectionLost));api.pendingStop=nil
        await replacing.value
        XCTAssertEqual(api.starts.count,1)
        XCTAssertEqual(session.slots[0].sessionID,"owned")
        XCTAssertNotNil(session.slots[0].error)
        api.holdStop=false
        try await session.close()
        XCTAssertEqual(api.stops,[original,original])
    }
    func testActualTransportStopKeepsCreatorWhenCurrentProfileChanges() async throws {
        let original = context()
        let api = API(original)
        let transport = MultiscreenAPITransport(context:original,api:api)
        _ = try await transport.start(channel(),automatic:false,current:{true})
        api.current = context("other")
        try await transport.stop("owned")
        XCTAssertEqual(api.stops,[original])
        do {_ = try await transport.start(channel(),automatic:false,current:{true});XCTFail("Old transport adopted new profile") }catch{}
        XCTAssertEqual(api.starts.count,1)
    }
    func testActualURLSessionStartSurvivesCallerCancelAndCleansLateOriginalSession() async throws {
        let host=UUID().uuidString.lowercased()+".invalid"
        let original=context(host:host)
        let exchange=LiveHTTPExchange()
        LiveHTTPProtocol.registry.install(exchange,key:host)
        let config=URLSessionConfiguration.ephemeral
        config.protocolClasses=[LiveHTTPProtocol.self]
        config.timeoutIntervalForResource=5
        let http=URLSession(configuration:config)
        defer {http.invalidateAndCancel();LiveHTTPProtocol.registry.install(nil,key:host)}
        let attempt=LivePlaybackAttempt(context:original,current:{true})
        let selected=try channel()
        let opening=Task {try await attempt.open(selected,confirm:{_,_ in false},fetch:{id,token,automatic in
            let request=try APIClient.liveStartRequest(context:original,query:["url":selected.url,"playAttemptId":id,"automaticRetry":String(automatic)],confirmation:token)
            let (data,_)=try await http.data(for:request)
            return try JSONDecoder().decode(LiveStart.self,from:data)
        },retire:{reply in
            _ = try await http.data(for:original.request("POST",path:"/api/video/hls/\(reply.sessionId!)/stop"))
        })}
        let entered=await XCTWaiter.fulfillment(of:[exchange.entered],timeout:2)
        XCTAssertEqual(entered,.completed)
        opening.cancel();attempt.close()
        for _ in 0..<10 {await Task.yield()}
        XCTAssertFalse(exchange.wasCancelled)
        exchange.acknowledge()
        do {_ = try await opening.value;XCTFail("Cancelled caller adopted URLSession receipt")}catch{}
        XCTAssertEqual(exchange.recorded.map(\.httpMethod),["GET","POST"])
        XCTAssertEqual(exchange.recorded.last?.url?.path,"/base/api/video/hls/late-owned/stop")
        XCTAssertEqual(exchange.recorded.last?.value(forHTTPHeaderField:"Authorization"),"Bearer original-token")
    }
    func testProductionPreferencePreparationCannotAdoptViewerAfterHeldIdentityLookup() async throws {
        let original = context()
        var current = original
        let attempt = LivePlaybackAttempt(context: original, current: { current == original })
        var lookup: CheckedContinuation<Bool, Never>?
        var starts = 0
        let selected = try channel()
        let opening = Task {
            _ = try await attempt.prepare { await withCheckedContinuation { lookup = $0 } }
            return try await attempt.open(selected, confirm: { _, _ in false }, fetch: { _, _, _ in
                starts += 1
                return try JSONDecoder().decode(LiveStart.self, from: Data(#"{"sessionId":"unexpected","playlistUrl":"/video/hls/unexpected/stream.m3u8","isDirect":false}"#.utf8))
            }, retire: { _ in })
        }
        for _ in 0..<100 where lookup == nil { await Task.yield() }
        XCTAssertNotNil(lookup)
        current = context("replacement")
        lookup?.resume(returning: true); lookup = nil
        do { _ = try await opening.value; XCTFail("Late lookup adopted replacement viewer") } catch {}
        XCTAssertEqual(attempt.context, original)
        XCTAssertEqual(starts, 0)
    }
}

#if os(iOS)
@MainActor
extension LiveAdmissionIntegrationTests {
    private final class Receiver: CastTransport {
        let device=CastDevice(id:"synthetic",name:"Synthetic receiver",model:nil,kind:.dlna,address:nil)
        let canSeek=false
        var loads=0
        var stops=0
        var pendingStop: CheckedContinuation<Void, Never>?
        var holdStop=false
        var readStatus: (() async -> CastPlaybackState?)?
        func load(_ media:CastMedia)async throws{loads += 1}
        func play()async throws{}
        func pause()async throws{}
        func seek(to seconds:Double)async throws{}
        func setVolume(_ volume:Float)async throws{}
        func status()async -> CastPlaybackState?{if let readStatus {return await readStatus()};return nil}
        func stop()async{stops += 1;if holdStop {await withCheckedContinuation {pendingStop=$0}}}
    }
    func testActualCastPreparedRetainsLiveCreatorAndLegacyDefaultsRemainNil() {
        let receiver=Receiver()
        var media=CastMedia(url:URL(string:"https://synthetic.invalid/never-open")!,contentType:"application/vnd.apple.mpegurl",title:"Synthetic",subtitle:nil,posterURL:nil,duration:nil,startPosition:0)
        media.isLive=true
        let live=CastController.Prepared(transport:receiver,media:media,hlsSessionID:"owned",playback:nil,liveContext:context())
        XCTAssertEqual(live.liveContext,context())
        let legacy=CastController.Prepared(transport:receiver,media:media,hlsSessionID:nil,playback:nil)
        XCTAssertNil(legacy.liveContext)
    }
    func testActualCastStartLoopJoinsHeldPreparedReplyBeforeStopCanFinish() async {
        let cast=CastController.shared
        await cast.finish(reason:"synthetic setup",stopReceiver:true)
        let receiver=Receiver()
        var session=CastController.Session(device:receiver.device,title:"Synthetic",subtitle:nil,artworkURL:nil)
        session.isLive=true
        var pending:CheckedContinuation<CastController.Prepared,Error>?
        let opening=Task {await cast.begin(session) {try await withCheckedThrowingContinuation {pending=$0}}}
        for _ in 0..<100 where pending == nil {await Task.yield()}
        XCTAssertNotNil(pending)
        var stopped=false
        let stop=Task {await cast.finish(reason:"synthetic user stop",stopReceiver:true);stopped=true}
        for _ in 0..<10 {await Task.yield()}
        XCTAssertFalse(stopped)
        var media=CastMedia(url:URL(string:"https://synthetic.invalid/never-open")!,contentType:"video/mp2t",title:"Synthetic",subtitle:nil,posterURL:nil,duration:nil,startPosition:0)
        media.isLive=true
        pending?.resume(returning:CastController.Prepared(transport:receiver,media:media,hlsSessionID:nil,playback:nil,liveContext:context()));pending=nil
        await opening.value;await stop.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(receiver.loads,0)
    }
    private func prepared(_ receiver: Receiver, id: String? = nil) -> CastController.Prepared {
        var media = CastMedia(url: URL(string:"https://synthetic.invalid/never-open")!, contentType:"video/mp2t",
            title:"Synthetic", subtitle:nil, posterURL:nil, duration:nil, startPosition:0)
        media.isLive = true
        return CastController.Prepared(transport:receiver, media:media, hlsSessionID:id, playback:nil,
            liveContext:id == nil ? nil : context())
    }
    func testStaleCastBeginCannotFinishNewerStartAfterSharedOriginalJoin() async {
        let cast = CastController.shared
        await cast.finish(reason:"synthetic setup", stopReceiver:true)
        let old = Receiver(), a = Receiver(), b = Receiver()
        var pending: CheckedContinuation<CastController.Prepared, Error>?
        let x = Task { await cast.begin(.init(device:old.device,title:"X",subtitle:nil,artworkURL:nil)) {
            try await withCheckedThrowingContinuation { pending = $0 }
        } }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        XCTAssertNotNil(pending)
        let first = Task { await cast.begin(.init(device:a.device,title:"A",subtitle:nil,artworkURL:nil)) { self.prepared(a) } }
        for _ in 0..<10 { await Task.yield() }
        let newest = Task { await cast.begin(.init(device:b.device,title:"B",subtitle:nil,artworkURL:nil)) { self.prepared(b) } }
        for _ in 0..<10 { await Task.yield() }
        pending?.resume(returning:prepared(old)); pending = nil
        await x.value; await first.value; await newest.value
        XCTAssertEqual(a.loads,0); XCTAssertEqual(b.loads,1)
        XCTAssertEqual(b.stops,0); XCTAssertTrue(cast.transport === b)
        XCTAssertEqual(cast.session?.title,"B")
        await cast.finish(reason:"synthetic cleanup",stopReceiver:true)
    }
    func testHeldOriginalKeepaliveDenialIsJoinedWithoutStoppingReplacement() async {
        let cast = CastController.shared
        await cast.finish(reason:"synthetic setup",stopReceiver:true)
        let oldStop = cast.stopLiveHLS
        var stopped: [(String,SourceActionContext)] = []
        cast.stopLiveHLS = { stopped.append(($0,$1)) }
        let a = Receiver(), b = Receiver()
        await cast.begin(.init(device:a.device,title:"A",subtitle:nil,artworkURL:nil,isLive:true)) { self.prepared(a,id:"owned-A") }
        var reply: CheckedContinuation<Void,Error>?
        cast.keepAlive { _, _, _ in try await withCheckedThrowingContinuation { reply = $0 } }
        for _ in 0..<100 where reply == nil { await Task.yield() }
        XCTAssertNotNil(reply)
        let replacement = Task { await cast.begin(.init(device:b.device,title:"B",subtitle:nil,artworkURL:nil,isLive:true)) { self.prepared(b) } }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(b.loads,0)
        reply?.resume(throwing:CastError("Synthetic original denial")); reply = nil
        await replacement.value
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(cast.liveKeepalive); XCTAssertTrue(cast.transport === b)
        XCTAssertEqual(b.loads,1); XCTAssertEqual(b.stops,0)
        XCTAssertEqual(stopped.map(\.0),["owned-A"]); XCTAssertEqual(stopped.first?.1,context())
        await cast.finish(reason:"synthetic cleanup",stopReceiver:true)
        cast.stopLiveHLS = oldStop
    }
    func testActiveOriginalKeepaliveDenialOwnsAndJoinsItsReceiverStop() async {
        let cast = CastController.shared
        await cast.finish(reason:"synthetic setup",stopReceiver:true)
        let oldStop = cast.stopLiveHLS
        var stopped: [String] = []
        cast.stopLiveHLS = { id, _ in stopped.append(id) }
        let a = Receiver(); a.holdStop = true
        await cast.begin(.init(device:a.device,title:"A",subtitle:nil,artworkURL:nil,isLive:true)) { self.prepared(a,id:"owned-A") }
        cast.keepAlive { _, _, _ in throw CastError("Synthetic active denial") }
        for _ in 0..<100 where a.pendingStop == nil { await Task.yield() }
        XCTAssertNotNil(a.pendingStop); XCTAssertNotNil(cast.liveKeepalive)
        let owner = cast.liveKeepalive
        a.pendingStop?.resume(); a.pendingStop = nil
        await owner?.value
        XCTAssertEqual(a.stops,1); XCTAssertEqual(stopped,["owned-A"])
        XCTAssertNil(cast.liveKeepalive); XCTAssertNil(cast.transport); XCTAssertNil(cast.session)
        cast.stopLiveHLS = oldStop
    }
    func testReplacementLoadJoinsActualDetachedReceiverStop() async {
        let cast = CastController.shared
        await cast.finish(reason:"synthetic setup",stopReceiver:true)
        let a = Receiver(), b = Receiver(); a.holdStop = true
        await cast.begin(.init(device:a.device,title:"A",subtitle:nil,artworkURL:nil)) { self.prepared(a) }
        let stopping = Task { await cast.finish(reason:"synthetic stop",stopReceiver:true) }
        for _ in 0..<100 where a.pendingStop == nil { await Task.yield() }
        XCTAssertNotNil(a.pendingStop); XCTAssertNotNil(cast.receiverStop)
        let replacement = Task { await cast.begin(.init(device:b.device,title:"B",subtitle:nil,artworkURL:nil)) { self.prepared(b) } }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(b.loads,0)
        a.pendingStop?.resume(); a.pendingStop = nil
        await stopping.value; await replacement.value
        XCTAssertNil(cast.receiverStop); XCTAssertEqual(b.loads,1)
        XCTAssertEqual(b.stops,0); XCTAssertTrue(cast.transport === b)
        await cast.finish(reason:"synthetic cleanup",stopReceiver:true)
    }
    func testUnsupportedDLNAHLSFailedStopRetainsCreatorAndBlocksNextProviderOpen() async {
        let cast = CastController.shared
        await cast.finish(reason:"synthetic setup",stopReceiver:true)
        let original = context(), oldStop = cast.stopLiveHLS
        var reply: CheckedContinuation<Void,Error>?
        var hold = true, stops: [(String,SourceActionContext)] = []
        cast.stopLiveHLS = { id, context in
            stops.append((id,context))
            if hold { hold = false; try await withCheckedThrowingContinuation { reply = $0 } }
            else { throw CastError("Synthetic unconfirmed stop") }
        }
        let receiver = Receiver()
        let opening = Task { await cast.begin(.init(device:receiver.device,title:"TS-only",subtitle:nil,artworkURL:nil,isLive:true)) {
            await cast.retireUnsupportedLiveHLS("unsupported-HLS",context:original)
            throw CastError("Synthetic TS-only renderer cannot play HLS")
        } }
        for _ in 0..<100 where reply == nil { await Task.yield() }
        XCTAssertNotNil(reply)
        XCTAssertEqual(cast.hlsSessionID,"unsupported-HLS"); XCTAssertEqual(cast.liveStartContext,original)
        reply?.resume(throwing:CastError("Synthetic lost stop acknowledgement")); reply = nil
        await opening.value
        var providerOpens = 0
        await cast.begin(.init(device:receiver.device,title:"Next",subtitle:nil,artworkURL:nil,isLive:true)) {
            providerOpens += 1; return self.prepared(receiver)
        }
        XCTAssertEqual(providerOpens,0); XCTAssertEqual(receiver.loads,0)
        XCTAssertEqual(cast.hlsSessionID,"unsupported-HLS"); XCTAssertEqual(cast.liveStartContext,original)
        XCTAssertTrue(stops.allSatisfy { $0.0 == "unsupported-HLS" && $0.1 == original })
        cast.stopLiveHLS = { _, _ in }
        await cast.finish(reason:"synthetic explicit confirmed cleanup",stopReceiver:true)
        XCTAssertNil(cast.hlsSessionID); XCTAssertNil(cast.liveStartContext)
        cast.stopLiveHLS = oldStop
    }
    func testLateNilReceiverStatusAtFailureLimitCannotFinishReplacement() async {
        let cast = CastController.shared
        await cast.finish(reason:"synthetic setup",stopReceiver:true)
        let a = Receiver(), b = Receiver()
        var reads = 0, held: CheckedContinuation<CastPlaybackState?,Never>?
        a.readStatus = {
            reads += 1
            if reads == 8 { return await withCheckedContinuation { held = $0 } }
            return nil
        }
        await cast.begin(.init(device:a.device,title:"A",subtitle:nil,artworkURL:nil)) { self.prepared(a) }
        cast.startPolling(wait: {})
        let oldPoll = cast.pollTask
        for _ in 0..<100 where held == nil { await Task.yield() }
        XCTAssertNotNil(held); XCTAssertEqual(reads,8)
        await cast.begin(.init(device:b.device,title:"B",subtitle:nil,artworkURL:nil)) { self.prepared(b) }
        held?.resume(returning:nil); held = nil
        await oldPoll?.value
        XCTAssertTrue(cast.transport === b); XCTAssertEqual(cast.session?.title,"B")
        XCTAssertEqual(b.loads,1); XCTAssertEqual(b.stops,0)
        await cast.finish(reason:"synthetic cleanup",stopReceiver:true)
    }
}
#endif
