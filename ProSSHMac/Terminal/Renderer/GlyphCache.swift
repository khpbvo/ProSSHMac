// GlyphCache.swift
// ProSSHV2
//
// LRU glyph cache for the Metal terminal renderer.
// Maps GlyphKey (codepoint + style) to AtlasEntry (texture atlas location)
// using a doubly-linked list + dictionary for O(1) lookup and O(1) eviction.

import Foundation

// MARK: - AtlasEntry

/// Describes where a rasterized glyph lives inside a texture atlas page.
/// Packed for minimal memory footprint (8 bytes total).
struct AtlasEntry: Sendable {
    /// Which atlas texture page this glyph resides in.
    let atlasPage: UInt8

    /// Pixel X coordinate of the glyph origin in the atlas.
    let x: UInt16

    /// Pixel Y coordinate of the glyph origin in the atlas.
    let y: UInt16

    /// Glyph pixel width (>1 for wide/CJK characters).
    let width: UInt8

    /// Horizontal bearing offset from the pen position (pixels).
    let bearingX: Int8

    /// Vertical bearing offset from the baseline (pixels, positive = up).
    let bearingY: Int8
}

// MARK: - GlyphCache

/// LRU cache mapping `GlyphKey` to `AtlasEntry` for the Metal terminal renderer.
///
/// Uses a doubly-linked list combined with a hash map to achieve O(1) lookup,
/// O(1) insertion, and O(1) eviction of the least-recently-used entry.
/// This class is **not** thread-safe — the owning renderer is responsible for
/// synchronization (it runs on a dedicated render thread / actor).
///
/// Default capacity of 4096 entries comfortably holds ASCII x 3 style variants
/// (285 entries) plus a generous pool for CJK, emoji, and extended Unicode.
final class GlyphCache {

    // MARK: - Linked List Node

    /// Doubly-linked list node holding a cached key-entry pair.
    /// Nodes form a most-recently-used (head) to least-recently-used (tail) chain.
    private final class Node {
        let key: GlyphKey
        var entry: AtlasEntry
        var prev: Node?
        var next: Node?

        init(key: GlyphKey, entry: AtlasEntry) {
            self.key = key
            self.entry = entry
        }
    }

    // MARK: - Properties

    /// Maximum number of entries before LRU eviction kicks in.
    let maxCapacity: Int

    /// O(1) lookup dictionary from glyph key to linked-list node.
    private var map: [GlyphKey: Node]

    /// Sentinel head node (most recently used entries are near head.next).
    private let head: Node

    /// Sentinel tail node (least recently used entries are near tail.prev).
    private let tail: Node

    /// Keys evicted during the most recent insert batch, available for the caller
    /// to free corresponding atlas regions. Cleared on each call to `insert`.
    private(set) var lastEvictedKeys: [GlyphKey] = []

    // MARK: - Initialization

    /// Create a glyph cache with the specified maximum capacity.
    ///
    /// - Parameter maxCapacity: Maximum entries before LRU eviction.
    ///   Defaults to 4096, which covers ASCII x 3 variants (285) plus
    ///   ample room for CJK, emoji, and other Unicode glyphs.
    init(maxCapacity: Int = 4096) {
        precondition(maxCapacity > 0, "GlyphCache capacity must be positive")
        self.maxCapacity = maxCapacity
        self.map = Dictionary(minimumCapacity: maxCapacity)

        // Create sentinel nodes. Their key/entry values are never read.
        let sentinelKey = GlyphKey(codepoint: 0, bold: false, italic: false)
        let sentinelEntry = AtlasEntry(
            atlasPage: 0, x: 0, y: 0, width: 0, bearingX: 0, bearingY: 0
        )
        self.head = Node(key: sentinelKey, entry: sentinelEntry)
        self.tail = Node(key: sentinelKey, entry: sentinelEntry)
        self.head.next = self.tail
        self.tail.prev = self.head
    }

    // MARK: - Public API

    /// The current number of cached entries.
    var count: Int { map.count }

    /// Whether the cache contains an entry for the given key (does not update access order).
    func contains(_ key: GlyphKey) -> Bool {
        map[key] != nil
    }

    /// Look up a glyph entry and promote it to most-recently-used.
    ///
    /// - Parameter key: The glyph key to look up.
    /// - Returns: The cached `AtlasEntry`, or `nil` if not present.
    func lookup(_ key: GlyphKey) -> AtlasEntry? {
        guard let node = map[key] else { return nil }
        moveToHead(node)
        return node.entry
    }

    /// Insert or update a glyph entry in the cache.
    ///
    /// If the key already exists, its entry is updated and promoted to
    /// most-recently-used. If inserting a new key would exceed `maxCapacity`,
    /// the least-recently-used entry is evicted first.
    ///
    /// - Parameters:
    ///   - key: The glyph key.
    ///   - entry: The atlas entry describing the glyph's texture location.
    func insert(_ key: GlyphKey, entry: AtlasEntry) {
        lastEvictedKeys.removeAll(keepingCapacity: true)

        if let existingNode = map[key] {
            // Update existing entry and promote to MRU
            existingNode.entry = entry
            moveToHead(existingNode)
            return
        }

        // Evict LRU entries until we have room
        while map.count >= maxCapacity {
            if let lruNode = removeTail() {
                map.removeValue(forKey: lruNode.key)
                lastEvictedKeys.append(lruNode.key)
            }
        }

        // Insert new node at head (most recently used)
        let newNode = Node(key: key, entry: entry)
        map[key] = newNode
        addToHead(newNode)
    }

    /// Remove a specific entry from the cache.
    ///
    /// - Parameter key: The glyph key to remove.
    /// - Returns: The removed `AtlasEntry`, or `nil` if the key was not cached.
    @discardableResult
    func remove(_ key: GlyphKey) -> AtlasEntry? {
        guard let node = map.removeValue(forKey: key) else { return nil }
        detach(node)
        return node.entry
    }

    /// Remove all entries from the cache.
    /// Typically called when the font changes and all cached glyphs become invalid.
    func clear() {
        map.removeAll(keepingCapacity: true)
        head.next = tail
        tail.prev = head
        lastEvictedKeys.removeAll()
    }

    // MARK: - Pre-Population

    /// Pre-populate the cache with printable ASCII glyphs (0x20 through 0x7E)
    /// across regular, bold, and italic variants.
    ///
    /// This ensures the most common terminal characters (95 codepoints x 3 styles
    /// = 285 entries) are immediately available without cache misses during
    /// the first frame of rendering.
    ///
    /// - Parameter rasterize: A closure that rasterizes a single glyph key and
    ///   returns its atlas entry, or `nil` if rasterization failed. The closure
    ///   is responsible for interacting with the font manager and atlas allocator.
    func prePopulateASCII(using rasterize: (GlyphKey) -> AtlasEntry?) {
        let styles: [(bold: Bool, italic: Bool)] = [
            (false, false),  // regular
            (true,  false),  // bold
            (false, true),   // italic
        ]

        for style in styles {
            for codepoint: UInt32 in 0x20...0x7E {
                let key = GlyphKey(
                    codepoint: codepoint,
                    bold: style.bold,
                    italic: style.italic
                )

                // Skip if already cached (e.g., from a previous partial populate)
                guard map[key] == nil else { continue }

                if let entry = rasterize(key) {
                    insert(key, entry: entry)
                }
            }
        }
    }

    /// Async variant of `prePopulateASCII` for use when rasterization is async
    /// (e.g., involves Core Text calls that should yield periodically).
    ///
    /// - Parameter rasterize: An async closure that rasterizes a single glyph key
    ///   and returns its atlas entry, or `nil` if rasterization failed.
    func prePopulateASCII(using rasterize: (GlyphKey) async -> AtlasEntry?) async {
        let styles: [(bold: Bool, italic: Bool)] = [
            (false, false),  // regular
            (true,  false),  // bold
            (false, true),   // italic
        ]

        for style in styles {
            for codepoint: UInt32 in 0x20...0x7E {
                let key = GlyphKey(
                    codepoint: codepoint,
                    bold: style.bold,
                    italic: style.italic
                )

                guard map[key] == nil else { continue }

                if let entry = await rasterize(key) {
                    insert(key, entry: entry)
                }
            }
        }
    }

    // MARK: - Diagnostics

    /// Hit rate statistics for profiling. Reset with `resetStats()`.
    private(set) var hits: Int = 0
    private(set) var misses: Int = 0

    /// The cache hit rate as a fraction (0.0 to 1.0).
    /// Returns 0 if no lookups have been recorded.
    var hitRate: Double {
        let total = hits + misses
        guard total > 0 else { return 0 }
        return Double(hits) / Double(total)
    }

    /// Perform a lookup that also records hit/miss statistics.
    ///
    /// - Parameter key: The glyph key to look up.
    /// - Returns: The cached `AtlasEntry`, or `nil` if not present.
    func trackedLookup(_ key: GlyphKey) -> AtlasEntry? {
        if let entry = lookup(key) {
            hits += 1
            return entry
        }
        misses += 1
        return nil
    }

    /// Reset hit/miss counters.
    func resetStats() {
        hits = 0
        misses = 0
    }

    // MARK: - Private Helpers

    /// Add a node immediately after the head sentinel (most-recently-used position).
    private func addToHead(_ node: Node) {
        node.prev = head
        node.next = head.next
        head.next?.prev = node
        head.next = node
    }

    /// Detach a node from its current position in the doubly-linked list.
    private func detach(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        node.prev = nil
        node.next = nil
    }

    /// Move an existing node to the head (most-recently-used position).
    private func moveToHead(_ node: Node) {
        detach(node)
        addToHead(node)
    }

    /// Remove and return the node immediately before the tail sentinel
    /// (the least-recently-used entry). Returns `nil` if the list is empty.
    private func removeTail() -> Node? {
        guard let lruNode = tail.prev, lruNode !== head else { return nil }
        detach(lruNode)
        return lruNode
    }
}
