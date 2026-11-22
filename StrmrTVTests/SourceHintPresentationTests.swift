import Foundation
import XCTest
#if os(iOS)
@testable import StrmrMobile
#else
@testable import StrmrTV
#endif

@MainActor
final class SourceHintPresentationTests: XCTestCase {
    func testActualTVAndMobileCardPoliciesKeepReleaseWatchProgressRankAndFocusIdentity() throws {
        let title = try SourceHintFixture.title(SourceHintFixture.raw()), card = HomeCard(title,rank:7)
        XCTAssertEqual(card.sourceAvailability?.state,"not_found")
        XCTAssertEqual(card.badge?.text,"#7"); XCTAssertEqual(card.subtitle,"Chart context")
        XCTAssertEqual(card.target?.titleID,title.id); XCTAssertEqual(card.id,title.id); XCTAssertEqual(card.progress,0)
        XCTAssertEqual(HeroContent(card).sourceAvailability,card.sourceAvailability)
        XCTAssertTrue(card.sourceAvailability?.presentation(at:SourceHintFixture.now).dimArtwork == true)
        XCTAssertFalse(card.target?.suppressAutomaticSourcePreparation == true,"A passive card is not a captured tap")
    }
    func testFreshMissingHeroTapProducesDetailsWithoutAutoplayOrPrewarm() throws {
        let target = DetailsTarget(try SourceHintFixture.title()), hint = try SourceHintFixture.hint()
        let selected = SourceHintNavigation.target(target,hint:hint,now:SourceHintFixture.now)
        XCTAssertTrue(selected.suppressAutomaticSourcePreparation)
        XCTAssertFalse(SourceHintNavigation.autoplay(primary:true,target:selected))
        XCTAssertEqual(selected.titleID,target.titleID); XCTAssertEqual(selected.tmdbID,target.tmdbID)
        XCTAssertFalse(target.suppressAutomaticSourcePreparation)
    }
    func testHeroReevaluatesCurrentHintAtTapRatherThanUsingARenderSnapshot() throws {
        let target = DetailsTarget(try SourceHintFixture.title()), missing = try SourceHintFixture.hint()
        let found = try SourceHintFixture.hint(SourceHintFixture.raw(state:"found"))
        XCTAssertFalse(SourceHintNavigation.target(target,hint:found,now:SourceHintFixture.now).suppressAutomaticSourcePreparation)
        XCTAssertTrue(SourceHintNavigation.target(target,hint:missing,now:SourceHintFixture.now).suppressAutomaticSourcePreparation)
        XCTAssertFalse(SourceHintNavigation.target(target,hint:missing,now:SourceHintFixture.now.addingTimeInterval(301)).suppressAutomaticSourcePreparation)
    }
    func testNegativeTapRemainsNoPrewarmIfHintExpiresBeforeDetailsAppear() throws {
        let target = DetailsTarget(try SourceHintFixture.title()), missing = try SourceHintFixture.hint()
        let selected = SourceHintNavigation.target(target,hint:missing,now:SourceHintFixture.now)
        let later = SourceHintNavigation.target(selected,hint:nil,now:SourceHintFixture.now.addingTimeInterval(400))
        XCTAssertTrue(later.suppressAutomaticSourcePreparation)
        XCTAssertFalse(SourceHintNavigation.autoplay(primary:true,target:later))
    }
    func testUnknownFoundStaleAndUnsupportedHintsPreserveOrdinaryExplicitChoices() throws {
        let target = DetailsTarget(try SourceHintFixture.title())
        for hint in [nil,try SourceHintFixture.hint(SourceHintFixture.raw(state:"unknown")),try SourceHintFixture.hint(SourceHintFixture.raw(state:"found"))] {
            let selected = SourceHintNavigation.target(target,hint:hint,now:SourceHintFixture.now)
            XCTAssertFalse(selected.suppressAutomaticSourcePreparation)
            XCTAssertTrue(SourceHintNavigation.autoplay(primary:true,target:selected))
            XCTAssertFalse(SourceHintNavigation.autoplay(primary:false,target:selected))
        }
    }
    func testVisibleEpisodeMissingWithLocalVersionMeansLocalVersionNeedsChecking() throws {
        let episode = try SourceHintFixture.episode(SourceHintFixture.raw()), hint = try XCTUnwrap(episode.sourceAvailability)
        XCTAssertEqual(hint.presentation(at:SourceHintFixture.now,inLibrary:true).kind,.localNeedsChecking)
        XCTAssertFalse(hint.presentation(at:SourceHintFixture.now,inLibrary:true).dimArtwork)
        XCTAssertTrue(hint.presentation(at:SourceHintFixture.now,inLibrary:false).dimArtwork)
        XCTAssertEqual(episode.itemId,"official-progress-id")
    }
    func testPartialEpisodeCoverageCannotDimAnUnobservedEpisodeOrWholeSeason() throws {
        var raw = SourceHintFixture.raw(state:"found"); raw["episodeCoverage"] = SourceHintFixture.coverage()
        let hint = try SourceHintFixture.hint(raw).presentation(at:SourceHintFixture.now)
        XCTAssertEqual(hint.kind,.partial); XCTAssertFalse(hint.dimArtwork)
        XCTAssertFalse(hint.coverage?.catalogueComplete == true)
        let unobserved = try SourceHintFixture.episode()
        XCTAssertNil(unobserved.sourceAvailability)
    }
    func testAnnotationRenderingNeverAdmitsDemandOrProviderWork() throws {
        let value = try SourceHintFixture.hint(), badge = SourceHintBadge(value:value,inLibrary:true)
        XCTAssertEqual(badge.value,value); XCTAssertTrue(badge.inLibrary)
        let first = value.presentation(at:SourceHintFixture.now)
        let expired = value.presentation(at:SourceHintFixture.now.addingTimeInterval(301))
        XCTAssertTrue(first.dimArtwork); XCTAssertFalse(expired.dimArtwork)
        XCTAssertEqual(value.state,"not_found"); XCTAssertEqual(value.reason,"no_matching_candidates")
        // The actual badge takes immutable annotation data only. This asserts its
        // consumed presentation input, not a SwiftUI/network runtime execution.
    }
    func testActualMobileHeroShelfGridAndEpisodeAdaptersConsumeTheSharedPolicy() throws {
        let title = try SourceHintFixture.title(SourceHintFixture.raw()), card = HomeCard(title)
        let coordinate = try XCTUnwrap(SourceHintAdapters.title(card))
        XCTAssertEqual(SourceHintAdapters.hero(card,visible:true),coordinate)
        XCTAssertNil(SourceHintAdapters.hero(card,visible:false))
        let episode = try SourceHintFixture.episode(SourceHintFixture.raw())
        let actual = try XCTUnwrap(SourceHintAdapters.episode(episode,titleID:"tmdb:series:55"))
        if case let .episode(titleID,numbering,value) = actual {
            XCTAssertEqual(titleID,"tmdb:series:55"); XCTAssertEqual(numbering,episode.numbering)
            XCTAssertEqual(value.episodeId,episode.id); XCTAssertEqual(value.episodeNumber,2)
        } else { XCTFail("Expected actual episode coordinates") }
        #if os(iOS)
        let shelf = MobileCardArt(card:card,landscape:false,size:CGSize(width:116,height:174))
        let hero = MobileHomeHero(card:card,size:CGSize(width:300,height:180))
        let grid = MobileGridCard(card:card)
        let row = MobileEpisodeCard(episode:episode,watched:false,selected:true,progress:0.37,inLibrary:true,
            hidesThumbnail:true,hidesOverview:true,fallbackImage:nil)
        XCTAssertEqual(shelf.card.sourceAvailability,title.sourceAvailability)
        XCTAssertEqual(hero.card.id,card.id); XCTAssertEqual(grid.card.id,card.id)
        XCTAssertEqual(row.episode.id,episode.id); XCTAssertTrue(row.hidesThumbnail)
        #else
        let poster = PosterCard(title:title), landscape = LandscapeCard(card:card)
        XCTAssertEqual(poster.sourceAvailability,title.sourceAvailability)
        XCTAssertEqual(landscape.card.sourceAvailability,title.sourceAvailability)
        #endif
        // Actual renderer inputs and shared consumed adapters, not a claim that
        // SwiftUI layout, scroll clipping or remote focus ran on this host.
    }
    func testDemandOwnersDoNotChangeTitleOrEpisodePlaybackIdentity() async throws {
        let api = SourceHintsFixtureAPI(), context = api.context
        let owner = VisibleSourceHints(context:context,api:api,viewID:"identity",coalesce:.zero,wait:{ duration in
            if duration == .zero { await Task.yield() } else { try await Task.sleep(for:.seconds(3600)) }
        })
        let card = HomeCard(try SourceHintFixture.title(SourceHintFixture.raw()),rank:9), before = card
        let episode = try SourceHintFixture.episode(), original = DetailsRequest.episodeInfo(episode)
        owner.setPage(CGRect(x:0,y:0,width:200,height:200),visible:true)
        owner.record(VisibleSourceRecord(id:UUID(),coordinate:try XCTUnwrap(SourceHintAdapters.title(card)),rect:CGRect(x:0,y:0,width:60,height:90),order:0))
        owner.record(VisibleSourceRecord(id:UUID(),coordinate:try XCTUnwrap(SourceHintAdapters.episode(episode,titleID:"tmdb:series:55")),rect:CGRect(x:70,y:0,width:60,height:90),order:1))
        owner.setActive(true)
        for _ in 0..<1000 where api.requests.count < 2 { await Task.yield() }
        await owner.closeAndDrain()
        XCTAssertEqual(card,before); XCTAssertEqual(card.badge?.text,"#9")
        let after = DetailsRequest.episodeInfo(episode)
        XCTAssertEqual(after.itemID,original.itemID); XCTAssertEqual(after.season,original.season)
        XCTAssertEqual(after.episode,original.episode); XCTAssertEqual(after.numbering,original.numbering)
        XCTAssertEqual(original.itemID,"official-progress-id")
        XCTAssertEqual(owner.selection.episodes.count,0)
        XCTAssertTrue(api.requests.contains{$0.url!.path.contains("/episodes/")})
        XCTAssertTrue(api.requests.allSatisfy{$0.url!.path.contains("/source-availability/")})
        XCTAssertTrue(api.requests.allSatisfy{$0.value(forHTTPHeaderField:"X-Profile-Unlock") == "original-proof"})
    }
}
