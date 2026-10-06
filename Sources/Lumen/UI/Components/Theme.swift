import SwiftUI

/// Colors from stremio-web's theme variables.
enum Theme {
    static let background = Color(red: 12 / 255, green: 11 / 255, blue: 17 / 255)
    static let secondaryBackground = Color(red: 26 / 255, green: 23 / 255, blue: 62 / 255)
    static let modalBackground = Color(red: 15 / 255, green: 13 / 255, blue: 32 / 255)
    static let accent = Color(red: 123 / 255, green: 91 / 255, blue: 245 / 255)
    static let green = Color(red: 34 / 255, green: 179 / 255, blue: 101 / 255)
    static let yellow = Color(red: 246 / 255, green: 199 / 255, blue: 0)
    static let danger = Color(red: 220 / 255, green: 38 / 255, blue: 38 / 255)
    static let overlay = Color.white.opacity(0.05)
    static let surface = Color.white.opacity(0.07)
    static let foreground = Color.white.opacity(0.9)
    static let secondaryForeground = Color.white.opacity(0.6)
    static let tertiaryForeground = Color.white.opacity(0.4)

    static let cornerRadius: CGFloat = 10
    static let posterWidth: CGFloat = 150

    static func typeTitle(_ type: String) -> String {
        switch type {
        case "movie": return "Movies"
        case "series": return "Series"
        case "channel": return "Channels"
        case "tv": return "TV"
        case "anime": return "Anime"
        case "other": return "Other"
        default: return type.capitalized
        }
    }

    static func typeSingular(_ type: String) -> String {
        switch type {
        case "movie": return "Movie"
        case "series": return "Series"
        case "channel": return "Channel"
        case "tv": return "TV"
        default: return type.capitalized
        }
    }
}

extension View {
    /// The translucent rounded panel used throughout the app.
    func panelStyle(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.1), in: Capsule())
            .contentShape(Capsule())
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.white.opacity(configuration.isPressed ? 0.25 : 0.12), in: Circle())
            .contentShape(Circle())
    }
}

/// A capsule chip (genres, filters).
struct Chip: View {
    var title: String
    var isSelected = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.accent : Color.white.opacity(0.1), in: Capsule())
            .foregroundStyle(.white)
    }
}

struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.tertiaryForeground)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.foreground)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bytesPerSecond(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary) + "/s"
    }

    static let releaseDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
