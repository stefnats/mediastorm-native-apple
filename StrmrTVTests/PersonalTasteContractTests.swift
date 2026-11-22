import Foundation
import XCTest
@testable import StrmrTV

@MainActor
enum PersonalTasteFixture {
    static func context(_ profile: String = "original", proof: String = "original-proof") -> SourceActionContext {
        SourceActionContext(baseURL: URL(string:"https://synthetic.invalid/base")!, profileID:profile,
            clientID:"client", sessionToken:"synthetic-session", unlock:proof)
    }
    static func title(_ id: String = "tt123", kind: String = "movie", tmdb: Int? = nil) throws -> Title {
        var value: [String:Any] = ["id":id,"name":"Synthetic \(id)","mediaType":kind]
        if let tmdb { value["tmdbId"] = tmdb }
        return try JSONDecoder().decode(Title.self,from:JSONSerialization.data(withJSONObject:value))
    }
    static func reply(status: String = "new", source: String = "", titles: [Title] = [],
                      available: Bool = true, history: Bool = false, kinds: [String] = ["movie","series"]) -> TasteSetupReply {
        TasteSetupReply(status:status,source:source,titles:titles,available:available,canUseHistory:history,mediaTypes:kinds)
    }
    static func body(_ request: URLRequest) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(request.httpBody)) as? [String:Any])
    }
}

/// Finite client-state fixture, not a replacement for server authorization.
@MainActor
final class PersonalTasteTestAPI: PersonalTasteAPI {
    enum Failure: Error { case unknownAcknowledgement }
    var context = PersonalTasteFixture.context()
    var rating: PersonalTitleRating = .none
    var setup = PersonalTasteFixture.reply()
    var events: [String] = []
    var contexts: [SourceActionContext] = []
    var rateRead: (() async throws -> PersonalTitleRating)?
    var rateWrite: ((PersonalTitleRating) async throws -> PersonalTitleRating)?
    var setupRead: (() async throws -> TasteSetupReply)?
    var setupWrite: ((String,[Title]) async throws -> TasteSetupReply)?
    var candidateRead: ((String,String) async throws -> [Title])?
    var setupDelete: (() async throws -> TasteSetupReply)?
    func isCurrent(_ context: SourceActionContext) -> Bool { context == self.context }
    func readRating(_ target: DetailsTarget, context: SourceActionContext) async throws -> PersonalTitleRating {
        events.append("rating-read"); contexts.append(context)
        if let rateRead { return try await rateRead() }
        return rating
    }
    func setRating(_ value: PersonalTitleRating, target: DetailsTarget, context: SourceActionContext) async throws -> PersonalTitleRating {
        events.append("rating-\(value.rawValue)"); contexts.append(context)
        if let rateWrite { return try await rateWrite(value) }
        rating = value
        return value
    }
    func readTasteSetup(_ context: SourceActionContext) async throws -> TasteSetupReply {
        events.append("setup-read"); contexts.append(context)
        if let setupRead { return try await setupRead() }
        return setup
    }
    func tasteCandidates(_ context: SourceActionContext, kind: String, query: String) async throws -> [Title] {
        events.append("candidates-\(kind)-\(query)"); contexts.append(context)
        if let candidateRead { return try await candidateRead(kind,query) }
        return []
    }
    func saveTasteSetup(_ context: SourceActionContext, action: String, titles: [Title]) async throws -> TasteSetupReply {
        events.append("setup-\(action)"); contexts.append(context)
        if let setupWrite { return try await setupWrite(action,titles) }
        setup = PersonalTasteFixture.reply(status:action == "skip" ? "skipped" : "completed",
            source:action == "skip" ? setup.source : action == "save" ? "manual" : "history",
            titles:action == "skip" ? setup.titles : titles,history:setup.canUseHistory)
        return setup
    }
    func clearTasteSetup(_ context: SourceActionContext) async throws -> TasteSetupReply {
        events.append("setup-delete"); contexts.append(context)
        if let setupDelete { return try await setupDelete() }
        setup = PersonalTasteFixture.reply()
        return setup
    }
}

@MainActor
final class PersonalTasteContractTests: XCTestCase {
    func testRatingWireUsesActualProfileTitleAndOnlyPersonalEnum() throws {
        let original = PersonalTasteFixture.context(), target = DetailsTarget(try PersonalTasteFixture.title("tt123"))
        let read = try PersonalTasteWire.ratingRequest(nil,target:target,context:original)
        XCTAssertEqual(read.httpMethod,"GET"); XCTAssertNil(read.httpBody)
        for rating in PersonalTitleRating.allCases {
            let write = try PersonalTasteWire.ratingRequest(rating,target:target,context:original)
            XCTAssertEqual(write.httpMethod,"PUT"); XCTAssertEqual(write.url?.path,"/base/api/users/original/ratings/movie/tt123")
            XCTAssertEqual(write.value(forHTTPHeaderField:"X-Profile-Unlock"),"original-proof")
            XCTAssertEqual(write.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-session")
            XCTAssertEqual(try PersonalTasteFixture.body(write) as NSDictionary,["rating":rating.rawValue] as NSDictionary)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(PersonalTitleRating.self,from:Data("\"five-stars\"".utf8)))
    }
    func testSetupSkipHistoryResetAndExplicitEmptySaveHaveDifferentRequests() throws {
        let context = PersonalTasteFixture.context()
        let empty = try PersonalTasteWire.setupRequest(context,action:"save")
        let fields = try PersonalTasteFixture.body(empty)
        XCTAssertEqual(Set(fields.keys),["action","titles"])
        XCTAssertEqual((fields["titles"] as? [Any])?.count,0)
        for action in ["skip","history"] {
            let request = try PersonalTasteWire.setupRequest(context,action:action)
            XCTAssertEqual(Set(try PersonalTasteFixture.body(request).keys),["action"])
        }
        let reset = try PersonalTasteWire.setupRequest(context,clear:true)
        XCTAssertEqual(reset.httpMethod,"DELETE"); XCTAssertNil(reset.httpBody)
        XCTAssertEqual(reset.url?.path,"/base/api/users/original/taste-onboarding")
        XCTAssertThrowsError(try PersonalTasteWire.setupRequest(context,action:"save",clear:true))
    }
    func testSetupSendsDeliveredCoordinatesAndBoundsFortyTitles() throws {
        let a = try PersonalTasteFixture.title("show",kind:"tv"), context = PersonalTasteFixture.context()
        let write = try PersonalTasteWire.setupRequest(context,action:"save",titles:[a])
        let titles = try XCTUnwrap(PersonalTasteFixture.body(write)["titles"] as? [[String:String]])
        XCTAssertEqual(titles,[["titleId":"show","mediaType":"series"]])
        XCTAssertNoThrow(try PersonalTasteWire.setupRequest(context,action:"save",titles:Array(repeating:a,count:40)))
        XCTAssertThrowsError(try PersonalTasteWire.setupRequest(context,action:"save",titles:Array(repeating:a,count:41)))
        XCTAssertThrowsError(try PersonalTasteWire.setupRequest(context,action:"history",titles:[a]))
        XCTAssertThrowsError(try PersonalTasteWire.setupRequest(context,titles:[a]))
    }
    func testCandidateSearchKeepsBasePathOriginalHeadersAndRealQuery() throws {
        let request = try PersonalTasteWire.candidatesRequest(PersonalTasteFixture.context(),kind:"series",query:"  A&B + Ü  ")
        XCTAssertEqual(request.url?.path,"/base/api/users/original/taste-onboarding/candidates")
        let query = try XCTUnwrap(URLComponents(url:XCTUnwrap(request.url),resolvingAgainstBaseURL:false)?.queryItems)
        XCTAssertEqual(query.first(where:{$0.name == "kind"})?.value,"series")
        XCTAssertEqual(query.first(where:{$0.name == "q"})?.value,"A&B + Ü")
        XCTAssertEqual(request.value(forHTTPHeaderField:"X-Client-ID"),"client")
        XCTAssertThrowsError(try PersonalTasteWire.candidatesRequest(PersonalTasteFixture.context(),kind:"episode",query:""))
        XCTAssertThrowsError(try PersonalTasteWire.candidatesRequest(PersonalTasteFixture.context(),kind:"movie",query:String(repeating:"ü",count:201)))
    }
    func testReplyValidationNeverManufacturesAvailabilityOrAcceptsUnknownStatus() throws {
        XCTAssertNoThrow(try PersonalTasteFixture.reply(available:false,kinds:[]).validate())
        XCTAssertThrowsError(try PersonalTasteFixture.reply(status:"guessed").validate())
        XCTAssertThrowsError(try PersonalTasteFixture.reply(source:"external").validate())
        XCTAssertThrowsError(try PersonalTasteFixture.reply(kinds:[]).validate())
        XCTAssertThrowsError(try PersonalTasteFixture.reply(kinds:["movie","movie"]).validate())
        XCTAssertThrowsError(try PersonalTasteFixture.reply(titles:Array(repeating:PersonalTasteFixture.title(),count:41)).validate())
    }
    func testAliasDedupRetainsMovieVersusSeriesIdentity() throws {
        let a = try PersonalTasteFixture.title("tt1",tmdb:12), b = try PersonalTasteFixture.title("tmdb:12",tmdb:12)
        XCTAssertTrue(PersonalTasteWire.same(a,b))
        XCTAssertFalse(PersonalTasteWire.same(a,try PersonalTasteFixture.title("tt1",kind:"series",tmdb:12)))
    }
}
