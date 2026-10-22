import SwiftUI
import AppKit
import CryptoKit

actor IconCache {
    static let shared = IconCache()
    private let session: URLSession
    private let diskDirectory: URL?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
        let dir = URL.cachesDirectory.appending(path: "com.thealejo.adaptapeaitracker/icons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.diskDirectory = dir
    }

    func loadData(for url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        let fileURL = diskDirectory?.appending(path: diskFilename(for: url))
        if let fileURL, let cached = try? Data(contentsOf: fileURL) { return cached }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              NSImage(data: data) != nil else { return nil } // never persist undecodable bytes
        if let fileURL { try? data.write(to: fileURL, options: .atomic) }
        return data
    }

    private func diskFilename(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".svg"
    }
}

struct ProviderIcon: View {
    let url: URL?
    let name: String
    var size: CGFloat = 18

    @State private var image: NSImage?
    @MainActor private static let memoryCache = NSCache<NSURL, NSImage>()

    init(url: URL?, name: String, size: CGFloat = 18) {
        self.url = url
        self.name = name
        self.size = size
        if let url, let cached = Self.memoryCache.object(forKey: url as NSURL) {
            _image = State(initialValue: cached)
        } else {
            _image = State(initialValue: nil)
        }
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .transition(.opacity)
            } else {
                fallback
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .accessibilityHidden(true)
        .task(id: url) { await loadIcon() }
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(.quaternary)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func loadIcon() async {
        guard let url else { image = nil; return }
        if let cached = Self.memoryCache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        image = nil
        guard let data = await IconCache.shared.loadData(for: url),
              let decoded = NSImage(data: data) else { return }
        guard !Task.isCancelled else { return }
        // NSImage natively decodes SVG representations; isTemplate tints to light/dark.
        decoded.isTemplate = true
        Self.memoryCache.setObject(decoded, forKey: url as NSURL)
        withAnimation(.easeOut(duration: 0.2)) {
            image = decoded
        }
    }
}
