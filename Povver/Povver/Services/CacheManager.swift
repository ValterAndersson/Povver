import Foundation
import OSLog
import UIKit

// MARK: - Cache Configuration
struct CacheConfiguration {
    let memoryCountLimit: Int
    let diskSizeLimit: Int // in bytes
    let defaultTTL: TimeInterval
    
    static let `default` = CacheConfiguration(
        memoryCountLimit: 50,
        diskSizeLimit: 50 * 1024 * 1024, // 50MB
        defaultTTL: 3600 // 1 hour
    )
}

// MARK: - Cache Entry
private struct CacheEntry<T: Codable>: Codable {
    let value: T
    let timestamp: Date
    let ttl: TimeInterval
    
    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > ttl
    }
}

// MARK: - Cache Manager Protocol
protocol CacheManagerProtocol: Sendable {
    func get<T: Codable & Sendable>(_ key: String, type: T.Type) async -> T?
    func set<T: Codable & Sendable>(_ key: String, value: T, ttl: TimeInterval?) async
    func invalidate(matching pattern: String) async
    func invalidateAll() async
    func preload(keys: [String]) async
}

// MARK: - Memory Cache Wrapper
final class MemoryCacheWrapper: @unchecked Sendable {
    private let cache: NSCache<NSString, NSData>
    private let lock = NSLock()
    
    init(countLimit: Int) {
        self.cache = NSCache<NSString, NSData>()
        self.cache.countLimit = countLimit
    }
    
    func object(forKey key: NSString) -> NSData? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key)
    }
    
    func setObject(_ obj: NSData, forKey key: NSString) {
        lock.lock()
        defer { lock.unlock() }
        cache.setObject(obj, forKey: key)
    }
    
    func removeAllObjects() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAllObjects()
    }
}

// MARK: - High Performance Cache Manager
actor CacheManager: CacheManagerProtocol {
    private let logger = Logger(subsystem: "com.povver.app", category: "CacheManager")
    private let configuration: CacheConfiguration
    
    // Multi-level cache
    private let memoryCache: MemoryCacheWrapper
    private let diskCache: DiskCache
    
    // Cache statistics
    private var hitCount = 0
    private var missCount = 0
    private var lastCleanup = Date()
    
    init(configuration: CacheConfiguration = .default) {
        self.configuration = configuration
        self.memoryCache = MemoryCacheWrapper(countLimit: configuration.memoryCountLimit)
        self.diskCache = DiskCache(sizeLimit: configuration.diskSizeLimit)
        
        Task {
            await setupNotifications()
        }
    }
    
    // MARK: - Public Methods
    
    func get<T: Codable & Sendable>(_ key: String, type: T.Type) async -> T? {
        let nsKey = key as NSString
        
        // Level 1: Memory cache (fastest)
        if let data = memoryCache.object(forKey: nsKey) {
            hitCount += 1
            logger.debug("Memory cache hit for key: \(key)")
            return decode(data as Data, type: type)
        }
        
        // Level 2: Disk cache
        if let diskData = await diskCache.get(key) {
            if let entry: CacheEntry<T> = decode(diskData, type: CacheEntry<T>.self),
               !entry.isExpired {
                hitCount += 1
                logger.debug("Disk cache hit for key: \(key)")
                
                // Promote to memory cache
                memoryCache.setObject(diskData as NSData, forKey: nsKey)
                return entry.value
            }
        }
        
        missCount += 1
        logger.debug("Cache miss for key: \(key)")
        return nil
    }
    
    func set<T: Codable & Sendable>(_ key: String, value: T, ttl: TimeInterval? = nil) async {
        let entry = CacheEntry(
            value: value,
            timestamp: Date(),
            ttl: ttl ?? configuration.defaultTTL
        )
        
        guard let data = encode(entry) else {
            logger.error("Failed to encode cache entry for key: \(key)")
            return
        }
        
        let nsKey = key as NSString
        let nsData = data as NSData
        
        // Write to both caches
        memoryCache.setObject(nsData, forKey: nsKey)
        await diskCache.set(key, data: data)
        
        // Periodic cleanup
        await cleanupIfNeeded()
    }
    
    func invalidate(matching pattern: String) async {
        logger.info("Invalidating cache entries matching pattern: \(pattern)")
        
        // Clear from memory cache
        memoryCache.removeAllObjects()
        
        // Clear from disk cache
        await diskCache.invalidate(matching: pattern)
    }
    
    func invalidateAll() async {
        logger.info("Invalidating all cache entries")
        memoryCache.removeAllObjects()
        await diskCache.invalidateAll()
        hitCount = 0
        missCount = 0
    }
    
    func preload(keys: [String]) async {
        logger.info("Preloading \(keys.count) cache keys")
        
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask { [weak self] in
                    if let data = await self?.diskCache.get(key) {
                        self?.memoryCache.setObject(data as NSData, forKey: key as NSString)
                    }
                }
            }
        }
    }
    
    // MARK: - Cache Statistics
    
    func getStatistics() async -> CacheStatistics {
        let hitRate = hitCount + missCount > 0 
            ? Double(hitCount) / Double(hitCount + missCount) 
            : 0
        
        return CacheStatistics(
            hitCount: hitCount,
            missCount: missCount,
            hitRate: hitRate,
            memoryUsage: currentMemoryUsage(),
            diskUsage: await diskCache.getCurrentSize()
        )
    }
    
    // MARK: - Private Methods
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleMemoryWarning() }
        }
    }
    
    private func handleMemoryWarning() async {
        logger.warning("Received memory warning, clearing memory cache")
        memoryCache.removeAllObjects()
    }
    
    private func cleanupIfNeeded() async {
        let hoursSinceLastCleanup = Date().timeIntervalSince(lastCleanup) / 3600
        if hoursSinceLastCleanup > 1 {
            await diskCache.cleanup()
            lastCleanup = Date()
        }
    }
    
    private func currentMemoryUsage() -> Int {
        // Approximate memory usage calculation
        let usage = 0
        // Note: NSCache doesn't expose its contents, so this is an approximation
        return usage
    }
    
    private func encode<T: Codable>(_ object: T) -> Data? {
        try? JSONEncoder().encode(object)
    }
    
    private func decode<T: Codable>(_ data: Data, type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Disk Cache Implementation
private actor DiskCache {
    private let logger = Logger(subsystem: "com.povver.app", category: "DiskCache")
    private let sizeLimit: Int
    private let cacheDirectory: URL
    private var currentSize: Int = 0
    
    init(sizeLimit: Int) {
        self.sizeLimit = sizeLimit
        
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cacheDir.appendingPathComponent("dashboard_cache", isDirectory: true)
        
        Task {
            await createDirectoryIfNeeded()
            await calculateCurrentSize()
        }
    }
    
    func get(_ key: String) async -> Data? {
        let fileURL = cacheDirectory.appendingPathComponent(key.sha256())
        return try? Data(contentsOf: fileURL)
    }
    
    func set(_ key: String, data: Data) async {
        let fileURL = cacheDirectory.appendingPathComponent(key.sha256())

        do {
            try data.write(to: fileURL, options: .atomic)

            // Apply file protection to encrypt file when device is locked
            do {
                try (fileURL as NSURL).setResourceValue(
                    URLFileProtection.complete,
                    forKey: .fileProtectionKey
                )
            } catch {
                // File protection is best-effort; don't crash if it fails
                logger.warning("Failed to set file protection on cache file: \(error)")
            }

            currentSize += data.count

            // Evict old entries if needed
            if currentSize > sizeLimit {
                await evictOldEntries()
            }
        } catch {
            logger.error("Failed to write cache file: \(error)")
        }
    }
    
    func invalidate(matching pattern: String) async {
        // For now, clear all since we're using hashed keys
        await invalidateAll()
    }
    
    func invalidateAll() async {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for file in files {
                try FileManager.default.removeItem(at: file)
            }
            currentSize = 0
        } catch {
            logger.error("Failed to clear disk cache: \(error)")
        }
    }
    
    func cleanup() async {
        await evictExpiredEntries()
    }
    
    func getCurrentSize() -> Int {
        return currentSize
    }
    
    private func createDirectoryIfNeeded() async {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    private func calculateCurrentSize() async {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
            currentSize = files.reduce(0) { total, file in
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return total + size
            }
        } catch {
            logger.error("Failed to calculate cache size: \(error)")
        }
    }
    
    private func evictOldEntries() async {
        // Implement LRU eviction based on file access times
        logger.info("Evicting old cache entries to maintain size limit")
        // TODO: Implement LRU eviction
    }
    
    private func evictExpiredEntries() async {
        // TODO: Implement expiration check
    }
}

// MARK: - Cache Statistics
struct CacheStatistics {
    let hitCount: Int
    let missCount: Int
    let hitRate: Double
    let memoryUsage: Int
    let diskUsage: Int
}

// MARK: - String Extension for SHA256
private extension String {
    func sha256() -> String {
        // Simple hash for filename
        let data = Data(self.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }
}
