import Foundation

struct AppSettings: Codable, Hashable {
    enum PlayerEngine: String, Codable, CaseIterable, Identifiable {
        /// libmpv when available (plays everything), AVPlayer otherwise.
        case automatic
        case mpv
        case avFoundation

        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .mpv: return "mpv"
            case .avFoundation: return "AVFoundation"
            }
        }
    }

    var playerEngine: PlayerEngine = .automatic
    var hardwareDecoding = true
    /// ISO 639-2 code (e.g. "eng") or empty for none.
    var subtitlesLanguage = Locale.current.language.languageCode.map { ISOLanguage.threeLetter(for: $0.identifier) } ?? "eng"
    var subtitlesSize = 100
    var audioLanguage = ""
    var bingeWatching = true
    var playInBackground = false
    var seekStepSeconds = 10
    var streamingServerURL = "http://127.0.0.1:11470"
    var startStreamingServer = true
    var showAdultAddons = false
    /// Stream addon pre-selected in a title's stream list: `auto` (Torrentio RD),
    /// empty for none, or an addon transport URL.
    var preferredStreamAddon = AppSettings.automaticStreamAddon

    static let automaticStreamAddon = "auto"

    init() {}

    init(from decoder: Decoder) throws {
        // Tolerate missing keys so new settings don't reset everything.
        let defaults = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playerEngine = c.lossy(PlayerEngine.self, .playerEngine) ?? defaults.playerEngine
        hardwareDecoding = c.lossy(Bool.self, .hardwareDecoding) ?? defaults.hardwareDecoding
        subtitlesLanguage = c.lossy(String.self, .subtitlesLanguage) ?? defaults.subtitlesLanguage
        subtitlesSize = c.lossy(Int.self, .subtitlesSize) ?? defaults.subtitlesSize
        audioLanguage = c.lossy(String.self, .audioLanguage) ?? defaults.audioLanguage
        bingeWatching = c.lossy(Bool.self, .bingeWatching) ?? defaults.bingeWatching
        playInBackground = c.lossy(Bool.self, .playInBackground) ?? defaults.playInBackground
        seekStepSeconds = c.lossy(Int.self, .seekStepSeconds) ?? defaults.seekStepSeconds
        streamingServerURL = c.lossy(String.self, .streamingServerURL) ?? defaults.streamingServerURL
        startStreamingServer = c.lossy(Bool.self, .startStreamingServer) ?? defaults.startStreamingServer
        showAdultAddons = c.lossy(Bool.self, .showAdultAddons) ?? defaults.showAdultAddons
        preferredStreamAddon = c.lossy(String.self, .preferredStreamAddon) ?? defaults.preferredStreamAddon
    }
}

enum StreamAddonPreference {
    /// Picks the addon whose streams should be pre-selected.
    /// `auto` picks Torrentio configured with Real-Debrid.
    static func preferred(among addons: [AddonDescriptor], setting: String) -> AddonDescriptor? {
        if setting.isEmpty { return nil }
        if setting != AppSettings.automaticStreamAddon {
            return addons.first { $0.transportUrl == setting }
        }
        return addons.first { isTorrentio($0) && isRealDebrid($0) }
    }

    static func isTorrentio(_ addon: AddonDescriptor) -> Bool {
        addon.manifest.id.lowercased().contains("torrentio")
            || addon.manifest.name.lowercased().contains("torrentio")
            || addon.transportUrl.lowercased().contains("torrentio")
    }

    /// Torrentio encodes debrid settings in its URL (`…/realdebrid=KEY/manifest.json`) and
    /// names configured instances e.g. "Torrentio RD".
    static func isRealDebrid(_ addon: AddonDescriptor) -> Bool {
        let url = addon.transportUrl.lowercased().removingPercentEncoding ?? addon.transportUrl.lowercased()
        let words = addon.manifest.name.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return url.contains("realdebrid=") || words.contains("RD") || addon.manifest.name.lowercased().contains("real-debrid")
    }
}

enum ISOLanguage {
    /// A small ISO 639-1 → 639-2 map covering the languages OpenSubtitles commonly serves.
    static let table: [String: (code: String, name: String)] = [
        "en": ("eng", "English"), "es": ("spa", "Spanish"), "fr": ("fre", "French"), "de": ("ger", "German"),
        "it": ("ita", "Italian"), "pt": ("por", "Portuguese"), "pb": ("pob", "Portuguese (Brazil)"),
        "ru": ("rus", "Russian"), "pl": ("pol", "Polish"), "nl": ("dut", "Dutch"), "sv": ("swe", "Swedish"),
        "no": ("nor", "Norwegian"), "da": ("dan", "Danish"), "fi": ("fin", "Finnish"), "tr": ("tur", "Turkish"),
        "el": ("gre", "Greek"), "he": ("heb", "Hebrew"), "ar": ("ara", "Arabic"), "fa": ("per", "Persian"),
        "hi": ("hin", "Hindi"), "ja": ("jpn", "Japanese"), "ko": ("kor", "Korean"), "zh": ("chi", "Chinese"),
        "cs": ("cze", "Czech"), "sk": ("slo", "Slovak"), "hu": ("hun", "Hungarian"), "ro": ("rum", "Romanian"),
        "bg": ("bul", "Bulgarian"), "hr": ("hrv", "Croatian"), "sr": ("scc", "Serbian"), "sl": ("slv", "Slovenian"),
        "uk": ("ukr", "Ukrainian"), "vi": ("vie", "Vietnamese"), "th": ("tha", "Thai"), "id": ("ind", "Indonesian"),
        "ms": ("may", "Malay"), "et": ("est", "Estonian"), "lv": ("lav", "Latvian"), "lt": ("lit", "Lithuanian"),
        "ca": ("cat", "Catalan"), "eu": ("baq", "Basque"), "gl": ("glg", "Galician"), "is": ("ice", "Icelandic"),
    ]

    /// Alternate ISO 639-2 codes (bibliographic vs terminologic) that should match each other.
    static let aliases: [String: String] = [
        "fra": "fre", "deu": "ger", "nld": "dut", "ell": "gre", "zho": "chi", "ces": "cze", "slk": "slo",
        "ron": "rum", "srp": "scc", "fas": "per", "msa": "may", "eus": "baq", "isl": "ice", "pt-br": "pob", "ptb": "pob",
    ]

    static func threeLetter(for code: String) -> String {
        let lower = code.lowercased()
        if lower.count == 2 { return table[lower]?.code ?? lower }
        return aliases[lower] ?? lower
    }

    static func normalize(_ code: String) -> String { threeLetter(for: code) }

    static func name(for code: String) -> String {
        let normalized = normalize(code)
        if let entry = table.values.first(where: { $0.code == normalized }) { return entry.name }
        if let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty { return name.capitalized }
        return code.uppercased()
    }

    static var allChoices: [(code: String, name: String)] {
        table.values.map { ($0.code, $0.name) }.sorted { $0.name < $1.name }
    }
}
