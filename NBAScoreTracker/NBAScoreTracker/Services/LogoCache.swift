import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Two-tier (L1 synchronous memory + L2 downsampled disk) team logo cache.
/// Replaces raw 500x500 AsyncImage decoding so day switches and section moves
/// paint on frame 0 with ~98% less decoded bitmap memory and full offline reuse.
final class LogoCache: @unchecked Sendable {
    static let shared = LogoCache()

    static let thumbnailMaxPixelSize = 66
    static let maximumDownloadBytes = 512 * 1024
    static let maximumDiskEntryBytes = 128 * 1024
    static let maximumDiskBytes = 4 * 1024 * 1024
    static let maximumDiskEntries = 64
    static let diskLifetime: TimeInterval = 30 * 86_400
    static let failureCooldown: TimeInterval = 60

    private let memoryCache: MemoryBox
    private let storage: Storage
    private let leaguePrefix: String

    init(
        directory: URL? = nil,
        session: URLSession? = nil,
        leaguePrefix: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let box = MemoryBox(countLimit: 48)
        self.memoryCache = box

        let resolvedLeague: String
        if let leaguePrefix {
            resolvedLeague = leaguePrefix
        } else {
            #if DEBUG
            resolvedLeague = ProcessInfo.processInfo.environment["NBA_LEAGUE"] == "10" ? "wnba" : "nba"
            #else
            resolvedLeague = "nba"
            #endif
        }
        self.leaguePrefix = resolvedLeague

        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            config.httpMaximumConnectionsPerHost = 4
            config.waitsForConnectivity = false
            resolvedSession = URLSession(configuration: config)
        }

        let resolvedDir: URL
        if let directory {
            resolvedDir = directory
        } else {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            resolvedDir = cachesDir.appendingPathComponent("NBAScoreTracker/logos-v1", isDirectory: true)
        }

        self.storage = Storage(directory: resolvedDir, session: resolvedSession, memoryCache: box, now: now)
    }

    /// Synchronous L1 lookup safe to call directly from SwiftUI `body`.
    func cachedImage(for tricode: String) -> NSImage? {
        guard let key = cacheKey(for: tricode) else { return nil }
        return memoryCache.image(forKey: key)
    }

    /// Resolves a team logo from L1 -> L2 disk -> bounded network download + downsample.
    func image(for tricode: String, url: URL) async -> NSImage? {
        guard let key = cacheKey(for: tricode) else { return nil }
        if let hit = memoryCache.image(forKey: key) {
            return hit
        }
        return await storage.load(key: key, url: url)?.image
    }

    /// Evicts in-memory L1 entries (used in tests to verify L2 disk reload).
    func clearMemoryCache() {
        memoryCache.removeAll()
    }

    static func downsample(_ data: Data, maxPixelSize: Int = thumbnailMaxPixelSize) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func cacheKey(for tricode: String) -> String? {
        guard NBAFeedLimits.isTricode(tricode) else { return nil }
        return "\(leaguePrefix)-\(tricode)"
    }

    private static func isValidCacheKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let league = parts[0]
        let tricode = String(parts[1])
        return (league == "nba" || league == "wnba") && NBAFeedLimits.isTricode(tricode)
    }

    // MARK: - Concurrency-safe boxes

    /// Immutable CGImage-backed NSImage transport across actor boundaries.
    private struct SendableImage: @unchecked Sendable {
        let image: NSImage
    }

    /// Thread-safe L1 wrapper around NSCache.
    private final class MemoryBox: @unchecked Sendable {
        private let cache = NSCache<NSString, NSImage>()

        init(countLimit: Int) {
            cache.countLimit = countLimit
        }

        func image(forKey key: String) -> NSImage? {
            cache.object(forKey: key as NSString)
        }

        func setImage(_ image: NSImage, forKey key: String) {
            cache.setObject(image, forKey: key as NSString)
        }

        func removeAll() {
            cache.removeAllObjects()
        }
    }

    // MARK: - Actor Storage

    private actor Storage {
        private let directory: URL
        private let session: URLSession
        private let memoryCache: MemoryBox
        private let now: @Sendable () -> Date
        private var inFlight: [String: Task<SendableImage?, Never>] = [:]
        private var failedAt: [String: Date] = [:]
        private var lastPrunedAt: Date?

        init(
            directory: URL,
            session: URLSession,
            memoryCache: MemoryBox,
            now: @escaping @Sendable () -> Date
        ) {
            self.directory = directory
            self.session = session
            self.memoryCache = memoryCache
            self.now = now
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func load(key: String, url: URL) async -> SendableImage? {
            if let hit = memoryCache.image(forKey: key) {
                return SendableImage(image: hit)
            }
            if let existing = inFlight[key] {
                return await existing.value
            }
            let current = now()
            if let failed = failedAt[key],
               current.timeIntervalSince(failed) >= 0,
               current.timeIntervalSince(failed) < LogoCache.failureCooldown {
                return nil
            }

            let task = Task<SendableImage?, Never> { [self] in
                defer { self.finishInFlight(key: key) }
                if let diskImage = self.loadFromDisk(key: key) {
                    self.failedAt.removeValue(forKey: key)
                    self.memoryCache.setImage(diskImage, forKey: key)
                    return SendableImage(image: diskImage)
                }
                guard let downloaded = await self.fetchBoundedData(from: url),
                      let cgImage = LogoCache.downsample(downloaded, maxPixelSize: LogoCache.thumbnailMaxPixelSize) else {
                    self.recordFailure(key: key)
                    return nil
                }
                self.failedAt.removeValue(forKey: key)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                self.memoryCache.setImage(nsImage, forKey: key)
                if let pngData = LogoCache.encodePNG(cgImage),
                   pngData.count <= LogoCache.maximumDiskEntryBytes {
                    self.saveToDisk(key: key, data: pngData)
                }
                return SendableImage(image: nsImage)
            }
            inFlight[key] = task
            return await task.value
        }

        private func finishInFlight(key: String) {
            inFlight.removeValue(forKey: key)
        }

        private func recordFailure(key: String) {
            failedAt[key] = now()
        }

        private func fileURL(for key: String) -> URL {
            directory.appendingPathComponent("\(key).png")
        }

        private func isFresh(_ date: Date) -> Bool {
            let age = now().timeIntervalSince(date)
            return age >= 0 && age < LogoCache.diskLifetime
        }

        private func loadFromDisk(key: String) -> NSImage? {
            pruneDisk()
            let url = fileURL(for: key)
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            } catch {
                return nil
            }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  isFresh(modified),
                  let handle = try? FileHandle(forReadingFrom: url) else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: LogoCache.maximumDiskEntryBytes + 1),
                  data.count <= LogoCache.maximumDiskEntryBytes,
                  let cgImage = LogoCache.downsample(data, maxPixelSize: LogoCache.thumbnailMaxPixelSize) else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        private func saveToDisk(key: String, data: Data) {
            let url = fileURL(for: key)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            pruneDisk(force: true)
        }

        private func pruneDisk(force: Bool = false) {
            let current = now()
            if !force, let lastPrunedAt,
               current.timeIntervalSince(lastPrunedAt) >= 0,
               current.timeIntervalSince(lastPrunedAt) < 300 {
                return
            }
            lastPrunedAt = current
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { return }

            var entries: [(url: URL, size: Int, modified: Date)] = []
            for url in files where url.pathExtension == "png" {
                let stem = url.deletingPathExtension().lastPathComponent
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      LogoCache.isValidCacheKey(stem),
                      let size = values.fileSize, size <= LogoCache.maximumDiskEntryBytes,
                      let modified = values.contentModificationDate, isFresh(modified) else {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                entries.append((url, size, modified))
            }
            entries.sort { $0.modified > $1.modified }
            var totalBytes = 0
            for (index, entry) in entries.enumerated() {
                totalBytes += entry.size
                if index >= LogoCache.maximumDiskEntries || totalBytes > LogoCache.maximumDiskBytes {
                    try? FileManager.default.removeItem(at: entry.url)
                }
            }
        }

        private func fetchBoundedData(from url: URL) async -> Data? {
            guard let outcome = try? await BoundedHTTPFetcher.fetch(
                request: URLRequest(url: url),
                using: session,
                maxBytes: LogoCache.maximumDownloadBytes
            ), !outcome.data.isEmpty else {
                return nil
            }
            return outcome.data
        }
    }
}
