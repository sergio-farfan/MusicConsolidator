# macos-app/App — where the app sources live now

Author: Sergio Farfan

The three app Swift sources moved on 2026-08-01 (M6b script-assembled
bundle decision). Their canonical location is now the SwiftPM executable
target:

```
macos-app/ConsolidatorKit/Sources/AppleMusicConsolidatorApp/
    AppleMusicConsolidatorApp.swift
    ContentView.swift
    Authorization.swift
```

SwiftPM requires target sources under the package's `Sources/` directory,
so the files were MOVED (not copied — there is exactly one copy; do not
recreate them here). They build as the `AppleMusicConsolidatorApp`
executable product, depending on `MusicBridge` and `ConsolidatorCore`.

Still canonical in this directory:

- `AppleMusicConsolidator.entitlements` — consumed by
  `macos-app/scripts/build-app.sh` at codesign time (and by the deferred
  Xcode path via `CODE_SIGN_ENTITLEMENTS`).
- `XCODE-SETUP.md` — the Xcode-project route (deferred to M7 if wanted);
  its first-run sequence (steps 7–10: Automation grant, live read,
  CLI cross-check, fidelity diff) and troubleshooting appendix still apply
  verbatim to the script-assembled bundle.

Build, assemble, and sign the bundle with:

```bash
<repo>/macos-app/scripts/build-app.sh
```

Output: `macos-app/build/AppleMusicConsolidator.app`.
