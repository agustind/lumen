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

/// A dropdown in the app's capsule style, replacing the stock pop-up button outside Settings.
/// `label` is the text shown for the current selection; the menu lists `content` with a checkmark
/// on the selected item.
struct Dropdown<Value: Hashable, Content: View>: View {
    var title: String
    @Binding var selection: Value
    var label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            Picker(title, selection: $selection, content: content)
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryForeground)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(DropdownButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(label)
    }
}

private struct DropdownButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DropdownBody(configuration: configuration)
    }

    private struct DropdownBody: View {
        var configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.foreground)
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(Color.white.opacity(configuration.isPressed ? 0.18 : isHovering ? 0.14 : 0.1), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                .contentShape(Capsule())
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

/// A segmented control in the app's capsule style: the selected segment is an accent pill
/// that slides between options.
struct SegmentedControl<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(value: Value, title: String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Segment(title: option.title, isSelected: option.value == selection, namespace: namespace) {
                    selection = option.value
                }
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .animation(.easeOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private struct Segment: View {
        var title: String
        var isSelected: Bool
        var namespace: Namespace.ID
        var action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : isHovering ? Theme.foreground : Theme.secondaryForeground)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background {
                        if isSelected {
                            Capsule().fill(Theme.accent).matchedGeometryEffect(id: "selection", in: namespace)
                        } else if isHovering {
                            Capsule().fill(Color.white.opacity(0.06))
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// A search/filter field in the app's capsule style, with a clear button while it has text.
struct SearchField: View {
    var prompt: String
    @Binding var text: String
    /// Changing this value focuses the field.
    var focusRequest = 0
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryForeground)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.foreground)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiaryForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 32)
        .background(Color.white.opacity(isFocused ? 0.14 : isHovering ? 0.12 : 0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(isFocused ? Theme.accent.opacity(0.8) : Color.white.opacity(0.08)))
        .contentShape(Capsule())
        .onTapGesture { isFocused = true }
        .onHover { isHovering = $0 }
        .onChange(of: focusRequest) { isFocused = true }
        .onExitCommand { text = ""; isFocused = false }
        .animation(.easeOut(duration: 0.12), value: isFocused)
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
