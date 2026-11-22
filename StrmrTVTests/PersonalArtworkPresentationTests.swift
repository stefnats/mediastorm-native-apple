import Foundation
import XCTest
@testable import StrmrTV

@MainActor
final class PersonalArtworkPresentationTests: XCTestCase {
    private func card() throws -> HomeCard {
        let target = DetailsTarget(try ContentArtworkFixture.title())
        return HomeCard(id:"original-card",target:target,title:"Original title",subtitle:"Original subtitle",
            overview:"Original overview",artworkURL:"original-landscape",progress:0.37)
    }
    func testActualHomeProjectionChangesOnlyPicturesNotPlaybackIdentityOrProgress() async throws {
        let api = ContentArtworkTestAPI()
        api.values = [ContentArtworkFixture.preference(poster:ContentArtworkFixture.poster,backdrop:ContentArtworkFixture.backdrop)]
        let store = await ContentArtworkFixture.store(api), original = try card()
        let projected = original.personalArtwork(using:store)
        XCTAssertEqual(projected.posterURL,ContentArtworkFixture.poster)
        XCTAssertEqual(projected.backdropURL,ContentArtworkFixture.backdrop)
        XCTAssertEqual(projected.artworkURL,ContentArtworkFixture.backdrop)
        XCTAssertEqual(projected.id,original.id); XCTAssertEqual(projected.link,original.link)
        XCTAssertEqual(projected.title,original.title); XCTAssertEqual(projected.subtitle,original.subtitle)
        XCTAssertEqual(projected.progress,0.37); XCTAssertEqual(projected.overview,original.overview)
        XCTAssertEqual(original.artworkURL,"original-landscape")
    }
    func testEpisodeStillAndProgrammeIdentityStayUnchanged() async throws {
        let api = ContentArtworkTestAPI()
        api.values = [ContentArtworkFixture.preference(poster:ContentArtworkFixture.poster,backdrop:ContentArtworkFixture.backdrop)]
        let store = await ContentArtworkFixture.store(api)
        var original = try card()
        original.episode = CardEpisode(seasonNumber:1,episodeNumber:2,name:"Actual E02",itemId:"episode-2")
        original.artworkURL = "episode-2-still"
        let projected = original.personalArtwork(using:store)
        XCTAssertEqual(projected.episode,original.episode); XCTAssertEqual(projected.artworkURL,"episode-2-still")
        XCTAssertEqual(projected.progress,original.progress); XCTAssertEqual(projected.link,original.link)
        XCTAssertEqual(projected.backdropURL,ContentArtworkFixture.backdrop)
    }
    func testProductionPosterLandscapeAndHeroHelpersUseConfirmedProfilePictures() async throws {
        let api = ContentArtworkTestAPI()
        api.values = [ContentArtworkFixture.preference(poster:ContentArtworkFixture.poster,backdrop:ContentArtworkFixture.backdrop)]
        let store = await ContentArtworkFixture.store(api), original = try card()
        XCTAssertEqual(PosterCard.artURL(try XCTUnwrap(original.target),artwork:store)?.absoluteString,ContentArtworkFixture.poster)
        XCTAssertEqual(LandscapeCard.artURL(original,poster:false,artwork:store)?.absoluteString,ContentArtworkFixture.backdrop)
        let hero = HeroContent(original,artwork:store)
        XCTAssertEqual(hero.backdropURL,ContentArtworkFixture.backdrop)
        XCTAssertEqual(hero.id,original.id); XCTAssertEqual(hero.title,original.title)
        store.confirmSaved(api.context,titleID:"tt123",value:ContentArtworkFixture.preference())
        XCTAssertEqual(PosterCard.artURL(try XCTUnwrap(original.target),artwork:store)?.absoluteString,"https://images.invalid/text.jpg")
        XCTAssertEqual(LandscapeCard.artURL(original,poster:false,artwork:store)?.absoluteString,"original-landscape")
        XCTAssertEqual(HeroContent(original,artwork:store).backdropURL,"https://images.invalid/standard-back.jpg")
    }
    func testProviderLogoAndAggregateTilesNeverAdoptTitleImages() async {
        let api = ContentArtworkTestAPI(), store = await ContentArtworkFixture.store(api)
        let source = HomeCard(id:"source",link:.action(.search),title:"Provider",subtitle:"",backdropURL:"provider",logoTile:true)
        XCTAssertEqual(source.personalArtwork(using:store),source)
    }
}
