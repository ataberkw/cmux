import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The custom sidebar snapshots every second; folder identities must not hit
/// the disk on every tick, yet cmux's own writes must show immediately.
@MainActor
struct CmuxFolderProfileStoreTests {
    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-folder-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".cmux"), withIntermediateDirectories: true
        )
        return dir
    }

    private func writeProfile(_ json: String, in dir: URL, modifiedAt date: Date) throws {
        let url = dir.appendingPathComponent(".cmux/profile.json")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func externalEditWaitsForRevalidation() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        try writeProfile(#"{"name":"Before"}"#, in: dir, modifiedAt: start.addingTimeInterval(-60))
        #expect(CmuxFolderProfileStore.identity(forDir: dir.path, now: start).name == "Before")

        // Edited outside cmux: still cached inside the revalidation window...
        try writeProfile(#"{"name":"After"}"#, in: dir, modifiedAt: start.addingTimeInterval(-30))
        let withinWindow = start.addingTimeInterval(CmuxFolderProfileStore.revalidateInterval - 1)
        #expect(CmuxFolderProfileStore.identity(forDir: dir.path, now: withinWindow).name == "Before")

        // ...and picked up once the window passes and the mtime differs.
        let afterWindow = start.addingTimeInterval(CmuxFolderProfileStore.revalidateInterval + 1)
        #expect(CmuxFolderProfileStore.identity(forDir: dir.path, now: afterWindow).name == "After")
    }

    @Test func cmuxWriteShowsImmediately() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        #expect(CmuxFolderProfileStore.identity(forDir: dir.path, now: start).name == dir.lastPathComponent)

        #expect(CmuxFolderProfileStore.setProfile(dir: dir.path, name: "Game", emoji: "🎮"))
        let identity = CmuxFolderProfileStore.identity(forDir: dir.path, now: start.addingTimeInterval(1))
        #expect(identity.name == "Game")
        #expect(identity.emoji == "🎮")
    }

    @Test func basenameIdentityNeverReadsTheProfile() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeProfile(#"{"name":"Local","icon":"🎮"}"#, in: dir, modifiedAt: Date())

        let identity = CmuxFolderProfileStore.basenameIdentity(forDir: dir.path)
        #expect(identity.name == dir.lastPathComponent)
        #expect(identity.emoji == nil)
        #expect(identity.imageBase64 == nil)
    }
}
