import AppKit

/// Decoded `Image(data:)` rasters, keyed by their base64 text.
///
/// The custom sidebar re-interprets and re-renders every second, so an
/// uncached `.image` node would base64-decode and PNG-decode the same bytes on
/// every tick. Undecodable input is cached too, so bad data is tried once.
@MainActor
final class RenderImageDataCache {
    /// The cache both render lanes share (each runs one `RenderNodeView` tree).
    static let shared = RenderImageDataCache()

    private final class Entry {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    private let entries = NSCache<NSString, Entry>()
    private let decode: (String) -> NSImage?

    /// Creates a cache.
    ///
    /// - Parameters:
    ///   - countLimit: Distinct images kept before NSCache evicts.
    ///   - decode: Turns base64 text into an image, `nil` when invalid.
    init(
        countLimit: Int = 64,
        decode: @escaping (String) -> NSImage? = { base64 in
            Data(base64Encoded: base64).flatMap(NSImage.init(data:))
        }
    ) {
        entries.countLimit = countLimit
        self.decode = decode
    }

    /// The image `base64` decodes to, or `nil` when it is not a valid image.
    func image(forBase64 base64: String) -> NSImage? {
        let key = base64 as NSString
        if let cached = entries.object(forKey: key) { return cached.image }
        let image = decode(base64)
        entries.setObject(Entry(image), forKey: key)
        return image
    }
}
