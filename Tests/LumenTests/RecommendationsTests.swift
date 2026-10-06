import XCTest
@testable import Lumen

final class RecommendationsTests: XCTestCase {
    func testMetaItemKeepsTMDBId() throws {
        let json = #"{"id":"tt0133093","type":"movie","name":"The Matrix","moviedb_id":603}"#
        let meta = try JSON.decoder.decode(MetaItem.self, from: Data(json.utf8))
        XCTAssertEqual(meta.moviedbId, 603)
        let roundTripped = try JSON.decoder.decode(MetaItem.self, from: JSON.encoder.encode(meta))
        XCTAssertEqual(roundTripped.moviedbId, 603)

        let asString = #"{"id":"tt1","type":"movie","name":"X","moviedb_id":"42"}"#
        XCTAssertEqual(try JSON.decoder.decode(MetaItem.self, from: Data(asString.utf8)).moviedbId, 42)
    }

    func testMapsTMDBResultsToMetaItems() throws {
        let movie = try JSONDecoder().decode(TMDBClient.Result.self, from: Data(
            #"{"id":604,"title":"The Matrix Reloaded","poster_path":"/abc.jpg","release_date":"2003-05-15"}"#.utf8))
        let item = TMDBClient.metaItem(from: movie, imdbId: "tt0234215", type: "movie")
        XCTAssertEqual(item.id, "tt0234215")
        XCTAssertEqual(item.type, "movie")
        XCTAssertEqual(item.name, "The Matrix Reloaded")
        XCTAssertEqual(item.poster?.absoluteString, "https://image.tmdb.org/t/p/w342/abc.jpg")
        XCTAssertEqual(item.releaseInfo, "2003")

        let show = try JSONDecoder().decode(TMDBClient.Result.self, from: Data(
            #"{"id":60059,"name":"Better Call Saul","poster_path":"/x.jpg","first_air_date":"2015-02-08"}"#.utf8))
        let series = TMDBClient.metaItem(from: show, imdbId: "tt3032476", type: "series")
        XCTAssertEqual(series.name, "Better Call Saul")
        XCTAssertEqual(series.releaseInfo, "2015")
    }

    func testFallbackPicksPopularCatalogForGenre() throws {
        let json = #"""
        {"id":"com.linvo.cinemeta","version":"1.0.0","name":"Cinemeta","resources":["catalog"],"types":["movie","series"],
         "catalogs":[
          {"type":"movie","id":"year","extra":[{"name":"genre","isRequired":true,"options":["2024","2023"]}]},
          {"type":"movie","id":"imdbRating","extra":[{"name":"genre","options":["Action","Sci-Fi"]}]},
          {"type":"movie","id":"top","extra":[{"name":"genre","options":["Action","Sci-Fi"]},{"name":"search"}]},
          {"type":"series","id":"top","extra":[{"name":"genre","options":["Drama"]}]},
          {"type":"movie","id":"searchOnly","extra":[{"name":"search","isRequired":true},{"name":"genre","options":["Sci-Fi"]}]}
         ]}
        """#
        let addon = AddonDescriptor(manifest: try JSON.decoder.decode(Manifest.self, from: Data(json.utf8)),
                                    transportUrl: "https://v3-cinemeta.strem.io/manifest.json")

        let match = try XCTUnwrap(Recommendations.genreCatalog(type: "movie", genre: "Sci-Fi", addons: [addon]))
        XCTAssertEqual(match.1.id, "top")
        XCTAssertEqual(match.1.type, "movie")
        XCTAssertEqual(Recommendations.genreCatalog(type: "series", genre: "Drama", addons: [addon])?.1.type, "series")
        XCTAssertNil(Recommendations.genreCatalog(type: "movie", genre: "Western", addons: [addon]))
        XCTAssertNil(Recommendations.genreCatalog(type: "movie", genre: "Drama", addons: [addon]), "series genres don't apply to movies")
    }
}
