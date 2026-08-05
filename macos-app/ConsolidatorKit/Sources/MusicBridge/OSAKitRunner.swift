// OSAKitRunner.swift
// The real, in-process ScriptRunner over OSAKit (M6a) — the Swift analog of
// the reference's SubprocessRunner (music_bridge.py:121-140), which shells out
// to osascript/osacompile. In-process execution is the point of the app: the
// signed app bundle itself becomes the Apple-event sender, clearing the
// -1701 automation-runner boundary. The observable seam contract is
// unchanged from what the M5 orchestration and its FakeRunner tests assume:
// stdout-equivalent text on success, a thrown MusicCommandError on ANY
// failure (a thrown error never flips to success downstream).
//
// Binding contract (final whole-branch review, M6 amendment; m6a-brief.md):
// 1. STATEFUL compile→execute pairing keyed by outputPath.
//    `.compileAppleScript` compiles via compileAndReturnError — the COMPILE
//    GATE — and on success retains the compiled OSAScript instance keyed by
//    outputPath (nothing is written to disk). `.executeCompiledScript`
//    executes ONLY an instance this runner itself compiled, on the SAME
//    OSAScript object; an unknown path FAILS CLOSED — the runner never loads
//    or compiles-on-demand from disk. A failed (re)compile retains nothing
//    for its path, evicting any earlier instance at the same key.
// 2. `.readJXA` runs OSAScript(source:language: JavaScript) through
//    compileAndReturnError then executeAndReturnError, returning the
//    script's text result as the seam's "stdout".
// 3. HAZARD: executeAndReturnError's return is mis-annotated non-optional —
//    it is handled as optional here, and a nil descriptor (with or without
//    an error dictionary) is a failure, never a silent success. A NON-nil
//    'null' descriptor (a script with no result) is a success with empty
//    output, the analog of an osascript run that prints nothing.
// 4. Descriptor→String SCALAR FIDELITY (live-phase risk R3): 'utxt' results
//    are decoded from the descriptor's RAW UTF-16 data in native byte order,
//    never through NSAppleEventDescriptor.stringValue — stringValue strips a
//    leading U+FEFF content scalar by misreading it as a byte-order mark
//    (verified empirically 2026-08-01; the in-process 'utxt' data carries no
//    added BOM for either JXA or AppleScript results). Decoding is strict:
//    odd byte counts and lone surrogates fail closed rather than being
//    replaced or dropped (stringValue corrupts lone surrogates to U+FFFD).
//    If a hypothetical future OSA component DID prepend a BOM, it would
//    surface as a spurious leading U+FEFF and be rejected fail-closed — on
//    the read path first by the StrictJSONScanner wire gate ("Music
//    returned invalid JSON"; a document-leading BOM is invalid JSON), with
//    the scalar-exact comparisons as the backstop elsewhere — instead of
//    silently normalizing wire text. Non-'utxt' results convert only from a
//    strict whitelist ('null' → "", 'long' → exact decimal digits); every
//    other type fails closed, because stringValue can silently normalize
//    (e.g. it strips the UTF-8 BOM from a raw 'utf8' data descriptor).
// 5. OSA error dictionaries map through sanitizedStderr (the reference's
//    _sanitized_stderr) into single-line, diagnosable MusicCommandError
//    messages carrying the OSA error number, mirroring how SubprocessRunner
//    wraps subprocess stderr.
// 6. CONCURRENCY: this class is intentionally NOT Sendable and must be used
//    from one thread/actor at a time — OSAScript is not thread-safe and the
//    orchestration (MusicBridgeSession) is strictly sequential. Do not share
//    one instance across concurrent tasks.

import Foundation
import OSAKit

/// In-process OSAKit implementation of the `ScriptRunner` seam.
/// Single-threaded use only (see the concurrency note above).
public final class OSAKitRunner: ScriptRunner {
    /// FourCharCode 'utxt' — Unicode text results.
    private static let unicodeTextType: DescType = 0x7574_7874
    /// FourCharCode 'null' — the no-result descriptor.
    private static let nullType: DescType = 0x6E75_6C6C
    /// FourCharCode 'long' — SInt32 scalar results.
    private static let longIntegerType: DescType = 0x6C6F_6E67

    /// Compiled AppleScript instances keyed by the seam's outputPath. The
    /// path is an in-memory pairing key only; no artifact exists on disk.
    private var compiledScripts: [String: OSAScript] = [:]

    public init() {}

    @discardableResult
    public func run(_ command: ScriptCommand) throws -> String {
        switch command {
        case .readJXA(let script):
            return try readJXA(script)
        case .compileAppleScript(let script, let outputPath):
            return try compileAppleScript(script, outputPath: outputPath)
        case .executeCompiledScript(let path):
            return try executeCompiledScript(path)
        }
    }

    // MARK: commands

    private func readJXA(_ script: String) throws -> String {
        let osaScript = OSAScript(source: script, language: try Self.language(named: "JavaScript"))
        var compileError: NSDictionary?
        guard osaScript.compileAndReturnError(&compileError) else {
            throw MusicCommandError("JXA compilation failed: \(Self.errorDetail(compileError))")
        }
        return try Self.execute(osaScript, failurePrefix: "JXA execution failed")
    }

    private func compileAppleScript(_ script: String, outputPath: String) throws -> String {
        // Evict first: a failed recompile must never leave an earlier
        // instance executable under the same key.
        compiledScripts[outputPath] = nil
        let osaScript = OSAScript(source: script, language: try Self.language(named: "AppleScript"))
        var compileError: NSDictionary?
        guard osaScript.compileAndReturnError(&compileError) else {
            throw MusicCommandError(
                "AppleScript compilation failed: \(Self.errorDetail(compileError))"
            )
        }
        compiledScripts[outputPath] = osaScript
        // osacompile prints nothing on success; the seam's stdout is empty.
        return ""
    }

    private func executeCompiledScript(_ path: String) throws -> String {
        guard let osaScript = compiledScripts[path] else {
            throw MusicCommandError(
                "refusing to execute: this runner has no compiled script for path "
                    + sanitizedStderr(path)
            )
        }
        return try Self.execute(osaScript, failurePrefix: "compiled script execution failed")
    }

    // MARK: execution and result conversion

    private static func language(named name: String) throws -> OSALanguage {
        guard let language = OSALanguage(forName: name) else {
            throw MusicCommandError("OSA language \(name) is unavailable")
        }
        return language
    }

    private static func execute(_ osaScript: OSAScript, failurePrefix: String) throws -> String {
        var executionError: NSDictionary?
        // Contract hazard 3: the return type lies — assign through an
        // Optional so an actually-nil descriptor is caught, not trusted.
        let result: NSAppleEventDescriptor? = osaScript.executeAndReturnError(&executionError)
        guard let descriptor = result, executionError == nil else {
            throw MusicCommandError("\(failurePrefix): \(errorDetail(executionError))")
        }
        return try text(from: descriptor)
    }

    /// The seam's "stdout" for a result descriptor. 'null' → empty output;
    /// 'utxt' → strict raw UTF-16 decode; 'long' → exact decimal digits from
    /// the SInt32 value; EVERYTHING else fails closed (contract item 4). The
    /// former stringValue fallback is gone: stringValue silently normalizes —
    /// e.g. a 'utf8' raw-data descriptor `«data utf8EFBBBF41»` renders as
    /// "A", its UTF-8 BOM stripped (fix round 1, finding 1). Legitimate seam
    /// results never reach the refusal: readJXA results are JS strings
    /// ('utxt', or 'null'/'type' for undefined/null) and both writers end in
    /// AppleScript text returns ('utxt'). Note the reject-direction
    /// divergence from the osascript CLI, which would display-coerce and
    /// print results like `missing value` ('type'/'msng') with exit 0.
    private static func text(from descriptor: NSAppleEventDescriptor) throws -> String {
        switch descriptor.descriptorType {
        case nullType:
            return ""
        case unicodeTextType:
            return try decodeNativeUTF16(descriptor.data)
        case longIntegerType:
            // Rendered from the numeric value directly — no AE text
            // coercion is involved, so the digits are exact by construction.
            return String(descriptor.int32Value)
        default:
            throw MusicCommandError(
                "script result type \(typeName(descriptor.descriptorType))"
                    + " has no fidelity-safe text conversion"
            )
        }
    }

    /// Render a FourCharCode for diagnostics: quoted ASCII when printable,
    /// hex otherwise.
    private static func typeName(_ type: DescType) -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: type >> 24),
            UInt8(truncatingIfNeeded: type >> 16),
            UInt8(truncatingIfNeeded: type >> 8),
            UInt8(truncatingIfNeeded: type),
        ]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            return String(format: "0x%08X", type)
        }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }

    /// Strict UTF-16 decode of 'utxt' descriptor data in native byte order.
    /// Every code unit is content — no BOM detection, no lossy replacement;
    /// malformed data fails closed (see contract item 4).
    private static func decodeNativeUTF16(_ data: Data) throws -> String {
        guard data.count.isMultiple(of: 2) else {
            throw MusicCommandError("script result is not valid UTF-16 text")
        }
        var units = [UInt16](repeating: 0, count: data.count / 2)
        let copied = units.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        guard copied == data.count else {
            throw MusicCommandError("script result is not valid UTF-16 text")
        }
        var view = String.UnicodeScalarView()
        var decoder = UTF16()
        var iterator = units.makeIterator()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                view.append(scalar)
            case .emptyInput:
                return String(view)
            case .error:
                throw MusicCommandError("script result is not valid UTF-16 text")
            }
        }
    }

    /// Render an OSA error dictionary as a single-line, sanitized,
    /// number-carrying detail string (the reference's stderr-detail analog).
    private static func errorDetail(_ dictionary: NSDictionary?) -> String {
        guard let dictionary else { return "no error details" }
        let message = (dictionary[OSAScriptErrorMessageKey] as? String)
            ?? (dictionary[OSAScriptErrorBriefMessageKey] as? String)
        let sanitized = sanitizedStderr(message)
        let detail = sanitized.isEmpty ? "no error details" : sanitized
        if let number = dictionary[OSAScriptErrorNumberKey] as? NSNumber {
            return "error \(number.intValue): \(detail)"
        }
        return detail
    }
}
