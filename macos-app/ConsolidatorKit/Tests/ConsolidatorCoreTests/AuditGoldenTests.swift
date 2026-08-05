// AuditGoldenTests.swift
// Golden-fixture parity for the M3 artifact renderers: assert Swift
// renderDetailCSV / renderSummaryMarkdown / renderPlanJSON (and the merge
// variants) match the Python reference implementation's write_csv / write_markdown / write_json
// output over the corpus exported by macos-app/golden/generate_audit_golden.py.
//
// Volatile parts (derived from audit.py):
// - detail CSV has none -> full byte-level parity is asserted, plus
//   column-set + row-by-row scalar comparison for diagnosable mismatches.
// - summary markdown embeds the fingerprint hex on the "- Fingerprint: `…`" /
//   "- Merge fingerprint: `…`" lines (Swift owns its own fingerprint bytes);
//   those values are normalized out, every other byte is pinned.
// - plan JSON is compared as decoded SHAPE (keys, values, structure) minus the
//   source_fingerprint / merge_fingerprint values — never byte-for-byte.

import Foundation
import Testing
@testable import ConsolidatorCore

private func goldenFileURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("golden")
        .appendingPathComponent(name)
}

private struct AuditGolden: Decodable {
    let writeAuditCases: [WriteAuditCase]
    let writeMergeAuditCases: [WriteMergeAuditCase]

    enum CodingKeys: String, CodingKey {
        case writeAuditCases = "write_audit_cases"
        case writeMergeAuditCases = "write_merge_audit_cases"
    }
}

private struct WriteAuditCase: Decodable {
    let name: String
    let source: PlaylistSnapshot
    let detailCsv: String
    let summaryMd: String

    enum CodingKeys: String, CodingKey {
        case name
        case source
        case detailCsv = "detail_csv"
        case summaryMd = "summary_md"
    }
}

private struct WriteMergeAuditCase: Decodable {
    let name: String
    let mergedName: String
    let copies: [PlaylistSnapshot]
    let detailCsv: String
    let summaryMd: String

    enum CodingKeys: String, CodingKey {
        case name
        case mergedName = "merged_name"
        case copies
        case detailCsv = "detail_csv"
        case summaryMd = "summary_md"
    }
}

private func loadGolden() throws -> AuditGolden {
    let data = try Data(contentsOf: goldenFileURL("audit_golden.json"))
    return try JSONDecoder().decode(AuditGolden.self, from: data)
}

/// The reference plan_json objects per case name, parsed with JSONSerialization
/// (shape comparison needs untyped values, including the Python fingerprint).
private func loadGoldenPlanObjects(
    listKey: String
) throws -> [String: [String: Any]] {
    let data = try Data(contentsOf: goldenFileURL("audit_golden.json"))
    let root = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let cases = try #require(root[listKey] as? [[String: Any]])
    var byName: [String: [String: Any]] = [:]
    for entry in cases {
        let name = try #require(entry["name"] as? String)
        byName[name] = try #require(entry["plan_json"] as? [String: Any])
    }
    return byName
}

// MARK: - Comparison helpers

/// Replace the volatile fingerprint hex on its dedicated summary lines.
/// Everything else in the markdown is pinned byte-for-byte.
private func normalizeFingerprintLines(_ markdown: String) -> String {
    markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        for prefix in ["- Fingerprint: `", "- Merge fingerprint: `"] {
            if line.hasPrefix(prefix) && line.hasSuffix("`") {
                return prefix + "<fingerprint>`"
            }
        }
        return String(line)
    }.joined(separator: "\n")
}

/// CSV parity: full text equality plus column-set + row-by-row cell
/// comparison with code-point rendering on the first mismatching cell.
private func expectCSVMatches(
    _ actual: String,
    _ expected: String,
    context: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    let actualRows = parseCSV(actual)
    let expectedRows = parseCSV(expected)
    guard let actualHeader = actualRows.first, let expectedHeader = expectedRows.first else {
        Issue.record("\(context): missing CSV header", sourceLocation: sourceLocation)
        return
    }
    #expect(
        actualHeader == expectedHeader,
        "\(context): CSV column set diverged\n  actual:   \(actualHeader)\n  expected: \(expectedHeader)",
        sourceLocation: sourceLocation
    )
    #expect(
        actualRows.count == expectedRows.count,
        "\(context): CSV row count \(actualRows.count - 1) vs \(expectedRows.count - 1)",
        sourceLocation: sourceLocation
    )
    for (rowIndex, (actualRow, expectedRow)) in zip(actualRows, expectedRows).enumerated() {
        if actualRow.count != expectedRow.count {
            Issue.record(
                "\(context): row \(rowIndex) has \(actualRow.count) cells, expected \(expectedRow.count)",
                sourceLocation: sourceLocation
            )
            continue
        }
        for (cellIndex, (actualCell, expectedCell)) in zip(actualRow, expectedRow).enumerated() {
            if !scalarEqual(actualCell, expectedCell) {
                Issue.record(
                    """
                    \(context): row \(rowIndex) column \(expectedHeader.indices.contains(cellIndex) ? expectedHeader[cellIndex] : "#\(cellIndex)") diverged from the reference
                      actual:   \(actualCell) [\(codePointRendering(actualCell))]
                      expected: \(expectedCell) [\(codePointRendering(expectedCell))]
                    """,
                    sourceLocation: sourceLocation
                )
            }
        }
    }
    // The CSV has no volatile parts, so byte-level parity must also hold
    // (quoting decisions, CRLF terminators, header bytes).
    #expect(
        scalarEqual(actual, expected),
        "\(context): CSV byte-level parity failed despite cell-level match",
        sourceLocation: sourceLocation
    )
}

/// Markdown parity after fingerprint normalization, with per-line code-point
/// diagnostics on mismatch.
private func expectMarkdownMatches(
    _ actual: String,
    _ expected: String,
    context: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    let actualNorm = normalizeFingerprintLines(actual)
    let expectedNorm = normalizeFingerprintLines(expected)
    if scalarEqual(actualNorm, expectedNorm) { return }
    let actualLines = actualNorm.split(separator: "\n", omittingEmptySubsequences: false)
    let expectedLines = expectedNorm.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(
        actualLines.count == expectedLines.count,
        "\(context): markdown line count \(actualLines.count) vs \(expectedLines.count)",
        sourceLocation: sourceLocation
    )
    for (index, (actualLine, expectedLine)) in zip(actualLines, expectedLines).enumerated()
    where !scalarEqual(String(actualLine), String(expectedLine)) {
        Issue.record(
            """
            \(context): markdown line \(index) diverged from the reference
              actual:   \(actualLine) [\(codePointRendering(String(actualLine)))]
              expected: \(expectedLine) [\(codePointRendering(String(expectedLine)))]
            """,
            sourceLocation: sourceLocation
        )
    }
}

/// Recursive JSON shape comparison. NSNumber booleans are distinguished from
/// integers (JSON true != 1); strings compare at scalar level; the values of
/// `ignoredTopLevelKeys` are skipped (they must still be present — checked via
/// the key-set comparison — and must be 64-char hex strings on both sides).
private func jsonShapeProblems(
    actual: Any,
    expected: Any,
    path: String,
    problems: inout [String]
) {
    if let actualDict = actual as? [String: Any] {
        guard let expectedDict = expected as? [String: Any] else {
            problems.append("\(path): object vs \(type(of: expected))")
            return
        }
        let actualKeys = Set(actualDict.keys)
        let expectedKeys = Set(expectedDict.keys)
        if actualKeys != expectedKeys {
            problems.append(
                "\(path): key set diverged, extra \(actualKeys.subtracting(expectedKeys).sorted()), "
                    + "missing \(expectedKeys.subtracting(actualKeys).sorted())"
            )
            return
        }
        for key in actualKeys.sorted() {
            jsonShapeProblems(
                actual: actualDict[key]!,
                expected: expectedDict[key]!,
                path: "\(path).\(key)",
                problems: &problems
            )
        }
        return
    }
    if let actualArray = actual as? [Any] {
        guard let expectedArray = expected as? [Any] else {
            problems.append("\(path): array vs \(type(of: expected))")
            return
        }
        if actualArray.count != expectedArray.count {
            problems.append("\(path): array count \(actualArray.count) vs \(expectedArray.count)")
            return
        }
        for (index, (actualItem, expectedItem)) in zip(actualArray, expectedArray).enumerated() {
            jsonShapeProblems(
                actual: actualItem,
                expected: expectedItem,
                path: "\(path)[\(index)]",
                problems: &problems
            )
        }
        return
    }
    if actual is NSNull {
        if !(expected is NSNull) { problems.append("\(path): null vs \(expected)") }
        return
    }
    if let actualNumber = actual as? NSNumber, !(actual is String) {
        guard let expectedNumber = expected as? NSNumber, !(expected is String) else {
            problems.append("\(path): number vs \(type(of: expected))")
            return
        }
        let actualIsBool = isJSONBoolean(actualNumber)
        let expectedIsBool = isJSONBoolean(expectedNumber)
        if actualIsBool != expectedIsBool {
            problems.append("\(path): boolean-ness diverged (\(actualNumber) vs \(expectedNumber))")
            return
        }
        if !actualNumber.isEqual(to: expectedNumber) {
            problems.append("\(path): \(actualNumber) vs \(expectedNumber)")
        }
        return
    }
    if let actualString = actual as? String {
        guard let expectedString = expected as? String else {
            problems.append("\(path): string vs \(type(of: expected))")
            return
        }
        if !scalarEqual(actualString, expectedString) {
            problems.append(
                "\(path): \(actualString) [\(codePointRendering(actualString))] vs "
                    + "\(expectedString) [\(codePointRendering(expectedString))]"
            )
        }
        return
    }
    problems.append("\(path): unsupported JSON value \(type(of: actual))")
}

private func expectPlanJSONShapeMatches(
    renderedText: String,
    goldenObject: [String: Any],
    fingerprintKey: String,
    context: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) throws {
    #expect(renderedText.hasSuffix("\n"), "\(context): plan JSON must end with a newline", sourceLocation: sourceLocation)
    let actualObject = try #require(
        try JSONSerialization.jsonObject(with: Data(renderedText.utf8)) as? [String: Any],
        sourceLocation: sourceLocation
    )
    // Both sides must carry the fingerprint key as a 64-char lowercase hex
    // string; the VALUE is side-specific by design and excluded from shape.
    for (label, object) in [("swift", actualObject), ("reference", goldenObject)] {
        let value = object[fingerprintKey] as? String ?? ""
        #expect(
            value.count == 64 && value.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) },
            "\(context): \(label) \(fingerprintKey) is not 64-char hex: \(value)",
            sourceLocation: sourceLocation
        )
    }
    var actualComparable = actualObject
    var expectedComparable = goldenObject
    actualComparable[fingerprintKey] = "<fingerprint>"
    expectedComparable[fingerprintKey] = "<fingerprint>"
    var problems: [String] = []
    jsonShapeProblems(actual: actualComparable, expected: expectedComparable, path: "plan", problems: &problems)
    for problem in problems {
        Issue.record("\(context): plan JSON shape diverged — \(problem)", sourceLocation: sourceLocation)
    }
}

// MARK: - Suites

@Suite("Audit artifact golden parity (write_csv/write_markdown/write_json)")
struct WriteAuditGoldenTests {

    @Test("renderers match the Python reference implementation for every write_audit golden case")
    func writeAuditRenderersMatchGolden() throws {
        let cases = try loadGolden().writeAuditCases
        let planObjects = try loadGoldenPlanObjects(listKey: "write_audit_cases")
        #expect(!cases.isEmpty)
        for goldenCase in cases {
            let plan = try buildPlan(goldenCase.source)
            expectCSVMatches(
                renderDetailCSV(plan),
                goldenCase.detailCsv,
                context: "\(goldenCase.name): detail_csv"
            )
            expectMarkdownMatches(
                renderSummaryMarkdown(plan),
                goldenCase.summaryMd,
                context: "\(goldenCase.name): summary_md"
            )
            try expectPlanJSONShapeMatches(
                renderedText: renderPlanJSON(plan),
                goldenObject: try #require(planObjects[goldenCase.name]),
                fingerprintKey: "source_fingerprint",
                context: goldenCase.name
            )
        }
    }
}

@Suite("Merge audit artifact golden parity (write_merge_csv/write_merge_markdown/write_merge_json)")
struct WriteMergeAuditGoldenTests {

    @Test("merge renderers match the Python reference implementation for every write_merge_audit golden case")
    func writeMergeAuditRenderersMatchGolden() throws {
        let cases = try loadGolden().writeMergeAuditCases
        let planObjects = try loadGoldenPlanObjects(listKey: "write_merge_audit_cases")
        #expect(!cases.isEmpty)
        for goldenCase in cases {
            let plan = try buildMergePlan(name: goldenCase.mergedName, copies: goldenCase.copies)
            expectCSVMatches(
                renderMergeDetailCSV(plan),
                goldenCase.detailCsv,
                context: "\(goldenCase.name): detail_csv"
            )
            expectMarkdownMatches(
                renderMergeSummaryMarkdown(plan),
                goldenCase.summaryMd,
                context: "\(goldenCase.name): summary_md"
            )
            try expectPlanJSONShapeMatches(
                renderedText: renderMergePlanJSON(plan),
                goldenObject: try #require(planObjects[goldenCase.name]),
                fingerprintKey: "merge_fingerprint",
                context: goldenCase.name
            )
        }
    }
}
