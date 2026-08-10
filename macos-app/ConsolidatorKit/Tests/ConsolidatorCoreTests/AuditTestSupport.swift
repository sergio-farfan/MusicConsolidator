// AuditTestSupport.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Shared M3 test helpers: unique temp directories (tests write ONLY under
// FileManager.temporaryDirectory), an excel-dialect CSV parser for
// column/row-level golden comparison, code-point rendering for mismatch
// diagnostics, and loadPlan/loadMergePlan rejection matchers.

import Foundation
import Testing
@testable import ConsolidatorCore

/// Run `body` with a fresh unique directory under the system temp dir,
/// removing it afterwards. All artifact-writing tests go through this.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConsolidatorKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

func codePointRendering(_ value: String) -> String {
    value.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
}

/// Minimal parser for the reference's CSV output (Python csv "excel" dialect):
/// comma delimiter, double-quote quoting with `""` escapes, CRLF row
/// terminator (bare LF tolerated), newlines preserved inside quoted fields.
func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    let scalars = Array(text.unicodeScalars)
    var i = 0
    func endField() {
        row.append(field)
        field = ""
    }
    func endRow() {
        endField()
        rows.append(row)
        row = []
    }
    while i < scalars.count {
        let scalar = scalars[i]
        if inQuotes {
            if scalar == "\"" {
                if i + 1 < scalars.count && scalars[i + 1] == "\"" {
                    field.unicodeScalars.append("\"")
                    i += 2
                    continue
                }
                inQuotes = false
                i += 1
                continue
            }
            field.unicodeScalars.append(scalar)
            i += 1
            continue
        }
        switch scalar {
        case "\"":
            inQuotes = true
            i += 1
        case ",":
            endField()
            i += 1
        case "\r" where i + 1 < scalars.count && scalars[i + 1] == "\n":
            endRow()
            i += 2
        case "\n":
            endRow()
            i += 1
        default:
            field.unicodeScalars.append(scalar)
            i += 1
        }
    }
    if !field.isEmpty || !row.isEmpty {
        endRow()
    }
    return rows
}

/// Parse a CSV text into header-keyed row dictionaries (like csv.DictReader).
func parseCSVRecords(_ text: String) -> (header: [String], records: [[String: String]]) {
    let rows = parseCSV(text)
    guard let header = rows.first else { return ([], []) }
    let records = rows.dropFirst().map { row in
        Dictionary(uniqueKeysWithValues: zip(header, row))
    }
    return (header, records)
}

/// The distinct fail-closed loader rejection classes (PlanLoadError cases).
enum ExpectedLoadRejection {
    case fileUnreadable
    case malformedJSON
    case decodeRejected
    case integrityRejected
}

private func classify(_ error: PlanLoadError) -> ExpectedLoadRejection {
    switch error {
    case .fileUnreadable: return .fileUnreadable
    case .malformedJSON: return .malformedJSON
    case .decodeRejected: return .decodeRejected
    case .integrityRejected: return .integrityRejected
    }
}

/// Assert that loading `url` as a consolidation plan fails with the expected
/// PlanLoadError case and that its message contains every listed substring.
func expectPlanLoadRejection(
    _ url: URL,
    _ expected: ExpectedLoadRejection,
    messageContains parts: [String],
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    do {
        _ = try loadPlan(from: url)
        Issue.record("expected load rejection (\(parts))", sourceLocation: sourceLocation)
    } catch let error as PlanLoadError {
        #expect(
            classify(error) == expected,
            "wrong rejection class: \(error)",
            sourceLocation: sourceLocation
        )
        for part in parts {
            #expect(
                error.description.contains(part),
                "message \(error.description) lacks \(part)",
                sourceLocation: sourceLocation
            )
        }
    } catch {
        Issue.record("expected PlanLoadError, got \(error)", sourceLocation: sourceLocation)
    }
}

/// Merge-plan variant of `expectPlanLoadRejection`.
func expectMergePlanLoadRejection(
    _ url: URL,
    _ expected: ExpectedLoadRejection,
    messageContains parts: [String],
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    do {
        _ = try loadMergePlan(from: url)
        Issue.record("expected load rejection (\(parts))", sourceLocation: sourceLocation)
    } catch let error as PlanLoadError {
        #expect(
            classify(error) == expected,
            "wrong rejection class: \(error)",
            sourceLocation: sourceLocation
        )
        for part in parts {
            #expect(
                error.description.contains(part),
                "message \(error.description) lacks \(part)",
                sourceLocation: sourceLocation
            )
        }
    } catch {
        Issue.record("expected PlanLoadError, got \(error)", sourceLocation: sourceLocation)
    }
}

/// Mutation-plan variant of `expectPlanLoadRejection`.
func expectMutationPlanLoadRejection(
    _ url: URL,
    _ expected: ExpectedLoadRejection,
    messageContains parts: [String],
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    do {
        _ = try loadMutationPlan(url: url)
        Issue.record("expected load rejection (\(parts))", sourceLocation: sourceLocation)
    } catch let error as PlanLoadError {
        #expect(
            classify(error) == expected,
            "wrong rejection class: \(error)",
            sourceLocation: sourceLocation
        )
        for part in parts {
            #expect(
                error.description.contains(part),
                "message \(error.description) lacks \(part)",
                sourceLocation: sourceLocation
            )
        }
    } catch {
        Issue.record("expected PlanLoadError, got \(error)", sourceLocation: sourceLocation)
    }
}
