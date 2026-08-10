// AppearancePresentation.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// UI rework Part 2 — the Settings "Appearance" preference's pure value
// layer: the three modes the user can pick and their mapping onto
// NSAppearance. No Music, no I/O — headlessly testable, the same posture
// as DestinationPresentation.swift's value layer beneath the destination
// shell. The persisted choice lives on AuditFlowModel; this file holds
// what the model and the view share.

import AppKit

/// The three appearance choices exposed in Settings.
nonisolated enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Maps a mode onto the `NSAppearance` to assign to `NSApp.appearance`.
/// This is the documented AppKit pattern (NSApplication/NSWindow/NSView all
/// conform to `NSAppearanceCustomization`): assigning
/// `NSAppearance(named: .darkAqua)` forces dark, `NSAppearance(named: .aqua)`
/// forces light, and assigning `nil` resets the app to follow the system
/// appearance.
nonisolated func nsAppearance(for mode: AppearanceMode) -> NSAppearance? {
    switch mode {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
}
