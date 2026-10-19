import AppKit
import ImageIO
import SamsungNotesKit

/// Card pictures: made once per version of a note, kept on disk beside it, and in memory for as
/// long as there is room. Scrolling a large library does not keep every picture alive.
@MainActor
final class ThumbnailCache {
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 160 << 20
        return cache
    }()
    /// The key of the picture kept for each note and appearance: an older version leaves when a newer one arrives.
    private var newest: [String: String] = [:]
    private var loading: [String: Task<NSImage?, Never>] = [:]

    func removeAll() {
        cache.removeAllObjects()
        newest.removeAll()
        for task in loading.values { task.cancel() }
        loading.removeAll()
    }

    static func key(_ record: NoteRecord, dark: Bool) -> String {
        "\(record.id)|\(record.commitID)|\(record.revision ?? 0)|\(record.modifiedAt.timeIntervalSince1970)|\(dark)"
    }

    /// The picture if it is in memory already.
    func cached(_ record: NoteRecord, dark: Bool) -> NSImage? {
        cache.object(forKey: ThumbnailCache.key(record, dark: dark) as NSString)
    }

    /// The picture, read from disk or drawn off the main thread when it is not in memory.
    func image(for record: NoteRecord, dark: Bool, store: LocalStore) async -> NSImage? {
        let key = ThumbnailCache.key(record, dark: dark)
        if let image = cache.object(forKey: key as NSString) { return image }
        if let running = loading[key] { return await running.value }
        let id = record.id
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            let url = store.thumbnailURL(id, dark: dark)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                return NSImage(cgImage: image, size: NSSize(width: 220, height: 220))
            }
            guard let note = try? store.load(id), let rendered = NoteRenderer.thumbnail(note, side: 440, dark: dark) else { return nil }
            NoteRenderer.writePNG(rendered, to: url)
            return NSImage(cgImage: rendered, size: NSSize(width: 220, height: 220))
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image {
            let slot = "\(id)|\(dark)"
            if let old = newest[slot], old != key { cache.removeObject(forKey: old as NSString) }
            newest[slot] = key
            let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 440 * 440
            cache.setObject(image, forKey: key as NSString, cost: pixels * 4)
        }
        return image
    }
}
