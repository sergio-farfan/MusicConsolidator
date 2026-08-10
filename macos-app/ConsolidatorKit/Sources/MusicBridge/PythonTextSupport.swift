// PythonTextSupport.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Byte-faithful ports of the Python text formatting the orchestration's
// operator-facing messages depend on:
//   - `repr(str)` — the `{value!r}` interpolations in every mismatch message
//     (quote selection, short escapes, \xXX/\uXXXX/\UXXXXXXXX for
//     non-printables, printability per Unicode general category);
//   - `_sanitized_stderr` / `_sanitized_exception` (music_bridge.py:106-118) —
//     non-printables to spaces, whitespace collapse, 500-code-point cap.
// Everything operates on Unicode scalars: Python strings are code-point
// sequences, and grapheme-level operations could merge or reorder what the
// reference treats as distinct characters.

import Foundation

/// Python `str.isprintable()` for one code point: false for the Other (Cc,
/// Cf, Cs, Co, Cn) and Separator (Zl, Zp, Zs) categories, except U+0020.
func isPythonPrintable(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.value == 0x20 { return true }
    switch scalar.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned,
         .lineSeparator, .paragraphSeparator, .spaceSeparator:
        return false
    default:
        return true
    }
}

/// Python `repr()` of a str. Quote selection: single quotes unless the text
/// contains a single quote and no double quote. Escapes: the quote and
/// backslash; \t \n \r; other C0 controls and DEL as \xXX; non-printables as
/// \xXX / \uXXXX / \UXXXXXXXX (lowercase hex); printable scalars pass raw.
func pythonRepr(_ value: String) -> String {
    var containsSingleQuote = false
    var containsDoubleQuote = false
    for scalar in value.unicodeScalars {
        if scalar.value == 0x27 { containsSingleQuote = true }
        if scalar.value == 0x22 { containsDoubleQuote = true }
    }
    let quote: Unicode.Scalar = (containsSingleQuote && !containsDoubleQuote) ? "\"" : "'"

    var encoded = String(String.UnicodeScalarView([quote]))
    for scalar in value.unicodeScalars {
        if scalar == quote || scalar.value == 0x5C {
            encoded.unicodeScalars.append("\\")
            encoded.unicodeScalars.append(scalar)
        } else if scalar.value == 0x09 {
            encoded += "\\t"
        } else if scalar.value == 0x0A {
            encoded += "\\n"
        } else if scalar.value == 0x0D {
            encoded += "\\r"
        } else if scalar.value < 0x20 || scalar.value == 0x7F {
            encoded += String(format: "\\x%02x", scalar.value)
        } else if isPythonPrintable(scalar) {
            encoded.unicodeScalars.append(scalar)
        } else if scalar.value <= 0xFF {
            encoded += String(format: "\\x%02x", scalar.value)
        } else if scalar.value <= 0xFFFF {
            encoded += String(format: "\\u%04x", scalar.value)
        } else {
            encoded += String(format: "\\U%08x", scalar.value)
        }
    }
    encoded.unicodeScalars.append(quote)
    return encoded
}

/// Python `repr()` of `int | None` (duration/bit rate/sample rate fields).
func pythonRepr(_ value: Int?) -> String {
    value.map(String.init) ?? "None"
}

/// Python `repr()` of a bool (the file-track flag).
func pythonRepr(_ value: Bool) -> String {
    value ? "True" : "False"
}

/// music_bridge.py:106-113 `_sanitized_stderr`: replace non-printable code
/// points with spaces, collapse whitespace runs (after the printable pass the
/// only whitespace left is U+0020), and cap at `limit` code points with a
/// trailing ellipsis.
func sanitizedStderr(_ value: String?, limit: Int = 500) -> String {
    var printable = String.UnicodeScalarView()
    for scalar in (value ?? "").unicodeScalars {
        printable.append(isPythonPrintable(scalar) ? scalar : " ")
    }

    var words: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in printable {
        if scalar.value == 0x20 {
            if !current.isEmpty {
                words.append(String(current))
                current = String.UnicodeScalarView()
            }
        } else {
            current.append(scalar)
        }
    }
    if !current.isEmpty {
        words.append(String(current))
    }
    let normalized = words.joined(separator: " ")

    let scalars = Array(normalized.unicodeScalars)
    guard scalars.count > limit else { return normalized }
    var prefix = scalars.prefix(limit - 1)
    while let last = prefix.last, last.value == 0x20 {
        prefix = prefix.dropLast()
    }
    return String(String.UnicodeScalarView(prefix)) + "…"
}

/// music_bridge.py:116-118 `_sanitized_exception`: the sanitized message, or
/// the error's type name when the message sanitizes to nothing.
func sanitizedException(_ error: Error) -> String {
    let detail = sanitizedStderr(String(describing: error))
    return detail.isEmpty ? String(describing: type(of: error)) : detail
}
