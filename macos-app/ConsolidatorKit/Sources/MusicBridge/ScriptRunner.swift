// ScriptRunner.swift
// The injectable command boundary for the M5 orchestration — the Swift port
// of the Python reference implementation's `CommandRunner` protocol seam plus its three fixed
// command shapes (music_bridge.py:15-16, 92: READ_ARGS, COMPILE_ARGS,
// WRITE_ARGS). The reference passes argv arrays to one `run(args, input_text)`
// method; the Swift seam names the same three operations explicitly so that
// M6's OSAKit-based runner can implement them in-process without the
// orchestration changing:
//
//   .readJXA(script:)                      ⇔ osascript -l JavaScript -e <script>
//   .compileAppleScript(script:outputPath:) ⇔ osacompile -o <outputPath>, script on stdin
//   .executeCompiledScript(path:)           ⇔ osascript <path>
//
// Semantics the orchestration relies on (SubprocessRunner,
// music_bridge.py:121-140): `run` returns the command's standard output on
// success and THROWS on any failure — a thrown error never flips to success
// anywhere downstream. The real in-process implementation is `OSAKitRunner`
// (M6a); tests inject fakes.

import Foundation

/// One Music automation command, as the reference's fixed argv shapes name them.
public enum ScriptCommand: Equatable, Sendable {
    /// Run read-only JXA source and return its stdout (READ_ARGS).
    case readJXA(script: String)
    /// Compile AppleScript source into the artifact at `outputPath`
    /// (COMPILE_ARGS; the reference feeds the script via stdin).
    case compileAppleScript(script: String, outputPath: String)
    /// Execute the previously compiled artifact — never raw source
    /// (WRITE_ARGS).
    case executeCompiledScript(path: String)
}

/// Runs a Music automation command and returns its standard output.
/// Mirrors the Python `CommandRunner` protocol: failures are thrown, and the
/// error's description is what operators see (after sanitization).
public protocol ScriptRunner {
    @discardableResult
    func run(_ command: ScriptCommand) throws -> String
}

/// A concise, operator-safe Music automation failure
/// (music_bridge.py:102-103 MusicCommandError).
public struct MusicCommandError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// Thrown where the reference's ORCHESTRATION half raises ValueError (parsing,
/// ensure/assert preflight, readback verification). The pure-builder half
/// keeps its own `MusicScriptBuilderError` (M4).
public struct MusicBridgeError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(_ message: String) {
        self.message = message
    }
}
