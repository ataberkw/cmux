import AppKit
@testable import CmuxSwiftRenderUI
import Testing

@MainActor
struct RenderImageDataCacheTests {
    @Test func decodesEachPayloadOnce() {
        var decodes = 0
        let cache = RenderImageDataCache { _ in
            decodes += 1
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let first = cache.image(forBase64: "AAAA")
        let second = cache.image(forBase64: "AAAA")
        #expect(decodes == 1)
        #expect(first === second)
        _ = cache.image(forBase64: "BBBB")
        #expect(decodes == 2)
    }

    @Test func invalidPayloadIsTriedOnce() {
        var decodes = 0
        let cache = RenderImageDataCache { _ in
            decodes += 1
            return nil
        }
        #expect(cache.image(forBase64: "not-an-image") == nil)
        #expect(cache.image(forBase64: "not-an-image") == nil)
        #expect(decodes == 1)
    }

    @Test func defaultDecoderRejectsGarbage() {
        #expect(RenderImageDataCache().image(forBase64: "%%%") == nil)
    }
}
