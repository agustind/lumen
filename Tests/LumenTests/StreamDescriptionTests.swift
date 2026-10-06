import XCTest
@testable import Lumen

final class StreamDescriptionTests: XCTestCase {
    private func stream(_ description: String) -> Lumen.Stream {
        var stream = Lumen.Stream(source: .url(URL(string: "https://example.com/video.mkv")!))
        stream.description = description
        return stream
    }

    func testSplitsTorrentioDescriptionAroundStats() {
        let parts = stream("The Matrix 1999 UHD Blu-ray 2160p HDR Remux Multi Atmos 7.1-DTOne\n👤 100 💾 51.3 GB ⚙️ 1337x\nMulti Audio / 🇬🇧 / 🇮🇹")
            .descriptionParts
        XCTAssertEqual(parts.title, "The Matrix 1999 UHD Blu-ray 2160p HDR Remux Multi Atmos 7.1-DTOne")
        XCTAssertEqual(parts.stats, "👤 100 💾 51.3 GB ⚙️ 1337x")
        XCTAssertEqual(parts.extra, "Multi Audio / 🇬🇧 / 🇮🇹")
    }

    func testKeepsPackAndFileNameLinesInTitle() {
        let parts = stream("[PACK] The Matrix 4K UHD Collection (1999-2003)\nThe Matrix (1999) [4KLiGHT].mkv\n👤 80 💾 4.98 GB ⚙️ 1337x")
            .descriptionParts
        XCTAssertEqual(parts.title, "[PACK] The Matrix 4K UHD Collection (1999-2003)\nThe Matrix (1999) [4KLiGHT].mkv")
        XCTAssertEqual(parts.stats, "👤 80 💾 4.98 GB ⚙️ 1337x")
        XCTAssertNil(parts.extra)
    }

    func testDescriptionWithoutStatsIsAllTitle() {
        let parts = stream("1080p WEB-DL\nEnglish").descriptionParts
        XCTAssertEqual(parts, Lumen.Stream.DescriptionParts(title: "1080p WEB-DL\nEnglish"))
    }
}
