import AppKit
import Foundation

/// A per-folder identity profile stored as `<dir>/.cmux/profile.json`
/// (`{ "name": "…", "iconType": "emoji"|"image", "icon": "🎮" }`), with the
/// image variant's already-shrunk PNG beside it at `<dir>/.cmux/icon.png`.
/// This is the portable, project-tied workspace identity the Split Map sidebar
/// renders; it travels with the folder (git/dotfiles) instead of living only in
/// cmux app state.
private struct CmuxFolderProfileData: Decodable {
    var name: String?
    var iconType: String?
    var icon: String?
}

/// One folder's resolved identity: a display name (profile name, else the
/// folder basename) and an optional emoji or base64-PNG icon.
struct CmuxFolderIdentity {
    let dir: String
    let name: String
    let emoji: String?
    let imageBase64: String?
}

/// Reads and caches `.cmux/profile.json` / `.cmux/icon.png` identities.
///
/// The custom sidebar snapshots every second, so a cached identity is served
/// without touching the disk for ``revalidateInterval``; after that the two
/// files' modification times are re-checked (two `stat`s) and the file is
/// re-parsed only when one changed. The socket write paths below drop the
/// entry, so cmux-made edits show immediately; only edits made outside cmux
/// wait up to ``revalidateInterval``.
@MainActor
enum CmuxFolderProfileStore {
    /// How long a cached identity is trusted before its files are re-checked.
    static let revalidateInterval: TimeInterval = 5

    private struct CacheEntry {
        let profileMTime: Date?
        let imageMTime: Date?
        let identity: CmuxFolderIdentity
        var checkedAt: Date
    }
    private static var cache: [String: CacheEntry] = [:]

    static func identity(forDir dir: String, now: Date = Date()) -> CmuxFolderIdentity {
        if let cached = cache[dir], now.timeIntervalSince(cached.checkedAt) < revalidateInterval {
            return cached.identity
        }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: dir)
        let profileURL = base.appendingPathComponent(".cmux/profile.json")
        let imageURL = base.appendingPathComponent(".cmux/icon.png")
        let profileMTime = (try? fm.attributesOfItem(atPath: profileURL.path))?[.modificationDate] as? Date
        let imageMTime = (try? fm.attributesOfItem(atPath: imageURL.path))?[.modificationDate] as? Date
        if var cached = cache[dir],
           cached.profileMTime == profileMTime,
           cached.imageMTime == imageMTime {
            cached.checkedAt = now
            cache[dir] = cached
            return cached.identity
        }
        var name = base.lastPathComponent
        var emoji: String?
        var imageBase64: String?
        if let data = try? Data(contentsOf: profileURL),
           let profile = try? JSONDecoder().decode(CmuxFolderProfileData.self, from: data) {
            if let trimmed = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                name = trimmed
            }
            let iconType = profile.iconType ?? (profile.icon != nil ? "emoji" : nil)
            if iconType == "emoji", let icon = profile.icon, !icon.isEmpty {
                emoji = icon
            } else if iconType == "image", let imageData = try? Data(contentsOf: imageURL) {
                imageBase64 = imageData.base64EncodedString()
            }
        }
        let identity = CmuxFolderIdentity(dir: dir, name: name, emoji: emoji, imageBase64: imageBase64)
        cache[dir] = CacheEntry(
            profileMTime: profileMTime,
            imageMTime: imageMTime,
            identity: identity,
            checkedAt: now
        )
        return identity
    }

    /// A folder's identity without reading its profile: the basename only.
    /// Used for remote panes, whose directory names a path on another host.
    nonisolated static func basenameIdentity(forDir dir: String) -> CmuxFolderIdentity {
        CmuxFolderIdentity(
            dir: dir,
            name: URL(fileURLWithPath: dir).lastPathComponent,
            emoji: nil,
            imageBase64: nil
        )
    }

    // MARK: - Writes (invoked by the workspace.set_folder_* socket methods)

    /// Merges fields into `<dir>/.cmux/profile.json`. A non-nil `name` sets the
    /// display name; a non-nil `emoji` sets the emoji icon (and flips
    /// `iconType` to "emoji"). Returns true on success.
    @discardableResult
    static func setProfile(dir: String, name: String? = nil, emoji: String? = nil) -> Bool {
        var data = readRaw(dir: dir)
        if let name { data["name"] = name }
        if let emoji {
            data["icon"] = emoji
            data["iconType"] = "emoji"
        }
        return writeRaw(dir: dir, data)
    }

    /// Shrinks + compresses `image` to a small square PNG at `<dir>/.cmux/icon.png`
    /// and flips the profile to the image icon (clearing any emoji).
    @discardableResult
    static func setImage(dir: String, image: NSImage, maxSize: CGFloat = 64) -> Bool {
        guard let png = shrunkPNG(image, maxSize: maxSize) else { return false }
        let cmuxDir = URL(fileURLWithPath: dir).appendingPathComponent(".cmux")
        try? FileManager.default.createDirectory(at: cmuxDir, withIntermediateDirectories: true)
        do {
            try png.write(to: cmuxDir.appendingPathComponent("icon.png"))
        } catch {
            return false
        }
        var data = readRaw(dir: dir)
        data["iconType"] = "image"
        data.removeValue(forKey: "icon")
        return writeRaw(dir: dir, data)
    }

    /// Removes any icon (emoji or image) and deletes `icon.png`, leaving just
    /// the name (or the folder basename when none).
    @discardableResult
    static func clearIcon(dir: String) -> Bool {
        let cmuxDir = URL(fileURLWithPath: dir).appendingPathComponent(".cmux")
        try? FileManager.default.removeItem(at: cmuxDir.appendingPathComponent("icon.png"))
        var data = readRaw(dir: dir)
        data.removeValue(forKey: "icon")
        data.removeValue(forKey: "iconType")
        return writeRaw(dir: dir, data)
    }

    private static func readRaw(dir: String) -> [String: Any] {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".cmux/profile.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    @discardableResult
    private static func writeRaw(dir: String, _ data: [String: Any]) -> Bool {
        let cmuxDir = URL(fileURLWithPath: dir).appendingPathComponent(".cmux")
        try? FileManager.default.createDirectory(at: cmuxDir, withIntermediateDirectories: true)
        let url = cmuxDir.appendingPathComponent("profile.json")
        guard let out = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        do {
            try out.write(to: url)
            cache.removeValue(forKey: dir)
            return true
        } catch {
            return false
        }
    }

    /// Aspect-fits `image` (no upscaling past `maxSize`) centered on a
    /// transparent `maxSize`×`maxSize` canvas and encodes it as PNG.
    private static func shrunkPNG(_ image: NSImage, maxSize: CGFloat) -> Data? {
        let src = image.size
        guard src.width > 0, src.height > 0 else { return nil }
        let fit = min(maxSize / src.width, maxSize / src.height)
        let drawW = src.width * fit
        let drawH = src.height * fit
        let canvas = NSImage(size: NSSize(width: maxSize, height: maxSize))
        canvas.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: (maxSize - drawW) / 2, y: (maxSize - drawH) / 2, width: drawW, height: drawH),
            from: .zero, operation: .sourceOver, fraction: 1.0)
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }
}
