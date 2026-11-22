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
}
