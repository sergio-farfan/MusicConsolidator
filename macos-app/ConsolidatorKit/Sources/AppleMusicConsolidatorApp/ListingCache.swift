// ListingCache.swift
// M11 — the persisted listing cache: names/persistent IDs/counts + the scan
// timestamp, as lightweight JSON under Application Support. THE CACHE
// SERVES THE BROWSER ONLY: audits and applies remain live-read against
// Music without exception — that line is the fail-closed foundation and is
// not negotiable. The cache is best-effort in both directions: any load or
// save failure silently degrades to the M8 behavior (scan explicitly).

import Foundation
import ConsolidatorCore

nonisolated struct CachedListingEntry: Codable, Equatable, Sendable {
    let playlistId: Double
    let name: String
    let persistentId: String
    let trackCount: Int
    let isSmart: Bool
    let specialKind: String
}

nonisolated struct CachedListing: Codable, Equatable, Sendable {
    let entries: [CachedListingEntry]
    let scannedAt: Date
}

nonisolated func cachedListing(
    from listings: [PlaylistListing],
    scannedAt: Date
) -> CachedListing {
    CachedListing(
        entries: listings.map {
            CachedListingEntry(
                playlistId: $0.playlistId,
                name: $0.name,
                persistentId: $0.persistentId,
                trackCount: $0.trackCount,
                isSmart: $0.isSmart,
                specialKind: $0.specialKind
            )
        },
        scannedAt: scannedAt
    )
}

nonisolated func playlistListings(from cache: CachedListing) -> [PlaylistListing] {
    cache.entries.map {
        PlaylistListing(
            playlistId: $0.playlistId,
            name: $0.name,
            persistentId: $0.persistentId,
            trackCount: $0.trackCount,
            isSmart: $0.isSmart,
            specialKind: $0.specialKind
        )
    }
}

/// Best-effort load: nil on ANY failure (missing, unreadable, undecodable).
nonisolated func loadListingCache(at url: URL) -> CachedListing? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(CachedListing.self, from: data)
}

/// Best-effort save (creates the directory if needed; failures are silent —
/// the cache is never load-bearing).
nonisolated func saveListingCache(_ cache: CachedListing, at url: URL) {
    guard let data = try? JSONEncoder().encode(cache) else { return }
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? data.write(to: url)
}

/// "Scanned just now / Nm ago / Nh ago / Nd ago" — the staleness indicator.
nonisolated func listingStalenessText(scannedAt: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(scannedAt))
    if seconds < 60 { return "Scanned just now" }
    if seconds < 3600 { return "Scanned \(Int(seconds / 60))m ago" }
    if seconds < 86400 { return "Scanned \(Int(seconds / 3600))h ago" }
    return "Scanned \(Int(seconds / 86400))d ago"
}

/// The default cache location (Application Support/AppleMusicConsolidator).
nonisolated func defaultListingCacheDirectoryPath() -> String {
    let base = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("AppleMusicConsolidator", isDirectory: true).path
}
