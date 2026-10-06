import SwiftUI

/// A poster tile used in catalogs, library and search.
struct PosterCard: View {
    var meta: MetaItem
    var width: CGFloat = Theme.posterWidth
    var progress: Double?
    var isWatched = false
    var subtitle: String?
    var action: () -> Void

    @State private var isHovered = false

    private var height: CGFloat { width / meta.posterShape.aspectRatio }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    CachedImage(url: meta.poster) {
                        ZStack {
                            Theme.surface
                            Text(meta.name)
                                .font(.system(size: 13, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Theme.secondaryForeground)
                                .padding(10)
                        }
                    }
                    .frame(width: width, height: height)
                    .clipped()

                    if let progress, progress > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.white.opacity(0.25))
                                Rectangle().fill(Theme.accent).frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let rating = meta.imdbRating, Double(rating) ?? 0 > 0 {
                        HStack(spacing: 3) {
                            Text("IMDb")
                                .font(.system(size: 8.5, weight: .black))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Theme.yellow, in: RoundedRectangle(cornerRadius: 2))
                                .foregroundStyle(.black)
                            Text(rating)
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.green)
                            .padding(6)
                    }
                }
                .overlay {
                    if isHovered {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(isHovered ? 0.5 : 0.25), radius: isHovered ? 12 : 4, y: 4)
                .scaleEffect(isHovered ? 1.04 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryForeground)
                            .lineLimit(1)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(meta.name)
    }
}

/// A horizontally scrolling row of posters with a header.
struct CatalogRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var items: [MetaItem]
    var isLoading = false
    var error: String?
    var onSelect: (MetaItem) -> Void
    var onSeeAll: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.foreground)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiaryForeground)
                }
                Spacer()
                trailing()
                if let onSeeAll {
                    Button("See All", action: onSeeAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryForeground)
                }
            }
            .padding(.horizontal, 28)

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.tertiaryForeground)
                    .padding(.horizontal, 28)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        if isLoading && items.isEmpty {
                            ForEach(0..<8, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                    .fill(Theme.surface)
                                    .frame(width: Theme.posterWidth, height: Theme.posterWidth * 1.5)
                            }
                        }
                        ForEach(items) { item in
                            PosterCard(meta: item, subtitle: item.releaseInfo) { onSelect(item) }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                }
                .scrollClipDisabled()
            }
        }
    }
}

extension CatalogRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, items: [MetaItem], isLoading: Bool = false, error: String? = nil,
         onSelect: @escaping (MetaItem) -> Void, onSeeAll: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, items: items, isLoading: isLoading, error: error,
                  onSelect: onSelect, onSeeAll: onSeeAll, trailing: { EmptyView() })
    }
}
