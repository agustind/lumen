import XCTest
@testable import Lumen

final class WatchedBitFieldTests: XCTestCase {
    /// Vectors produced by the reference JS implementation (stremio-watched-bitfield).
    func testParsesReferenceSerialization() throws {
        let ids = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c"]
        let field = try XCTUnwrap(WatchedBitField(serialized: "c:12:eJw7wA8AAZEA0A==", videoIds: ids))
        XCTAssertEqual(ids.map { field.isWatched($0) }, [false, false, false, false, false, false, true, true, true, true, true, true])
    }

    func testParsesLargeReferenceSerialization() throws {
        let ids = (0..<500).map { "tt1:\($0 / 20 + 1):\($0 % 20 + 1)" }
        let field = try XCTUnwrap(WatchedBitField(serialized: "tt1:21:4:404:eJz7/x8IGGQYiAf8yBwANxwFJw==", videoIds: ids))
        for index in 0..<500 {
            let expected = index < 40 || (50..<53).contains(index) || (400..<404).contains(index)
            XCTAssertEqual(field.get(index), expected, "index \(index)")
        }
    }

    func testRoundTripAndAnchorShift() throws {
        var field = WatchedBitField(videoIds: ["a", "b", "c", "d"])
        field.setVideo("b", watched: true)
        field.setVideo("c", watched: true)
        let serialized = try XCTUnwrap(field.serialize())
        XCTAssertTrue(serialized.hasPrefix("c:3:"))

        // A new episode prepended (e.g. a special) shifts indices; the anchor keeps them aligned.
        let shifted = try XCTUnwrap(WatchedBitField(serialized: serialized, videoIds: ["z", "a", "b", "c", "d", "e"]))
        XCTAssertEqual(["z", "a", "b", "c", "d", "e"].map { shifted.isWatched($0) }, [false, false, true, true, false, false])
    }

    func testOrdersVideosLikeCore() {
        var a = Video(id: "s2e1", title: "", season: 2, episode: 1)
        var b = Video(id: "s1e2", title: "", season: 1, episode: 2)
        let c = Video(id: "s1e1", title: "", season: 1, episode: 1)
        a.released = nil
        b.released = nil
        XCTAssertEqual(WatchedBitField.orderedVideoIds([a, b, c]), ["s1e1", "s1e2", "s2e1"])
    }
}

final class AddonProtocolTests: XCTestCase {
    func testOfficialAddonsDecode() {
        let addons = ProfileStore.officialAddons
        XCTAssertGreaterThanOrEqual(addons.count, 5)
        let cinemeta = addons.first { $0.manifest.id == "com.linvo.cinemeta" }
        XCTAssertNotNil(cinemeta)
        XCTAssertTrue(cinemeta!.supports(resource: "meta", type: "series", id: "tt0903747"))
        XCTAssertFalse(cinemeta!.supports(resource: "meta", type: "series", id: "kitsu:1"))
        XCTAssertTrue(cinemeta!.manifest.catalogs.contains { $0.isBoardCatalog })
        XCTAssertTrue(cinemeta!.manifest.catalogs.contains { $0.isSearchCatalog })
    }

    func testManifestRoundTripsVerbatim() throws {
        let json = #"{"id":"x","version":"1.0.0","name":"X","resources":["stream"],"types":["movie"],"customField":{"a":[1,2]}}"#
        let manifest = try JSON.decoder.decode(Manifest.self, from: Data(json.utf8))
        let reencoded = try JSONSerialization.jsonObject(with: JSON.encoder.encode(manifest)) as! [String: Any]
        XCTAssertNotNil(reencoded["customField"])
        XCTAssertEqual(manifest.name, "X")
    }

    func testResourceURLEncoding() throws {
        let addon = ProfileStore.officialAddons.first { $0.manifest.id == "com.linvo.cinemeta" }!
        let url = try AddonClient.resourceURL(addon: addon, resource: "catalog", type: "movie", id: "top",
                                              extra: [("search", "the office & co"), ("skip", "100")])
        XCTAssertEqual(url.absoluteString, "https://v3-cinemeta.strem.io/catalog/movie/top/search=the%20office%20%26%20co&skip=100.json")
        let meta = try AddonClient.resourceURL(addon: addon, resource: "stream", type: "series", id: "tt0903747:1:2")
        XCTAssertEqual(meta.absoluteString, "https://v3-cinemeta.strem.io/stream/series/tt0903747%3A1%3A2.json")
    }

    func testLegacyCatalogExtras() throws {
        let json = #"{"type":"movie","id":"top","genres":["Action"],"extraSupported":["genre","skip"],"extraRequired":["genre"]}"#
        let catalog = try JSON.decoder.decode(ManifestCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.extra(named: "genre")?.options, ["Action"])
        XCTAssertEqual(catalog.extra(named: "genre")?.isRequired, true)
        XCTAssertFalse(catalog.isBoardCatalog)
    }

    func testStreamSources() throws {
        let json = #"""
        {"streams":[
          {"name":"Torrentio\n4K","title":"Movie.2160p.mkv\n👤 10","infoHash":"ABCDEF0123456789ABCDEF0123456789ABCDEF01","fileIdx":2,"sources":["tracker:udp://t.example:80"],"behaviorHints":{"bingeGroup":"torrentio|4k"}},
          {"url":"https://example.com/video.mp4","name":"Direct"},
          {"ytId":"VFkjBy2b50Q"},
          {"externalUrl":"https://netflix.com/title/1"},
          {"nothing":"here"}
        ]}
        """#
        let streams = try JSON.decoder.decode(StreamsResponse.self, from: Data(json.utf8)).streams
        XCTAssertEqual(streams.count, 4, "invalid streams are skipped")
        guard case let .torrent(hash, idx, announce, _) = streams[0].source else { return XCTFail() }
        XCTAssertEqual(hash, "abcdef0123456789abcdef0123456789abcdef01")
        XCTAssertEqual(idx, 2)
        XCTAssertEqual(announce, ["tracker:udp://t.example:80"])
        XCTAssertEqual(streams[0].behaviorHints.bingeGroup, "torrentio|4k")
        XCTAssertTrue(streams[1].isPlayableInApp)
        XCTAssertFalse(streams[3].isPlayableInApp)
    }

    func testMagnetParsing() throws {
        let url = URL(string: "magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01&dn=Some%20Movie&tr=udp%3A%2F%2Ftracker.example%3A80")!
        let stream = try XCTUnwrap(Stream.fromMagnet(url))
        XCTAssertEqual(stream.name, "Some Movie")
        guard case let .torrent(hash, _, announce, _) = stream.source else { return XCTFail() }
        XCTAssertEqual(hash, "abcdef0123456789abcdef0123456789abcdef01")
        XCTAssertEqual(announce, ["tracker:udp://tracker.example:80"])
    }

    func testMetaDecodingIsLenient() throws {
        let json = #"""
        {"meta":{"id":"tt0903747","type":"series","name":"Breaking Bad","imdbRating":9.5,"releaseInfo":2008,
         "links":[{"name":"Crime","category":"Genres","url":"stremio:///discover/x/series/top?genre=Crime"},{"name":"Bryan Cranston","category":"Cast"}],
         "videos":[{"id":"tt0903747:1:2","name":"Cat's in the Bag...","season":1,"number":2,"firstAired":"2008-01-28T05:00:00.000Z"},
                   {"id":"tt0903747:1:1","title":"Pilot","season":"1","episode":1,"released":"2008-01-21T05:00:00.000Z"},
                   {"id":"tt0903747:0:1","title":"Special","season":0,"episode":1}],
         "trailers":[{"source":"VFkjBy2b50Q","type":"Trailer"}],
         "poster":42}}
        """#
        let meta = try JSON.decoder.decode(MetaResponse.self, from: Data(json.utf8)).meta
        XCTAssertEqual(meta.imdbRating, "9.5")
        XCTAssertEqual(meta.releaseInfo, "2008")
        XCTAssertNil(meta.poster)
        XCTAssertEqual(meta.allGenres, ["Crime"])
        XCTAssertEqual(meta.allCast, ["Bryan Cranston"])
        XCTAssertEqual(meta.seasons, [1, 0])
        XCTAssertEqual(meta.videos(inSeason: 1).map(\.id), ["tt0903747:1:1", "tt0903747:1:2"])
        XCTAssertEqual(meta.nextVideo(after: "tt0903747:1:1")?.id, "tt0903747:1:2")
        XCTAssertNil(meta.nextVideo(after: "tt0903747:1:2"), "does not roll into specials")
        XCTAssertEqual(meta.trailerStreams.count, 1)
    }
}

final class LibraryItemTests: XCTestCase {
    func testDecodesAndEncodesAPIShape() throws {
        let json = #"""
        {"_id":"tt0903747","name":"Breaking Bad","type":"series","poster":"https://x/p.jpg","posterShape":"poster",
         "removed":false,"temp":false,"_ctime":"2020-01-01T00:00:00.000Z","_mtime":"2024-05-06T07:08:09.123Z",
         "state":{"lastWatched":"2024-05-06T07:08:09.123Z","timeWatched":1000,"timeOffset":2000,"overallTimeWatched":3000,
                  "timesWatched":1,"flaggedWatched":0,"duration":4000,"video_id":"tt0903747:1:1","watched":"","noNotif":false},
         "behaviorHints":{"defaultVideoId":null}}
        """#
        let item = try JSON.decoder.decode(LibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.state.videoId, "tt0903747:1:1")
        XCTAssertNil(item.state.watched)
        XCTAssertTrue(item.isInLibrary)
        XCTAssertTrue(item.isInContinueWatching)
        XCTAssertEqual(item.progress, 0.5)

        let encoded = try JSONSerialization.jsonObject(with: JSON.encoder.encode(item)) as! [String: Any]
        XCTAssertEqual(encoded["_id"] as? String, "tt0903747")
        XCTAssertEqual(encoded["_mtime"] as? String, "2024-05-06T07:08:09.123Z")
        let state = encoded["state"] as! [String: Any]
        XCTAssertEqual(state["video_id"] as? String, "tt0903747:1:1")
        XCTAssertEqual(state["timeOffset"] as? Int, 2000)
    }
}

final class InteropOutputTests: XCTestCase {
    /// Our serialization must be byte-identical to stremio-watched-bitfield's (JS) output.
    func testSerializationMatchesReferenceImplementation() throws {
        let ids = (0..<500).map { "tt1:\($0 / 20 + 1):\($0 % 20 + 1)" }
        var field = WatchedBitField(videoIds: ids)
        for index in 0..<500 where index < 40 || (50..<53).contains(index) || (400..<404).contains(index) { field.set(index, true) }
        XCTAssertEqual(try XCTUnwrap(field.serialize()), "tt1:21:4:404:eJz7/x8IGGQYiAf8yBwANxwFJw==")
    }
}

final class StreamAddonPreferenceTests: XCTestCase {
    private func addon(_ name: String, url: String, id: String = "com.stremio.torrentio.addon") throws -> AddonDescriptor {
        let json = #"{"id":"\#(id)","version":"1.0.0","name":"\#(name)","resources":["stream"],"types":["movie"]}"#
        return AddonDescriptor(manifest: try JSON.decoder.decode(Manifest.self, from: Data(json.utf8)), transportUrl: url)
    }

    func testAutomaticPrefersTorrentioRealDebrid() throws {
        let plain = try addon("Torrentio", url: "https://torrentio.strem.fun/manifest.json")
        let rd = try addon("Torrentio RD", url: "https://torrentio.strem.fun/sort=qualitysize|realdebrid=KEY/manifest.json")
        let other = try addon("WatchHub", url: "https://watchhub.strem.io/manifest.json", id: "org.stremio.watchhub")
        XCTAssertEqual(StreamAddonPreference.preferred(among: [other, plain, rd], setting: "auto")?.transportUrl, rd.transportUrl)
        XCTAssertNil(StreamAddonPreference.preferred(among: [other, plain], setting: "auto"), "plain Torrentio is not pre-selected")
        XCTAssertNil(StreamAddonPreference.preferred(among: [other], setting: "auto"))
        XCTAssertNil(StreamAddonPreference.preferred(among: [other, rd], setting: ""))
        XCTAssertEqual(StreamAddonPreference.preferred(among: [other, rd], setting: other.transportUrl)?.transportUrl, other.transportUrl)
    }

    func testDetectsRealDebridFromEncodedURL() throws {
        let encoded = try addon("Torrentio", url: "https://torrentio.strem.fun/realdebrid%3DKEY/manifest.json")
        XCTAssertTrue(StreamAddonPreference.isRealDebrid(encoded))
        let cards = try addon("Torrentio Cards", url: "https://torrentio.strem.fun/manifest.json")
        XCTAssertFalse(StreamAddonPreference.isRealDebrid(cards), "'Cards' must not match 'RD'")
    }
}

final class SubtitleSyncTests: XCTestCase {
    func testParsesSRTAndVTT() {
        let srt = "1\r\n00:01:47,250 --> 00:01:50,500\r\nHello\r\n\r\n2\r\n01:00:00,000 --> 01:00:02,5\r\nBye\r\n"
        XCTAssertEqual(SubtitleSync.parseCues(srt), [.init(start: 107.25, end: 110.5), .init(start: 3600, end: 3602.5)])
        let vtt = "WEBVTT\n\n00:05.000 --> 00:07.250 align:start\nHi\n"
        XCTAssertEqual(SubtitleSync.parseCues(vtt), [.init(start: 5, end: 7.25)])
    }

    /// Speech that matches the cues shifted by a known amount must be recovered.
    func testAlignmentRecoversShift() throws {
        var cues: [SubtitleSync.Cue] = []
        var t = 130.0
        var generator = SystemRandomNumberGenerator()
        while t < 470 {
            let length = Double.random(in: 1...4, using: &generator)
            cues.append(.init(start: t, end: t + length))
            t += length + Double.random(in: 0.5...6, using: &generator)
        }
        let trueShift = 3.4
        let hop = 0.0975
        let origin = 120.0
        let probabilities = (0..<Int(360 / hop)).map { i -> Double in
            let time = origin + Double(i) * hop
            let speaking = cues.contains { time >= $0.start + trueShift && time < $0.end + trueShift }
            return min(1, max(0, (speaking ? 0.85 : 0.1) + Double.random(in: -0.1...0.1, using: &generator)))
        }
        let result = try SubtitleSync.align(speech: .init(origin: origin, hop: hop, probabilities: probabilities), cues: cues)
        XCTAssertEqual(result.scale, 1)
        XCTAssertEqual(result.offset, trueShift + SubtitleSync.detectorLatency, accuracy: 0.15)
    }

    /// End-to-end through ffmpeg + SoundAnalysis on a real file (opt-in: set STREMIO_SYNC_FIXTURE
    /// to an MKV whose embedded subtitle stream 1 is shifted by STREMIO_SYNC_SHIFT seconds).
    func testEndToEndFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["STREMIO_SYNC_FIXTURE"] else { throw XCTSkip("no fixture") }
        let track = MediaTrack(id: "1", kind: .subtitle, codec: "subrip", isExternal: false, ffIndex: 1)
        let result = try await PlayerSession.computeSync(media: URL(fileURLWithPath: path), position: 240, duration: 600,
                                                         subtitleURL: nil, track: track, audioIndex: 0)
        print("END_TO_END offset=\(result.offset) scale=\(result.scale) confidence=\(result.confidence)")
        let shift = Double(ProcessInfo.processInfo.environment["STREMIO_SYNC_SHIFT"] ?? "0") ?? 0
        XCTAssertEqual(result.scale, 1)
        XCTAssertEqual(result.offset, -shift, accuracy: 1.0)
    }
}
