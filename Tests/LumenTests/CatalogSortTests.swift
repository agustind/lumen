import XCTest
@testable import Lumen

@MainActor
final class CatalogSortTests: XCTestCase {
    func testSortsByRatingWithUnratedLastAndStableTies() throws {
        // Cinemeta sends ratings as strings, sometimes empty.
        let json = #"""
        [{"id":"tt1","type":"movie","name":"A","imdbRating":"7.1"},
         {"id":"tt2","type":"movie","name":"B","imdbRating":""},
         {"id":"tt3","type":"movie","name":"C","imdbRating":8.4},
         {"id":"tt4","type":"movie","name":"D","imdbRating":"7.1"},
         {"id":"tt5","type":"movie","name":"E"}]
        """#
        let items = try JSON.decoder.decode([MetaItem].self, from: Data(json.utf8))
        XCTAssertEqual(CatalogGridModel.sortedByRating(items).map(\.name), ["C", "A", "D", "B", "E"])
    }
}
