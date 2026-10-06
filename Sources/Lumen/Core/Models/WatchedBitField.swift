import Compression
import Foundation

/// Port of `stremio-watched-bitfield`: tracks watched episodes as a zlib-compressed bitfield
/// serialized as `{anchorVideoId}:{anchorLength}:{base64}`, compatible with the official apps.
struct WatchedBitField: Hashable, Sendable {
    private(set) var videoIds: [String]
    private var bits: [UInt8]

    init(videoIds: [String]) {
        self.videoIds = videoIds
        bits = Array(repeating: 0, count: (videoIds.count + 7) / 8)
    }

    init?(serialized: String, videoIds: [String]) {
        var components = serialized.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3 else { return nil }
        let packed = components.removeLast()
        guard let anchorLength = Int(components.removeLast()) else { return nil }
        let anchorId = components.joined(separator: ":")

        self.init(videoIds: videoIds)
        guard let anchorIndex = videoIds.firstIndex(of: anchorId) else { return }
        guard let data = Data(base64Encoded: packed), let inflated = Zlib.inflate(data) else { return }
        let previous = [UInt8](inflated)
        let offset = (anchorLength - 1) - anchorIndex
        func previousBit(_ i: Int) -> Bool {
            guard i >= 0, i < anchorLength, i / 8 < previous.count else { return false }
            return previous[i / 8] & (1 << (i % 8)) != 0
        }
        for index in videoIds.indices where previousBit(index + offset) {
            set(index, true)
        }
    }

    /// Video ids in the canonical order used for bit indices (season, episode, release date).
    static func orderedVideoIds(_ videos: [Video]) -> [String] {
        func key(_ video: Video) -> (Int64, Int64, Int64) {
            let hasSeriesInfo = video.season != nil && video.episode != nil
            return (
                hasSeriesInfo ? Int64(video.season!) : Int64.min,
                hasSeriesInfo ? Int64(video.episode!) : Int64.min,
                video.released.map { Int64($0.timeIntervalSince1970 * 1000) } ?? Int64.min
            )
        }
        return videos.enumerated()
            .sorted { lhs, rhs in
                let a = key(lhs.element), b = key(rhs.element)
                if a != b { return a < b }
                return lhs.offset < rhs.offset
            }
            .map(\.element.id)
    }

    func get(_ index: Int) -> Bool {
        guard index >= 0, index / 8 < bits.count else { return false }
        return bits[index / 8] & (1 << (index % 8)) != 0
    }

    mutating func set(_ index: Int, _ value: Bool) {
        guard index >= 0, index / 8 < bits.count else { return }
        if value { bits[index / 8] |= (1 << (index % 8)) } else { bits[index / 8] &= ~(1 << (index % 8)) }
    }

    func isWatched(_ videoId: String) -> Bool {
        guard let index = videoIds.firstIndex(of: videoId) else { return false }
        return get(index)
    }

    mutating func setVideo(_ videoId: String, watched: Bool) {
        guard let index = videoIds.firstIndex(of: videoId) else { return }
        set(index, watched)
    }

    func serialize() -> String? {
        guard !videoIds.isEmpty, let packed = Zlib.deflate(Data(bits)) else { return nil }
        var lastIndex = 0
        for index in stride(from: videoIds.count - 1, through: 0, by: -1) where get(index) {
            lastIndex = index
            break
        }
        return "\(videoIds[lastIndex]):\(lastIndex + 1):\(packed.base64EncodedString())"
    }
}

/// zlib (RFC 1950) wrappers around Apple's raw-deflate Compression API.
enum Zlib {
    static func inflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return Data() }
        // Skip the 2-byte zlib header; the trailing adler32 is ignored by the raw decoder.
        return process(data.dropFirst(2), operation: COMPRESSION_STREAM_DECODE)
    }

    static func deflate(_ data: Data) -> Data? {
        guard let body = process(data, operation: COMPRESSION_STREAM_ENCODE) else { return nil }
        var result = Data([0x78, 0x9C])
        result.append(body)
        let checksum = adler32(data)
        result.append(contentsOf: [UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF), UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)])
        return result
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static func process(_ input: Data, operation: compression_stream_operation) -> Data? {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPointer) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var output = Data()
        let source = [UInt8](input)
        return source.withUnsafeBufferPointer { sourceBuffer -> Data? in
            streamPointer.pointee.src_ptr = sourceBuffer.baseAddress ?? UnsafePointer(buffer)
            streamPointer.pointee.src_size = source.count
            while true {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = bufferSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: bufferSize - streamPointer.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return output
                default: return nil
                }
            }
        }
    }
}
