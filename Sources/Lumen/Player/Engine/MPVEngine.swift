import AppKit
import CMpv
import OpenGL.GL3
import QuartzCore

/// Locates and loads libmpv at runtime.
enum MPVLibrary {
    private(set) static var loadedPath: String?
    private(set) static var lastError: String?

    /// `@rpath` covers the app bundle's Frameworks folder and an installed Stremio.app
    /// (see the rpaths in Package.swift); Homebrew paths are absolute.
    static let candidates = [
        "@rpath/libmpv.2.dylib",
        "@rpath/libmpv.dylib",
        "/opt/homebrew/lib/libmpv.2.dylib",
        "/opt/homebrew/lib/libmpv.dylib",
        "/usr/local/lib/libmpv.2.dylib",
        "/usr/local/lib/libmpv.dylib",
    ]

    @discardableResult
    static func load() -> Bool {
        if cmpv_is_loaded() != 0 { return true }
        var errors: [String] = []
        for path in candidates {
            if cmpv_load(path) != 0 {
                loadedPath = path
                Log.info("Loaded libmpv from \(path)")
                return true
            }
            errors.append(String(cString: cmpv_load_error()))
        }
        lastError = errors.last
        Log.error("libmpv not available: \(errors.joined(separator: " | "))")
        return false
    }

    static var isAvailable: Bool { load() }

    /// Recent warnings/errors from mpv, for diagnostics.
    @MainActor private(set) static var log: [String] = []

    @MainActor static func appendLog(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

@MainActor
final class MPVEngine: PlaybackEngine {
    let name = "mpv"
    let state = PlaybackState()
    let supportsExternalSubtitles = true
    private(set) var videoView: NSView

    fileprivate var handle: OpaquePointer?
    private let layer: MPVLayer
    private var lastPublishedTime: Double = -1
    private var pendingExternalSubtitles: [(URL, String, String)] = []

    private enum Property: UInt64, CaseIterable {
        case timePos = 1, duration, pause, pausedForCache, coreIdle, eofReached, trackList, aid, sid
        case volume, mute, speed, demuxerCacheTime, cacheBufferingState, videoParamsW, videoParamsH, subDelay, seeking

        var name: String {
            switch self {
            case .timePos: return "time-pos"
            case .duration: return "duration"
            case .pause: return "pause"
            case .pausedForCache: return "paused-for-cache"
            case .coreIdle: return "core-idle"
            case .eofReached: return "eof-reached"
            case .trackList: return "track-list"
            case .aid: return "aid"
            case .sid: return "sid"
            case .volume: return "volume"
            case .mute: return "mute"
            case .speed: return "speed"
            case .demuxerCacheTime: return "demuxer-cache-time"
            case .cacheBufferingState: return "cache-buffering-state"
            case .videoParamsW: return "video-params/w"
            case .videoParamsH: return "video-params/h"
            case .subDelay: return "sub-delay"
            case .seeking: return "seeking"
            }
        }

        var format: mpv_format {
            switch self {
            case .timePos, .duration, .volume, .speed, .demuxerCacheTime, .subDelay: return MPV_FORMAT_DOUBLE
            case .pause, .pausedForCache, .coreIdle, .eofReached, .mute, .seeking: return MPV_FORMAT_FLAG
            case .trackList: return MPV_FORMAT_NODE
            case .aid, .sid: return MPV_FORMAT_STRING
            case .cacheBufferingState, .videoParamsW, .videoParamsH: return MPV_FORMAT_INT64
            }
        }
    }

    init(hardwareDecoding: Bool) {
        handle = cmpv_create()
        let layer = MPVLayer()
        self.layer = layer
        let view = MPVVideoView(mpvLayer: layer)
        videoView = view

        guard let handle else {
            state.error = "Failed to create mpv instance"
            return
        }
        let options: [(String, String)] = [
            ("vo", "libmpv"),
            ("hwdec", hardwareDecoding ? "auto-safe" : "no"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("ytdl", "no"),
            ("config", "no"),
            ("terminal", "no"),
            ("audio-client-name", "Lumen"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "300MiB"),
            ("demuxer-max-back-bytes", "100MiB"),
            ("demuxer-readahead-secs", "30"),
            ("network-timeout", "60"),
            ("sub-auto", "no"),
            ("sub-font-size", "52"),
            ("sub-border-size", "2.5"),
            ("sub-shadow-offset", "1"),
            ("sub-codepage", "auto"),
            ("screenshot-directory", "~/Desktop"),
            ("user-agent", "Lumen-macOS/1.0"),
        ]
        for (key, value) in options { _ = cmpv_set_option_string(handle, key, value) }
        if cmpv_initialize(handle) < 0 {
            state.error = "Failed to initialize mpv"
            return
        }
        _ = cmpv_request_log_messages(handle, "warn")
        for property in Property.allCases {
            _ = cmpv_observe_property(handle, property.rawValue, property.name, property.format)
        }
        cmpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let engine = Unmanaged<MPVEngine>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { engine.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
        layer.attach(handle: handle)
    }

    // MARK: Commands

    private func command(_ args: [String]) {
        guard let handle else { return }
        var cStrings = args.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        var constPointers = cStrings.map { UnsafePointer<CChar>($0) }
        _ = constPointers.withUnsafeMutableBufferPointer { buffer in
            cmpv_command(handle, buffer.baseAddress)
        }
    }

    private func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        _ = cmpv_set_property_string(handle, name, value)
    }

    func load(_ url: URL, startAt seconds: Double?) {
        state.reset()
        lastPublishedTime = -1
        pendingExternalSubtitles = []
        // `start` applies to the next loadfile; reset it so later loads start from 0.
        setString("start", seconds.map { String(format: "%.3f", $0) } ?? "none")
        command(["loadfile", url.absoluteString, "replace"])
        setPaused(false)
    }

    func setPaused(_ paused: Bool) {
        guard let handle else { return }
        _ = cmpv_set_property_flag(handle, "pause", paused ? 1 : 0)
    }

    func seek(to seconds: Double) {
        command(["seek", String(format: "%.3f", max(0, seconds)), "absolute+keyframes"])
        state.time = seconds
    }

    func setVolume(_ volume: Double) {
        guard let handle else { return }
        _ = cmpv_set_property_double(handle, "volume", min(max(volume, 0), 100))
        if state.isMuted { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard let handle else { return }
        _ = cmpv_set_property_flag(handle, "mute", muted ? 1 : 0)
    }

    func setSpeed(_ speed: Double) {
        guard let handle else { return }
        _ = cmpv_set_property_double(handle, "speed", speed)
    }

    func selectAudioTrack(_ id: String) { setString("aid", id) }

    func selectSubtitleTrack(_ id: String?) { setString("sid", id ?? "no") }

    func addExternalSubtitle(url: URL, title: String, lang: String) {
        guard state.isLoaded else {
            pendingExternalSubtitles.append((url, title, lang))
            return
        }
        command(["sub-add", url.absoluteString, "auto", title, lang])
    }

    func setSubtitleDelay(_ seconds: Double) {
        guard let handle else { return }
        _ = cmpv_set_property_double(handle, "sub-delay", seconds)
    }

    func setSubtitleSpeed(_ speed: Double) {
        guard let handle else { return }
        _ = cmpv_set_property_double(handle, "sub-speed", speed)
        state.subtitleSpeed = speed
    }

    func setSubtitleScale(_ scale: Double) {
        guard let handle else { return }
        _ = cmpv_set_property_double(handle, "sub-scale", scale)
    }

    func stop() {
        guard let handle else { return }
        self.handle = nil
        cmpv_set_wakeup_callback(handle, nil, nil)
        layer.detach()
        cmpv_terminate_destroy(handle)
    }

    // MARK: Events

    private func drainEvents() {
        guard let handle else { return }
        while true {
            guard let event = cmpv_wait_event(handle, 0) else { break }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { break }
            process(event: event.pointee)
            if id == MPV_EVENT_SHUTDOWN { break }
        }
    }

    private func process(event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            process(property: property, id: event.reply_userdata)
        case MPV_EVENT_FILE_LOADED:
            state.isLoaded = true
            state.error = nil
            let pending = pendingExternalSubtitles
            pendingExternalSubtitles = []
            for (url, title, lang) in pending { addExternalSubtitle(url: url, title: title, lang: lang) }
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if endFile.reason == MPV_END_FILE_REASON_ERROR {
                state.error = "Playback failed: \(String(cString: cmpv_error_string(endFile.error)))"
                state.isBuffering = false
            } else if endFile.reason == MPV_END_FILE_REASON_EOF {
                state.didReachEnd = true
            }
        case MPV_EVENT_PLAYBACK_RESTART:
            state.isBuffering = false
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let prefix = message.prefix.map { String(cString: $0) } ?? "mpv"
            let text = message.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Log.info("[mpv/\(prefix)] \(text)")
            MPVLibrary.appendLog("[\(prefix)] \(text)")
        default:
            break
        }
    }

    private func process(property: mpv_event_property, id: UInt64) {
        guard let kind = Property(rawValue: id) else { return }
        func double() -> Double? {
            guard property.format == MPV_FORMAT_DOUBLE, let data = property.data else { return nil }
            return data.assumingMemoryBound(to: Double.self).pointee
        }
        func flag() -> Bool? {
            guard property.format == MPV_FORMAT_FLAG, let data = property.data else { return nil }
            return data.assumingMemoryBound(to: Int32.self).pointee != 0
        }
        func int() -> Int64? {
            guard property.format == MPV_FORMAT_INT64, let data = property.data else { return nil }
            return data.assumingMemoryBound(to: Int64.self).pointee
        }
        func string() -> String? {
            guard property.format == MPV_FORMAT_STRING, let data = property.data,
                  let cString = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return nil }
            return String(cString: cString)
        }

        switch kind {
        case .timePos:
            guard let time = double() else { return }
            // Throttle UI updates; mpv reports every frame.
            if abs(time - lastPublishedTime) >= 0.25 || time < lastPublishedTime {
                lastPublishedTime = time
                state.time = time
            }
        case .duration: state.duration = double() ?? 0
        case .pause: state.isPaused = flag() ?? false
        case .pausedForCache: state.isBuffering = flag() ?? false
        case .coreIdle: break
        case .seeking:
            if flag() == true { state.isBuffering = true }
        case .eofReached:
            if flag() == true { state.didReachEnd = true }
        case .trackList:
            guard property.format == MPV_FORMAT_NODE, let data = property.data else { return }
            let node = data.assumingMemoryBound(to: mpv_node.self).pointee
            updateTracks(MPVNode.convert(node))
        case .aid:
            let value = string()
            state.selectedAudioId = (value == nil || value == "no") ? nil : value
        case .sid:
            let value = string()
            state.selectedSubtitleId = (value == nil || value == "no") ? nil : value
        case .volume: state.volume = double() ?? state.volume
        case .mute: state.isMuted = flag() ?? false
        case .speed: state.speed = double() ?? 1
        case .demuxerCacheTime: state.bufferedUntil = double() ?? 0
        case .cacheBufferingState: state.cacheProgress = int().map { Double($0) / 100 }
        case .videoParamsW, .videoParamsH:
            if let w = cmpvInt("video-params/w"), let h = cmpvInt("video-params/h"), w > 0, h > 0 {
                state.videoSize = CGSize(width: w, height: h)
            }
        case .subDelay: state.subtitleDelay = double() ?? 0
        }
    }

    private func cmpvInt(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value = 0.0
        return cmpv_get_property_double(handle, name, &value) >= 0 ? value : nil
    }

    private func updateTracks(_ value: Any?) {
        guard let list = value as? [[String: Any]] else { return }
        var audio: [MediaTrack] = []
        var subtitles: [MediaTrack] = []
        for entry in list {
            guard let id = entry["id"] as? Int64, let type = entry["type"] as? String else { continue }
            let kind: MediaTrack.Kind
            switch type {
            case "audio": kind = .audio
            case "sub": kind = .subtitle
            default: continue
            }
            let track = MediaTrack(
                id: String(id), kind: kind,
                title: entry["title"] as? String,
                lang: entry["lang"] as? String,
                codec: entry["codec"] as? String,
                isExternal: entry["external"] as? Bool ?? false,
                isDefault: entry["default"] as? Bool ?? false,
                ffIndex: (entry["ff-index"] as? Int64).map(Int.init)
            )
            if kind == .audio { audio.append(track) } else { subtitles.append(track) }
        }
        state.audioTracks = audio
        state.subtitleTracks = subtitles
    }
}

/// Converts `mpv_node` trees into Foundation values.
enum MPVNode {
    static func convert(_ node: mpv_node) -> Any? {
        switch node.format {
        case MPV_FORMAT_STRING:
            return node.u.string.map { String(cString: $0) }
        case MPV_FORMAT_FLAG:
            return node.u.flag != 0
        case MPV_FORMAT_INT64:
            return node.u.int64
        case MPV_FORMAT_DOUBLE:
            return node.u.double_
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee else { return [Any]() }
            return (0..<Int(list.num)).compactMap { convert(list.values[$0]) }
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee else { return [String: Any]() }
            var map: [String: Any] = [:]
            for index in 0..<Int(list.num) {
                guard let key = list.keys?[index] else { continue }
                map[String(cString: key)] = convert(list.values[index])
            }
            return map
        default:
            return nil
        }
    }
}

// MARK: - Rendering

final class MPVVideoView: NSView {
    private let mpvLayer: MPVLayer

    init(mpvLayer: MPVLayer) {
        self.mpvLayer = mpvLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = mpvLayer
        layerContentsRedrawPolicy = .duringViewResize
        mpvLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        mpvLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        mpvLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override var isOpaque: Bool { true }
}

/// Renders mpv frames through the libmpv OpenGL render API into a CAOpenGLLayer.
final class MPVLayer: CAOpenGLLayer, @unchecked Sendable {
    private let cglPixelFormat: CGLPixelFormatObj
    private let cglContext: CGLContextObj
    private var renderContext: OpaquePointer?
    private let lock = NSLock()
    private let frameFlag = NSLock()
    private var needsRender = true
    /// Diagnostics (read by DebugHooks; written only inside `draw` while holding `lock`):
    /// frames drawn and the centre pixel of the last frame.
    nonisolated(unsafe) static var renderedFrames = 0
    nonisolated(unsafe) static var lastCenterPixel: [UInt8] = []
    private static let sampleFrames = ProcessInfo.processInfo.environment["LUMEN_DEBUG"] == "1"

    override init() {
        cglPixelFormat = MPVLayer.makePixelFormat()
        var context: CGLContextObj?
        CGLCreateContext(cglPixelFormat, nil, &context)
        cglContext = context!
        var swapInterval: GLint = 1
        CGLSetParameter(cglContext, kCGLCPSwapInterval, &swapInterval)
        super.init()
        // Core Animation polls canDraw on every display refresh; we draw only when mpv
        // has signalled a new frame (or the layer was resized).
        isAsynchronous = true
        needsDisplayOnBoundsChange = true
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    override init(layer: Any) {
        let other = layer as! MPVLayer
        cglPixelFormat = other.cglPixelFormat
        cglContext = other.cglContext
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func makePixelFormat() -> CGLPixelFormatObj {
        let attributeSets: [[CGLPixelFormatAttribute]] = [
            [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
             kCGLPFADoubleBuffer, kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers,
             kCGLPFASupportsAutomaticGraphicsSwitching, CGLPixelFormatAttribute(0)],
            [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
             kCGLPFADoubleBuffer, CGLPixelFormatAttribute(0)],
        ]
        for attributes in attributeSets {
            var pixelFormat: CGLPixelFormatObj?
            var count: GLint = 0
            if CGLChoosePixelFormat(attributes, &pixelFormat, &count) == kCGLNoError, let pixelFormat {
                return pixelFormat
            }
        }
        fatalError("No usable OpenGL pixel format")
    }

    func attach(handle: OpaquePointer) {
        CGLLockContext(cglContext)
        CGLSetCurrentContext(cglContext)
        var context: OpaquePointer?
        if cmpv_render_context_create_gl(&context, handle) < 0 {
            Log.error("mpv render context creation failed")
        }
        CGLUnlockContext(cglContext)
        lock.lock()
        renderContext = context
        lock.unlock()
        guard let context else { return }
        cmpv_render_context_set_update_callback(context, { ctx in
            guard let ctx else { return }
            let layer = Unmanaged<MPVLayer>.fromOpaque(ctx).takeUnretainedValue()
            layer.requestRender()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func detach() {
        do {
            lock.lock()
            defer { lock.unlock() }
            guard let context = renderContext else { return }
            cmpv_render_context_set_update_callback(context, nil, nil)
            CGLLockContext(cglContext)
            CGLSetCurrentContext(cglContext)
            cmpv_render_context_free(context)
            CGLUnlockContext(cglContext)
            renderContext = nil
        }
    }

    fileprivate func requestRender() {
        frameFlag.lock()
        needsRender = true
        frameFlag.unlock()
    }

    override var bounds: CGRect {
        didSet { requestRender() }
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj { cglPixelFormat }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj { cglContext }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        frameFlag.lock()
        defer { frameFlag.unlock() }
        if needsRender {
            needsRender = false
            return true
        }
        return false
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        lock.lock()
        defer { lock.unlock() }
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        if let renderContext, viewport[2] > 0, viewport[3] > 0 {
            _ = cmpv_render_context_render_gl(renderContext, fbo, viewport[2], viewport[3])
            MPVLayer.renderedFrames += 1
            if MPVLayer.sampleFrames {
                var pixel = [UInt8](repeating: 0, count: 4)
                glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(fbo))
                glReadPixels(viewport[2] / 2, viewport[3] / 2, 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixel)
                MPVLayer.lastCenterPixel = pixel
            }
        } else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        glFlush()
        if let renderContext { cmpv_render_context_report_swap(renderContext) }
    }

}
