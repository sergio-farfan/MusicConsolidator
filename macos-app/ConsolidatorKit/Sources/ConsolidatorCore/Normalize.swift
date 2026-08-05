// Normalize.swift
// Swift port of apple_music_consolidator/normalize.py.
//
// Reference reference (apple_music_consolidator/normalize.py):
//
//     def normalize_text(value: str) -> str:
//         text = unicodedata.normalize("NFKC", value).translate(_PUNCTUATION)
//         return re.sub(r"\s+", " ", text).strip().casefold()
//
//     def duration_to_ms(seconds: float | None) -> int | None:
//         return None if seconds is None else int(round(seconds * 1000))
//
//     def semantic_key(track) -> tuple[str, str, int] | None:
//         title, artist = normalize_text(track.title), normalize_text(track.artist)
//         if not title or not artist or track.duration_ms is None:
//             return None
//         return title, artist, track.duration_ms
//
// Parity is enforced by golden fixtures exported straight from the Python reference implementation
// (see macos-app/golden/*.json and ConsolidatorCoreTests.NormalizeGoldenTests).

import Foundation

/// The strict duplicate-matching key: normalized title, normalized artist, and
/// exact duration in milliseconds. Mirrors Python's `semantic_key` tuple.
///
/// Equality and hashing are at UNICODE-SCALAR level, NOT Swift `String`'s
/// default canonical equivalence. The reference groups keys in a Python dict,
/// which compares strings code-point-for-code-point; canonically-equivalent
/// but scalar-different normalized outputs (e.g. "\u{03B9}\u{0308}\u{0301}"
/// vs "\u{03CA}\u{0301}") must stay DISTINCT, exactly as Python keeps them
/// (binding M1 review finding; regression: SemanticKeyScalarTests).
public struct SemanticKey: Hashable, Sendable {
    public let title: String
    public let artist: String
    public let durationMs: Int

    public init(title: String, artist: String, durationMs: Int) {
        self.title = title
        self.artist = artist
        self.durationMs = durationMs
    }

    public static func == (lhs: SemanticKey, rhs: SemanticKey) -> Bool {
        lhs.durationMs == rhs.durationMs
            && lhs.title.unicodeScalars.elementsEqual(rhs.title.unicodeScalars)
            && lhs.artist.unicodeScalars.elementsEqual(rhs.artist.unicodeScalars)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(durationMs)
        // Length prefixes keep (title, artist) boundaries unambiguous so the
        // hash stays consistent with the scalar-level `==` above.
        hasher.combine(title.unicodeScalars.count)
        for scalar in title.unicodeScalars {
            hasher.combine(scalar.value)
        }
        hasher.combine(artist.unicodeScalars.count)
        for scalar in artist.unicodeScalars {
            hasher.combine(scalar.value)
        }
    }
}

/// Ordered to mirror Python's `str.maketrans` table in normalize.py exactly.
private let punctuationMap: [(String, String)] = [
    ("\u{2019}", "'"),  // ’ RIGHT SINGLE QUOTATION MARK
    ("\u{2018}", "'"),  // ‘ LEFT SINGLE QUOTATION MARK
    ("\u{201C}", "\""), // “ LEFT DOUBLE QUOTATION MARK
    ("\u{201D}", "\""), // ” RIGHT DOUBLE QUOTATION MARK
    ("\u{2013}", "-"),  // – EN DASH
    ("\u{2014}", "-"),  // — EM DASH
]

/// Sharp-s pre-map, kept as CROSS-OS-VERSION INSURANCE only. On the current
/// toolchain (macOS 26 / Swift 6.3), raw `.folding(options: .caseInsensitive,
/// locale: nil)` ALREADY performs full case folding and yields "ss" for both
/// ß (U+00DF) and ẞ (U+1E9E) — verified empirically during review (three
/// reviewers) and re-verified in fix round 1; an earlier claim here that
/// `.folding` keeps ß un-expanded was wrong (the failing first draft most
/// likely used `lowercased()`, which is simple case mapping). The pre-map is
/// harmless (its output is `.folding`'s own fixed point) and pins the reference's
/// casefold behavior for these two code points against ICU changes across OS
/// versions. Reference: Python `str.casefold()` -> "ss" for both.
private let caseFoldPreMap: [(String, String)] = [
    ("\u{00DF}", "ss"), // ß LATIN SMALL LETTER SHARP S
    ("\u{1E9E}", "ss"), // ẞ LATIN CAPITAL LETTER SHARP S
]

/// The exact set of code points Python `str.strip()` removes: every cp where
/// `chr(cp).isspace()` is True. Derived empirically from the reference runtime
/// (CPython 3.14.6, unicodedata 16.0.0) by sweeping all of 0x0-0x10FFFF —
/// 29 code points. This intentionally REPLACES Foundation's
/// `CharacterSet.whitespacesAndNewlines`, which contains U+200B ZERO WIDTH
/// SPACE (a legacy quirk; ZWSP is Cf, not whitespace — Python keeps it) and is
/// OS-version-dependent. Note U+001C-001F (file/group/record/unit separators)
/// ARE stripped: Python's `str.isspace()` is true for them.
/// Internal (not private) since M8 fix round 1: PlaylistGrouping's
/// near-match normalization collapses interior runs of this SAME
/// byte-verified set (Python str.split() semantics) — reusing it instead of
/// hand-writing a second whitespace table (the M4 ScalarSupport drift
/// lesson). Access-level-only change; the set's contents are untouched.
let pythonStripScalars: Set<Unicode.Scalar> = [
    "\u{0009}", // CHARACTER TABULATION
    "\u{000A}", // LINE FEED
    "\u{000B}", // LINE TABULATION
    "\u{000C}", // FORM FEED
    "\u{000D}", // CARRIAGE RETURN
    "\u{001C}", // INFORMATION SEPARATOR FOUR (FS)
    "\u{001D}", // INFORMATION SEPARATOR THREE (GS)
    "\u{001E}", // INFORMATION SEPARATOR TWO (RS)
    "\u{001F}", // INFORMATION SEPARATOR ONE (US)
    "\u{0020}", // SPACE
    "\u{0085}", // NEXT LINE (NEL)
    "\u{00A0}", // NO-BREAK SPACE
    "\u{1680}", // OGHAM SPACE MARK
    "\u{2000}", // EN QUAD
    "\u{2001}", // EM QUAD
    "\u{2002}", // EN SPACE
    "\u{2003}", // EM SPACE
    "\u{2004}", // THREE-PER-EM SPACE
    "\u{2005}", // FOUR-PER-EM SPACE
    "\u{2006}", // SIX-PER-EM SPACE
    "\u{2007}", // FIGURE SPACE
    "\u{2008}", // PUNCTUATION SPACE
    "\u{2009}", // THIN SPACE
    "\u{200A}", // HAIR SPACE
    "\u{2028}", // LINE SEPARATOR
    "\u{2029}", // PARAGRAPH SEPARATOR
    "\u{202F}", // NARROW NO-BREAK SPACE
    "\u{205F}", // MEDIUM MATHEMATICAL SPACE
    "\u{3000}", // IDEOGRAPHIC SPACE
]

/// Trim leading/trailing scalars exactly like Python `str.strip()`: drop
/// scalars in `pythonStripScalars` from both ends, at Unicode-scalar (code
/// point) granularity — NOT grapheme-cluster granularity — because the reference
/// operates on code points (e.g. a leading SPACE is stripped even when a
/// combining mark follows it and would form one grapheme cluster in Swift).
/// Internal (not private): Resolver.isAvailable ports the reference's
/// `cloud_status.strip().casefold()` and needs the same strip semantics.
func trimPythonWhitespace(_ value: String) -> String {
    let scalars = value.unicodeScalars
    guard let start = scalars.firstIndex(where: { !pythonStripScalars.contains($0) }),
          let end = scalars.lastIndex(where: { !pythonStripScalars.contains($0) }) else {
        return ""
    }
    return String(scalars[start...end])
}

/// Post-fold scalar corrections applied AFTER `.folding(options:
/// .caseInsensitive)` to reach Python `str.casefold()` byte parity where the
/// two disagree. Every entry was derived empirically from the reference by a
/// per-code-point `chr(cp).casefold()` sweep (CPython 3.14.6, unicodedata
/// 16.0.0) over U+13A0-13F5, U+13F8-13FD, U+AB70-ABBF, U+1C80-1C88; all
/// targets are single scalars.
///
/// - Cherokee: Unicode CaseFolding.txt folds the SMALL letters UP to the
///   capitals (smalls were added later, in Unicode 8), so Python's casefold
///   fixed points are the CAPITALS. Apple's `.folding` instead folds capitals
///   DOWN to smalls. A pre-map alone cannot fix this — `.folding` runs
///   afterward and folds pre-mapped capitals back down — so we correct
///   post-fold: any Cherokee small letter left after `.folding` (original
///   input or a folded-down capital) maps up to its capital. The reference sweep
///   showed both small blocks are offset-contiguous with their targets:
///   U+AB70+i -> U+13A0+i (80 code points) and U+13F8+i -> U+13F0+i (6).
/// - Historic Cyrillic U+1C80-1C88: Python casefolds them to modern Cyrillic
///   small letters; `.folding` leaves all nine unchanged (verified), so the
///   post-fold map sees them and applies the reference's targets.
private let postFoldScalarCorrections: [Unicode.Scalar: Unicode.Scalar] = {
    var map: [Unicode.Scalar: Unicode.Scalar] = [:]
    // Cherokee small letters -> Cherokee capital letters (reference casefold targets).
    for offset in 0...(0xABBF - 0xAB70) {
        map[Unicode.Scalar(0xAB70 + offset)!] = Unicode.Scalar(0x13A0 + offset)!
    }
    for offset in 0...(0x13FD - 0x13F8) {
        map[Unicode.Scalar(0x13F8 + offset)!] = Unicode.Scalar(0x13F0 + offset)!
    }
    // Historic Cyrillic -> modern Cyrillic small letters (reference casefold targets).
    let historicCyrillic: [(UInt32, UInt32)] = [
        (0x1C80, 0x0432), // ᲀ CYRILLIC SMALL LETTER ROUNDED VE      -> в VE
        (0x1C81, 0x0434), // ᲁ CYRILLIC SMALL LETTER LONG-LEGGED DE  -> д DE
        (0x1C82, 0x043E), // ᲂ CYRILLIC SMALL LETTER NARROW O        -> о O
        (0x1C83, 0x0441), // ᲃ CYRILLIC SMALL LETTER WIDE ES         -> с ES
        (0x1C84, 0x0442), // ᲄ CYRILLIC SMALL LETTER TALL TE         -> т TE
        (0x1C85, 0x0442), // ᲅ CYRILLIC SMALL LETTER THREE-LEGGED TE -> т TE
        (0x1C86, 0x044A), // ᲆ CYRILLIC SMALL LETTER TALL HARD SIGN  -> ъ HARD SIGN
        (0x1C87, 0x0463), // ᲇ CYRILLIC SMALL LETTER TALL YAT        -> ѣ YAT
        (0x1C88, 0xA64B), // ᲈ CYRILLIC SMALL LETTER UNBLENDED UK    -> ꙋ MONOGRAPH UK
    ]
    for (from, to) in historicCyrillic {
        map[Unicode.Scalar(from)!] = Unicode.Scalar(to)!
    }
    return map
}()

/// Normalize equivalent text without removing accents. Swift port of
/// `apple_music_consolidator.normalize.normalize_text`.
public func normalizeText(_ value: String) -> String {
    // 1. NFKC (compatibility decomposition + canonical composition).
    let nfkc = (value as NSString).precomposedStringWithCompatibilityMapping

    // 2. Map curly quotes and en/em dashes to their ASCII equivalents.
    var punctuationNormalized = nfkc
    for (from, to) in punctuationMap {
        punctuationNormalized = punctuationNormalized.replacingOccurrences(of: from, with: to)
    }

    // 3. Collapse runs of whitespace (spaces/tabs/newlines/etc.) to a single space.
    let collapsed = punctuationNormalized.replacingOccurrences(
        of: "\\s+",
        with: " ",
        options: .regularExpression
    )

    // 4. Trim leading/trailing whitespace with Python str.strip() semantics
    //    (NOT CharacterSet.whitespacesAndNewlines, which also trims U+200B —
    //    see pythonStripScalars doc comment).
    let trimmed = trimPythonWhitespace(collapsed)

    // 5.+6. Case-fold with Python str.casefold() parity (see pythonCasefold).
    return pythonCasefold(trimmed)
}

/// Python `str.casefold()` parity: sharp-s pre-map (insurance; see
/// caseFoldPreMap), ICU-backed case-insensitive folding, then post-fold scalar
/// corrections where `.folding` disagrees with Python casefold (Cherokee,
/// historic Cyrillic — see postFoldScalarCorrections). Extracted from
/// `normalizeText` steps 5-6 (behavior unchanged) because the resolver's
/// `isAvailable`/`isLossless` port the reference's bare `.casefold()` calls
/// (apple_music_consolidator/resolver.py lines 18-26) without the rest of the
/// normalization pipeline.
func pythonCasefold(_ value: String) -> String {
    var preFolded = value
    for (from, to) in caseFoldPreMap {
        preFolded = preFolded.replacingOccurrences(of: from, with: to)
    }
    let folded = preFolded.folding(options: .caseInsensitive, locale: nil)

    var corrected = String.UnicodeScalarView()
    corrected.reserveCapacity(folded.unicodeScalars.count)
    for scalar in folded.unicodeScalars {
        corrected.append(postFoldScalarCorrections[scalar] ?? scalar)
    }
    return String(corrected)
}

/// Convert seconds to the nearest millisecond, preserving absent values.
/// Uses round-half-to-even (banker's rounding) to match Python's `round()`
/// builtin, which is NOT round-half-away-from-zero.
public func durationToMs(_ seconds: Double?) -> Int? {
    seconds.map { Int(($0 * 1000).rounded(.toNearestOrEven)) }
}

/// Return the strict duplicate key, or nil when required values are absent.
/// Mirrors Python's `semantic_key`.
public func semanticKey(_ track: TrackSnapshot) -> SemanticKey? {
    let title = normalizeText(track.title)
    let artist = normalizeText(track.artist)
    guard !title.isEmpty, !artist.isEmpty, let durationMs = track.durationMs else {
        return nil
    }
    return SemanticKey(title: title, artist: artist, durationMs: durationMs)
}
