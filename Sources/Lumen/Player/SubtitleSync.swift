import AVFoundation
import Foundation
import SoundAnalysis

/// Automatic subtitle synchronisation (the approach of ffsubsync/alass, done natively):
/// detect speech in a slice of the movie's audio with Apple's sound classifier, then find the
/// subtitle offset (and frame-rate scale) whose cues best overlap the detected speech.
enum SubtitleSync {
    struct Cue: Equatable {
        var start: Double
        var end: Double
    }

    /// Speech probability sampled on a regular grid of `hop` seconds, starting at `origin`
    /// (seconds of movie time).
    struct SpeechTrack {
        var origin: Double
        var hop: Double
        var probabilities: [Double]
    }

    struct Result: Equatable {
        /// Seconds to add to subtitle times (mpv `sub-delay`).
        var offset: Double
        /// Multiplier for subtitle times (mpv `sub-speed`), for frame-rate mismatches.
        var scale: Double
        /// Peak prominence; higher is more certain. Below `minimumConfidence` the match is rejected.
        var confidence: Double
    }

    enum SyncError: LocalizedError {
        case noFFmpeg
        case extractionFailed(String)
        case unsupportedSubtitle
        case notEnoughData
        case noReliableMatch

        var errorDescription: String? {
            switch self {
            case .noFFmpeg: return "Auto sync needs ffmpeg (bundled with Stremio, or `brew install ffmpeg`)."
            case .extractionFailed(let message): return "Couldn't read the audio: \(message)"
            case .unsupportedSubtitle: return "This subtitle format can't be auto-synced (image-based subtitles aren't supported)."
            case .notEnoughData: return "Not enough dialogue around this point to sync. Try again during a scene with talking."
            case .noReliableMatch: return "Couldn't find a reliable match. The subtitles may belong to a different cut."
            }
        }
    }

    static let minimumConfidence = 2.2
    /// Measured with synthetic speech at known times: the classifier reports speech ~0.1 s late.
    static let detectorLatency = 0.10

    // MARK: Parsing

    /// Parses SRT and WebVTT cues.
    static func parseCues(_ text: String) -> [Cue] {
        let pattern = #"(\d{1,2}:)?(\d{1,2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}:)?(\d{1,2}):(\d{2})[,.](\d{1,3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var cues: [Cue] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            func time(_ base: Int) -> Double {
                let hours = Double(group(base)?.dropLast() ?? "0") ?? 0
                let minutes = Double(group(base + 1) ?? "0") ?? 0
                let seconds = Double(group(base + 2) ?? "0") ?? 0
                let fraction = group(base + 3) ?? "0"
                let millis = (Double(fraction) ?? 0) / pow(10, Double(fraction.count))
                return hours * 3600 + minutes * 60 + seconds + millis
            }
            let cue = Cue(start: time(1), end: time(5))
            if cue.end > cue.start { cues.append(cue) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: Speech detection

    private final class SpeechObserver: NSObject, SNResultsObserving {
        var points: [(time: Double, probability: Double)] = []
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let center = result.timeRange.start.seconds + result.timeRange.duration.seconds / 2
            points.append((center, result.classification(forIdentifier: "speech")?.confidence ?? 0))
        }
    }

    /// Runs Apple's built-in sound classifier over an audio file. `origin` is the movie time of
    /// the file's first sample.
    static func detectSpeech(in audioFile: URL, origin: Double) throws -> SpeechTrack {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let window = 0.975
        request.windowDuration = CMTime(seconds: window, preferredTimescale: 16000)
        request.overlapFactor = 0.9
        let analyzer = try SNAudioFileAnalyzer(url: audioFile)
        let observer = SpeechObserver()
        try analyzer.add(request, withObserver: observer)
        analyzer.analyze()
        let points = observer.points.sorted { $0.time < $1.time }
        guard points.count > 10 else { throw SyncError.notEnoughData }
        let hop = window * (1 - 0.9)
        // Resample onto a fixed grid (results are already evenly spaced, but be defensive).
        let first = points[0].time
        let count = Int(((points.last!.time - first) / hop).rounded()) + 1
        var grid = [Double](repeating: 0, count: count)
        for point in points {
            let index = Int(((point.time - first) / hop).rounded())
            if index >= 0 && index < count { grid[index] = max(grid[index], point.probability) }
        }
        return SpeechTrack(origin: origin + first, hop: hop, probabilities: grid)
    }

    // MARK: Alignment

    /// Frame-rate conversions that commonly cause drifting subtitles (e.g. a 25 fps PAL
    /// subtitle on a 23.976 fps release).
    static let scaleCandidates: [Double] = [1, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25 / 24, 24 / 25]

    /// Finds the offset/scale maximising overlap between subtitle cues and detected speech.
    /// `searchRange` bounds the offset in seconds (relative to the scaled timeline).
    static func align(speech: SpeechTrack, cues: [Cue], searchRange: Double = 90) throws -> Result {
        let samples = speech.probabilities
        guard samples.count > 100 else { throw SyncError.notEnoughData }
        let mean = samples.reduce(0, +) / Double(samples.count)
        // Prefix sums of the centred signal make each cue's score an O(1) lookup.
        var prefix = [Double](repeating: 0, count: samples.count + 1)
        for (i, value) in samples.enumerated() { prefix[i + 1] = prefix[i] + (value - mean) }
        let windowEnd = speech.origin + Double(samples.count) * speech.hop

        func integral(_ time: Double) -> Double {
            // Linear interpolation of the prefix sum at an arbitrary time.
            let position = (time - speech.origin) / speech.hop
            if position <= 0 { return 0 }
            if position >= Double(samples.count) { return prefix[samples.count] }
            let index = Int(position)
            let fraction = position - Double(index)
            return prefix[index] + fraction * (prefix[index + 1] - prefix[index])
        }

        func score(_ cues: [Cue], offset: Double) -> Double {
            var total = 0.0
            for cue in cues { total += integral(cue.end + offset) - integral(cue.start + offset) }
            return total
        }

        var best: (score: Double, offset: Double, scale: Double, scores: [Double])?
        for scale in scaleCandidates {
            let scaled = cues.map { Cue(start: $0.start * scale, end: $0.end * scale) }
            // Only cues that could land inside the analysed window matter.
            let relevant = scaled.filter { $0.end > speech.origin - searchRange && $0.start < windowEnd + searchRange }
            guard relevant.count >= 6 else { continue }
            let step = speech.hop
            var scores: [Double] = []
            var localBest = (score: -Double.infinity, offset: 0.0)
            var offset = -searchRange
            while offset <= searchRange {
                let s = score(relevant, offset: offset)
                scores.append(s)
                if s > localBest.score { localBest = (s, offset) }
                offset += step
            }
            // A slice of a few minutes can't tell 1.0 from near-1 rates (e.g. 24/23.976), so a
            // different frame rate has to win clearly before we stretch the subtitles.
            let margin = scale == 1 || best == nil ? 1.0 : 1.05
            if best == nil || localBest.score > best!.score * margin {
                best = (localBest.score, localBest.offset, scale, scores)
            }
        }
        guard var winner = best else { throw SyncError.notEnoughData }

        // Refine to 10 ms around the coarse peak.
        let scaled = cues.map { Cue(start: $0.start * winner.scale, end: $0.end * winner.scale) }
        var fine = winner.offset - speech.hop
        while fine <= winner.offset + speech.hop {
            let s = score(scaled, offset: fine)
            if s > winner.score { winner.score = s; winner.offset = fine }
            fine += 0.01
        }

        // Confidence: how far the peak stands above the rest of the offset landscape
        // (excluding its immediate neighbourhood).
        let scores = winner.scores
        let neighbourhood = Int(2 / speech.hop)
        let peakIndex = scores.firstIndex(of: scores.max()!) ?? 0
        let others = scores.enumerated().filter { abs($0.offset - peakIndex) > neighbourhood }.map(\.element)
        let othersMean = others.reduce(0, +) / Double(max(others.count, 1))
        let variance = others.reduce(0) { $0 + pow($1 - othersMean, 2) } / Double(max(others.count, 1))
        let deviation = max(sqrt(variance), 1e-9)
        let runnerUp = others.max() ?? othersMean
        let confidence = min((winner.score - othersMean) / deviation, 50) * (winner.score > runnerUp ? 1 : 0.5)
        // Prominence over the runner-up keeps confident-but-ambiguous peaks out.
        let prominence = (winner.score - othersMean) / max(runnerUp - othersMean, 1e-9)

        let result = Result(offset: ((winner.offset + detectorLatency) * 100).rounded() / 100, scale: winner.scale,
                            confidence: prominence < 1.08 ? min(confidence, minimumConfidence - 0.1) : confidence)
        guard result.confidence >= minimumConfidence else { throw SyncError.noReliableMatch }
        return result
    }

    // MARK: Audio extraction

    static func findFFmpeg() -> URL? {
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("server/ffmpeg").path { candidates.append(bundled) }
        candidates += [
            "/Applications/Stremio.app/Contents/MacOS/ffmpeg",
            NSHomeDirectory() + "/Applications/Stremio.app/Contents/MacOS/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Extracts mono 16 kHz audio for `[start, start + duration)` and, optionally, an embedded
    /// subtitle stream (as SRT, with times relative to `start`).
    static func extract(from media: URL, start: Double, duration: Double, audioStreamIndex: Int?,
                        subtitleStreamIndex: Int?, into directory: URL) async throws -> (audio: URL, subtitles: URL?) {
        guard let ffmpeg = findFFmpeg() else { throw SyncError.noFFmpeg }
        let audio = directory.appendingPathComponent("audio.wav")
        let subtitles = directory.appendingPathComponent("subs.srt")
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                         "-ss", String(format: "%.3f", start), "-i", media.absoluteString, "-t", String(format: "%.3f", duration),
                         "-map", audioStreamIndex.map { "0:\($0)" } ?? "0:a:0",
                         "-vn", "-ac", "1", "-ar", "16000", audio.path]
        if let subtitleStreamIndex {
            arguments += ["-map", "0:\(subtitleStreamIndex)", "-f", "srt", subtitles.path]
        }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: audio.path) else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .split(separator: "\n").last.map(String.init) ?? "ffmpeg exited with \(process.terminationStatus)"
            throw SyncError.extractionFailed(message)
        }
        return (audio, subtitleStreamIndex == nil ? nil : subtitles)
    }
}
