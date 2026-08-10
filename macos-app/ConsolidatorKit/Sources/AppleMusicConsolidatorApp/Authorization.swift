// Authorization.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Apple-events automation preflight against com.apple.Music via
// AEDeterminePermissionToAutomateTarget (AE framework, part of
// CoreServices; `import ApplicationServices` re-exports it). The target is
// a typeApplicationBundleID address descriptor —
// NSAppleEventDescriptor(bundleIdentifier:) constructs exactly that — and
// the permission is checked for the wildcard event class/ID so the result
// reflects the app's Automation grant for Music as a whole.
//
// The call BLOCKS while the TCC consent prompt is on screen when
// askUserIfNeeded is true, so it must run OFF the main actor (ContentView
// dispatches it in a detached task).
//
// This file makes no read and no write against Music: determining
// permission is a TCC query, not an Apple event to Music's scripting
// interface (Music must be running for TCC to resolve the target, hence
// the explicit procNotFound mapping with launch guidance).

import Foundation
import ApplicationServices

/// Outcome of the automation preflight, mapped to operator-readable text.
nonisolated enum AutomationPreflightResult: Sendable, Equatable {
    case granted
    case denied
    case consentNotDetermined
    case musicNotRunning
    case descriptorUnavailable
    case unexpected(OSStatus)

    var displayText: String {
        switch self {
        case .granted:
            return "Granted — this app may send Apple events to Music."
        case .denied:
            return "Denied (-1743, errAEEventNotPermitted). Enable it under "
                + "System Settings > Privacy & Security > Automation > "
                + "AppleMusicConsolidator > Music, or reset the decision with: "
                + "tccutil reset AppleEvents com.sergiofarfan.AppleMusicConsolidator"
        case .consentNotDetermined:
            return "Consent required (-1744, errAEEventWouldRequireUserConsent) — "
                + "the consent prompt was not shown. Launch the app in your normal "
                + "GUI session (from Xcode or Finder) with Music running, then try again."
        case .musicNotRunning:
            return "Music is not running (-600, procNotFound). Open Music first "
                + "(Applications > Music, or run: open -a Music), then run the "
                + "preflight again."
        case .descriptorUnavailable:
            return "Could not build the Apple-event address descriptor for com.apple.Music."
        case .unexpected(let status):
            return "Unexpected AEDeterminePermissionToAutomateTarget status: \(status)."
        }
    }
}

nonisolated enum AutomationPreflight {
    static let musicBundleIdentifier = "com.apple.Music"

    /// Ask TCC whether this app may automate Music, showing the consent
    /// prompt if the decision has not been made yet. Blocking — call off
    /// the main actor.
    static func determineMusicAutomationPermission(askUserIfNeeded: Bool) -> AutomationPreflightResult {
        // typeApplicationBundleID target descriptor for Music.
        let target = NSAppleEventDescriptor(bundleIdentifier: musicBundleIdentifier)
        guard let targetPointer = target.aeDesc else {
            return .descriptorUnavailable
        }
        let status = AEDeterminePermissionToAutomateTarget(
            targetPointer,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
        // Codes are matched numerically; the values are the documented AE
        // constants (named in comments) so this file does not depend on
        // which legacy MacErrors constants the importer surfaces.
        switch status {
        case 0: // noErr
            return .granted
        case -1743: // errAEEventNotPermitted — the user (or MDM policy) denied
            return .denied
        case -1744: // errAEEventWouldRequireUserConsent — undetermined, prompt not shown
            return .consentNotDetermined
        case -600: // procNotFound — the target application is not running
            return .musicNotRunning
        default:
            return .unexpected(status)
        }
    }
}
