import AppKit
import SwiftUI

/// In-memory + on-disk image cache. Posters are requested constantly while scrolling,
/// so SwiftUI's AsyncImage (which reloads on every appearance) isn't good enough.
actor ImageLoader {
    static let shared = ImageLoader()

    // NSCache is thread-safe.
    private nonisolated(unsafe) let memory = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    init() {
        memory.countLimit = 600
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20,
                                          directory: Storage.directory.appendingPathComponent("ImageCache"))
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: configuration)
    }

    nonisolated func cached(_ url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let image = memory.object(forKey: url as NSURL) { return image }
        if let task = inFlight[url] { return await task.value }
        let session = self.session
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = NSImage(data: data) else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }
}

struct CachedImage<Placeholder: View>: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            if let image, loadedURL == url {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ImageLoader.shared.cached(url) {
                image = cached
                loadedURL = url
                return
            }
            let loaded = await ImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                loadedURL = url
            }
        }
    }
}

extension CachedImage where Placeholder == Color {
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.init(url: url, contentMode: contentMode) { Theme.surface }
    }
}
