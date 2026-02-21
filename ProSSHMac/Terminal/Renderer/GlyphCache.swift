// GlyphCache.swift
// ProSSHV2
//
// LRU glyph cache for the Metal terminal renderer.
// Maps GlyphKey (codepoint + style) to AtlasEntry (texture atlas location)
// using a flat-slot LRU list + dictionary for O(1) lookup and O(1) eviction.

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
/// Uses a flat-slot doubly-linked list (integer indices) combined with a hash map
/// to achieve O(1) lookup, O(1) insertion, and O(1) eviction of the least-
/// recently-used entry.
/// This class is **not** thread-safe — the owning renderer is responsible for
/// synchronization (it runs on a dedicated render thread / actor).
///
/// Default capacity of 4096 entries comfortably holds ASCII x 3 style variants
/// (285 entries) plus a generous pool for CJK, emoji, and extended Unicode.
final class GlyphCache {

    private static let noIndex = -1

    // MARK: - Slot Storage

    /// Flat slot for one cache entry plus LRU links (index-based).
    private struct Slot {
        var key: GlyphKey
        var entry: AtlasEntry
        var prev: Int
        var next: Int
        var inUse: Bool
    }

    // MARK: - Properties

    /// Maximum number of entries before LRU eviction kicks in.
    let maxCapacity: Int

    /// O(1) lookup dictionary from glyph key to slot index.
    private var map: [GlyphKey: Int]
    /// Flat slot storage. Slots are reused via `freeList`.
    private var slots: ContiguousArray<Slot>
    /// Free slot indices available for reuse.
    private var freeList: [Int]
    /// Most recently used slot index.
    private var headIndex: Int
    /// Least recently used slot index.
    private var tailIndex: Int

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
        self.slots = []
        self.slots.reserveCapacity(maxCapacity)
        self.freeList = []
        self.freeList.reserveCapacity(maxCapacity)
        self.headIndex = Self.noIndex
        self.tailIndex = Self.noIndex
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
        guard let index = map[key], slots[index].inUse else { return nil }
        moveToHead(index)
        return slots[index].entry
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
        if let existingIndex = map[key], slots[existingIndex].inUse {
            // Update existing entry and promote to MRU
            slots[existingIndex].entry = entry
            moveToHead(existingIndex)
            return
        }

        // Evict exactly one LRU entry when at capacity, then reuse the slot.
        if map.count >= maxCapacity, tailIndex != Self.noIndex {
            let lruIndex = tailIndex
            map.removeValue(forKey: slots[lruIndex].key)
            detach(lruIndex)

            slots[lruIndex].key = key
            slots[lruIndex].entry = entry
            slots[lruIndex].inUse = true
            addToHead(lruIndex)
            map[key] = lruIndex
            return
        }

        let index: Int
        if let recycled = freeList.popLast() {
            index = recycled
            slots[index].key = key
            slots[index].entry = entry
            slots[index].prev = Self.noIndex
            slots[index].next = Self.noIndex
            slots[index].inUse = true
        } else {
            index = slots.count
            slots.append(Slot(
                key: key,
                entry: entry,
                prev: Self.noIndex,
                next: Self.noIndex,
                inUse: true
            ))
        }

        addToHead(index)
        map[key] = index
    }

    /// Remove a specific entry from the cache.
    ///
    /// - Parameter key: The glyph key to remove.
    /// - Returns: The removed `AtlasEntry`, or `nil` if the key was not cached.
    @discardableResult
    func remove(_ key: GlyphKey) -> AtlasEntry? {
        guard let index = map.removeValue(forKey: key), slots[index].inUse else { return nil }
        let entry = slots[index].entry
        detach(index)
        slots[index].inUse = false
        freeList.append(index)
        return entry
    }

    /// Remove all entries from the cache.
    /// Typically called when the font changes and all cached glyphs become invalid.
    func clear() {
        map.removeAll(keepingCapacity: true)
        headIndex = Self.noIndex
        tailIndex = Self.noIndex
        freeList.removeAll(keepingCapacity: true)

        if !slots.isEmpty {
            for idx in slots.indices.reversed() {
                slots[idx].inUse = false
                slots[idx].prev = Self.noIndex
                slots[idx].next = Self.noIndex
                freeList.append(idx)
            }
        }
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
    @inline(__always)
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

    /// Add a slot to the MRU position.
    private func addToHead(_ index: Int) {
        slots[index].prev = Self.noIndex
        slots[index].next = headIndex

        if headIndex != Self.noIndex {
            slots[headIndex].prev = index
        }

        headIndex = index
        if tailIndex == Self.noIndex {
            tailIndex = index
        }
    }

    /// Detach a slot from its current position in the LRU chain.
    private func detach(_ index: Int) {
        let prev = slots[index].prev
        let next = slots[index].next

        if prev != Self.noIndex {
            slots[prev].next = next
        } else {
            headIndex = next
        }

        if next != Self.noIndex {
            slots[next].prev = prev
        } else {
            tailIndex = prev
        }

        slots[index].prev = Self.noIndex
        slots[index].next = Self.noIndex
    }

    /// Move an existing slot to MRU position.
    private func moveToHead(_ index: Int) {
        guard headIndex != index else { return }
        detach(index)
        addToHead(index)
    }
}
