import XCTest
@testable import Lumen

final class RealDebridTests: XCTestCase {
    private let hashA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let hashB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func torrentio(_ hash: String, _ name: String) -> Lumen.Stream {
        Lumen.Stream(source: .url(URL(string: "https://torrentio.strem.fun/resolve/realdebrid/TOKEN/\(hash)/null/0/file.mkv")!),
                     name: name)
    }

    private func comet(_ hash: String, _ name: String) -> Lumen.Stream {
        Lumen.Stream(source: .url(URL(string: "https://comet.elfhosted.com/playback/\(hash)/0/n/n/n?name=x")!), name: name)
    }

    func testFindsHashInPlaybackURLs() {
        XCTAssertEqual(RealDebrid.infoHash(of: torrentio(hashA.uppercased(), "")), hashA)
        XCTAssertEqual(RealDebrid.infoHash(of: comet(hashB, "")), hashB)
        let notice = Lumen.Stream(source: .url(URL(string: "https://torrentio.strem.fun/videos/failed_access_v3.mp4")!))
        XCTAssertNil(RealDebrid.infoHash(of: notice))
    }

    func testMergeRanksCachedThenResolutionAndDedupes() {
        let merged = RealDebrid.merge([
            [torrentio(hashA, "[RD download] Torrentio\n4k"), torrentio(hashB, "[RD+] Torrentio\n1080p")],
            [comet(hashB, "[RD⚡] Comet 1080p"), comet(hashA, "[RD⚡] Comet 2160p")],
        ])
        // Comet's cached copy of A outranks Torrentio's uncached one. B appears once: both copies are
        // cached 1080p, and Comet lists its copy higher.
        XCTAssertEqual(merged.map(\.displayName), ["[RD⚡] Comet 2160p", "[RD⚡] Comet 1080p"])
    }

    func testCometConfigIsBase64InFirstPathSegment() throws {
        let url = try XCTUnwrap(RealDebrid.Source.comet.streamURL(token: "ABC123", type: "movie", id: "tt0111161"))
        let segment = url.pathComponents[1]
        let json = try XCTUnwrap(Data(base64Encoded: segment)).flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertTrue(json?.contains(#""apiKey":"ABC123""#) == true)
        XCTAssertEqual(url.path.hasSuffix("/stream/movie/tt0111161.json"), true)
    }

    func testTorrentioURL() {
        XCTAssertEqual(RealDebrid.Source.torrentio.streamURL(token: "ABC123", type: "series", id: "tt0903747:1:1")?.absoluteString,
                       "https://torrentio.strem.fun/realdebrid=ABC123/stream/series/tt0903747%3A1%3A1.json")
    }

    func testBuiltInAddonNeedsTokenAndSource() {
        var settings = AppSettings()
        XCTAssertNil(RealDebrid.addon(for: settings))
        settings.realDebridToken = "ABC123"
        let addon = RealDebrid.addon(for: settings)
        XCTAssertEqual(addon?.supports(resource: "stream", type: "series", id: "tt0903747:1:1"), true)
        settings.realDebridSources = []
        XCTAssertNil(RealDebrid.addon(for: settings))
        settings.realDebridSources = ["comet"]
        settings.realDebridToken = "not a token"
        XCTAssertNil(RealDebrid.addon(for: settings))
    }
}
