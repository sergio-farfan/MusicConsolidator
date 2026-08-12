# Xcode project setup — AppleMusicConsolidator (M6b)

Author: Sergio Farfan
Environment: Xcode 26.6 on macOS 26 (Tahoe), Apple Silicon.

This guide creates the Xcode app project around the prepared sources in
`macos-app/App/` and walks through signing, the Automation grant, the first
live read-only read of `Trance 2022` (all same-name copies), the cross-check
against the Python CLI, and the live descriptor-fidelity re-verification.

Everything in this milestone is READ-ONLY against Music. The app has no
write or apply path.

## 0. Preconditions

- The self-signed certificate **"Sergio Farfan Code Signing"** exists in the
  login keychain (Keychain Access > Certificate Assistant; Certificate Type:
  Code Signing; trust set to Always Trust for Code Signing).
- The prepared files exist (nothing in `ConsolidatorKit/` was changed):
  - `macos-app/App/AppleMusicConsolidatorApp.swift`
  - `macos-app/App/ContentView.swift`
  - `macos-app/App/Authorization.swift`
  - `macos-app/App/AppleMusicConsolidator.entitlements`
- Package sanity (optional, from `macos-app/ConsolidatorKit`):
  `swift test` → 248 tests pass.
- This directory tree is **not** a Git repository and must stay that way.

## 1. Create the project

1. Open Xcode 26.6 → **File > New > Project…** (Shift-Cmd-N).
2. Choose the **macOS** tab → **App** (under Application) → **Next**.
3. Options page — set exactly:
   - Product Name: `AppleMusicConsolidator`
   - Team: `None`
   - Organization Identifier: `com.sergiofarfan`
     (the Bundle Identifier preview must read
     `com.sergiofarfan.AppleMusicConsolidator`)
   - Interface: `SwiftUI`
   - Language: `Swift`
   - Testing System: `None`
   - Storage: `None`
4. **Next** → in the save sheet navigate to
   `<repo>/macos-app`
   and **UNCHECK "Create Git repository on my Mac"** → **Create**.

Xcode creates `macos-app/AppleMusicConsolidator/` containing
`AppleMusicConsolidator.xcodeproj` and a nested `AppleMusicConsolidator/`
folder with template files (`AppleMusicConsolidatorApp.swift`,
`ContentView.swift`, `Assets.xcassets`,
`AppleMusicConsolidator.entitlements`).

## 2. Replace the template sources with the prepared files

The prepared files stay in `macos-app/App/` as the single source of truth;
they are added **by reference**, and the template duplicates are deleted.

1. In the Project navigator, Cmd-click the two template files
   `AppleMusicConsolidatorApp.swift` and `ContentView.swift` → right-click →
   **Delete** → choose **Move to Trash** (not "Remove Reference").
   Keep `Assets.xcassets`. Leave the template
   `AppleMusicConsolidator.entitlements` alone for now (it is handled in
   step 4, after the App Sandbox capability is removed).
2. **File > Add Files to "AppleMusicConsolidator"…** → navigate to
   `macos-app/App` → Cmd-click to select all four files:
   `AppleMusicConsolidatorApp.swift`, `ContentView.swift`,
   `Authorization.swift`, `AppleMusicConsolidator.entitlements`.
3. In the sheet's options (click **Options** at the bottom left if they are
   collapsed):
   - Action: **Reference files in place** (NOT "Copy files to destination")
   - Groups: Create groups
   - Add to targets: **AppleMusicConsolidator** checked
   → **Add**.
4. Select the newly added `AppleMusicConsolidator.entitlements` (the one
   under `App/`) in the navigator → open the File inspector (right panel) →
   under **Target Membership**, UNCHECK `AppleMusicConsolidator` if it is
   checked. Entitlements are consumed through a build setting (step 4), not
   bundled as a resource. The three `.swift` files must keep their target
   membership checked.

## 3. Bundle identifier and deployment target

1. Select the project (blue icon) in the navigator → target
   **AppleMusicConsolidator** → **General** tab.
2. Identity → Bundle Identifier: verify it is exactly
   `com.sergiofarfan.AppleMusicConsolidator`.
3. Minimum Deployments → macOS: **14.0**.

## 4. Signing & Capabilities

Open the **Signing & Capabilities** tab of the target.

1. **UNCHECK "Automatically manage signing"** → confirm
   **Disable Automatic** in the dialog. The section splits into
   Signing (Debug) and Signing (Release).
2. For **both** Debug and Release:
   - Provisioning Profile: `None`
   - Signing Certificate: open the popup → **Other…** → type exactly
     `Sergio Farfan Code Signing` → confirm.
3. **Remove App Sandbox**: the template adds an **App Sandbox** capability
   card. Click the trash (x) icon in the card's top-right corner. This also
   removes `com.apple.security.app-sandbox` (and the template's
   file-access key) from the template entitlements file. The app must NOT
   be sandboxed: a sandboxed app cannot send Apple events to Music without
   per-app temporary exceptions.
4. **Do NOT enable Hardened Runtime.** If a Hardened Runtime card is
   present, remove it with its trash icon too (self-signed local
   development; hardened runtime is a notarized-distribution concern).
5. Now delete the template entitlements file: in the Project navigator,
   right-click the template `AppleMusicConsolidator.entitlements` (the one
   inside `AppleMusicConsolidator/AppleMusicConsolidator/`, NOT the one
   under `App/`) → **Delete** → **Move to Trash**.
6. Point the build at the prepared entitlements: **Build Settings** tab →
   filter buttons **All** + **Combined** → search `entitlements` → row
   **Code Signing Entitlements** (`CODE_SIGN_ENTITLEMENTS`) → double-click
   the target-level value → set it to:

   ```
   ../App/AppleMusicConsolidator.entitlements
   ```

   (relative to `$(SRCROOT)` = `macos-app/AppleMusicConsolidator`, this
   resolves to `macos-app/App/AppleMusicConsolidator.entitlements`).
7. While in Build Settings, search `hardened` and verify
   **Enable Hardened Runtime** is `No` (or not set to Yes).

The prepared entitlements file contains exactly one key —
`com.apple.security.automation.apple-events` = `true` — and no sandbox key.

## 5. Info tab — Apple-events usage description

1. Target → **Info** tab → "Custom macOS Application Target Properties".
2. Hover any row → click **+** → type the raw key
   `NSAppleEventsUsageDescription` (Xcode may display it as
   "Privacy - AppleEvents Sending Usage Description" — same key) →
   Type `String` → paste this exact value:

   ```
   Apple Music Consolidator needs to control Music to read playlists and (in a later step, only after your explicit approval) create new consolidated playlists. Source playlists are never modified.
   ```

Without this key macOS kills the Apple-event send instead of prompting.

## 6. Add the local package and link the libraries

1. **File > Add Package Dependencies…** → click **Add Local…**
   (bottom-left) → navigate to
   `<repo>/macos-app/ConsolidatorKit`
   (the folder that directly contains `Package.swift`) → **Add Package**.
2. In the "Choose Package Products" sheet, set BOTH products to the app
   target:
   - `MusicBridge` → Add to Target: `AppleMusicConsolidator`
   - `ConsolidatorCore` → Add to Target: `AppleMusicConsolidator`
   → **Add Package**. The app imports both modules, so both must be linked.
3. If the sheet did not appear or a product was left at "None": target →
   **General** → "Frameworks, Libraries, and Embedded Content" → **+** →
   select `MusicBridge` and `ConsolidatorCore` under the local package →
   **Add**.
4. Do NOT edit anything under `ConsolidatorKit/Sources` from Xcode — the
   package is review-frozen for this milestone.

## 7. Build & Run and the first-run sequence

Running from Xcode executes the app in the normal GUI session, which gives
the TCC prompt the correct attribution (the known -1701 failure mode only
occurs for senders outside the GUI/TCC session — see the appendix).

1. **Open Music first**: launch Music manually (Applications > Music, or
   `open -a Music` in Terminal) and let it finish loading the library.
2. In Xcode select the `AppleMusicConsolidator` scheme / My Mac → **Cmd-B**
   (should build with zero errors) → **Cmd-R**.
3. In the app window click **Preflight Automation**. Expect the macOS
   consent dialog — `"AppleMusicConsolidator" wants access to control
   "Music"` — showing the usage-description sentence from step 5.
   Click **Allow**.
4. The status line must now read:
   `Granted — this app may send Apple events to Music.`
   - `Music is not running (-600 …)` → open Music, preflight again.
   - `Denied (-1743 …)` → see the appendix (re-enable or `tccutil reset`).

## 8. First live read (read-only) and raw-wire export

1. Keep the default playlist name `Trance 2022` → click
   **Read all copies (read-only)**. The buttons stay disabled while the
   read runs (single-flight); a large library can take a while on the
   first read. Nothing is written to Music.
2. Verify the display: one card per same-name copy, in ascending
   playlist-id order, each showing playlist id, persistent ID, name (plus a
   `U+XXXX` scalar rendering when the name contains non-ASCII), track
   count, and first/last track title + persistent ID; plus a total elapsed
   line (runner execution + parse).
3. Click **Export raw wire JSON…** → save as, e.g.,
   `~/Desktop/trance-2022-app-raw.json`. This file is byte-for-byte the
   UTF-8 encoding of the exact pre-parse string `OSAKitRunner` returned —
   no trailing newline, nothing re-serialized. It is the artifact for the
   fidelity diff in step 10.

## 9. Cross-check against the Python CLI

> **Status (2026-08-11): sections 9 and 10 are now the PRIMARY Swift↔Python
> read-parity gate.** They used to be a belt-and-braces live confirmation of a
> parity already proven offline: the Swift read builder emitted byte-identical
> script text to the Python reference's, pinned case-by-case in
> `ScriptGoldenTests`. That is no longer true. The Swift read scripts went
> COLUMNAR on 2026-08-11 (Sergio's decision, for performance), so
> `buildReadJXA`'s text deliberately diverges from `build_read_jxa`'s, and the
> `read_jxa` golden byte-parity case now covers only the RETAINED pre-columnar
> `legacyReadJXAScript` — not the reader the app actually uses. Two different
> scripts must now be shown to return the same WIRE JSON, and these two
> sections are where that is established against real library data. Treat a
> divergence here as blocking, not informational, and re-run them after any
> change to a read script.

Run in your normal Terminal (project root; read-only against Music — it
writes only new report artifacts):

```bash
cd <repo>
python3 scripts/apple_music_consolidate.py merge-audit --name 'Trance 2022' --output-dir reports
```

Then compare the freshly created `.plan.json` against the app's display
(plan `copies` are in the same ascending playlist-id order as the app):

```bash
cd <repo>
python3 - reports/<the-new-file>.plan.json <<'EOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    plan = json.load(handle)
for position, copy in enumerate(plan["copies"], 1):
    tracks = copy["tracks"]
    print(f"copy {position}: pid={copy['persistent_id']} "
          f"name={copy['name']!r} tracks={len(tracks)}")
    if tracks:
        first, last = tracks[0], tracks[-1]
        print(f"  first: {first['title']} — {first['persistent_id']}")
        print(f"  last:  {last['title']} — {last['persistent_id']}")
EOF
```

Must match the app card-for-card: copy count and order, per-copy persistent
ID, name, track count, first/last title + persistent ID. Run the app read
and the CLI audit back-to-back without touching Music in between; any
mismatch means the library changed between reads (re-run both) or a real
divergence (stop and investigate before M7).

## 10. Live descriptor-fidelity re-verification (R3 gate item)

This re-verifies, against real Music-sourced text, that the in-process
OSAKit descriptor decode is scalar-identical to `osascript` output (the
M6a finding: `NSAppleEventDescriptor.stringValue` strips a leading U+FEFF;
the runner decodes raw UTF-16 instead). Since 2026-08-11 it carries a second,
now-primary job: it is the wire-level Swift↔Python READ parity gate (see the
status note in section 9), because the two read scripts are no longer the same
text.

1. Produce the osascript raw output separately, with the REFERENCE's own read
   script. Note what this step compares as of 2026-08-11: the reference's read
   script is NOT the same text as the Swift app's any more. `build_read_jxa`
   is the pre-columnar per-track form; the app's `buildReadJXA` fetches each
   track property as one whole-column Apple Event. The divergence is
   deliberate (a Swift-only performance change the Python CLI has no need for),
   which is exactly why this diff matters: two DIFFERENT scripts must return
   scalar-identical wire JSON for the same library, and that is the property
   being tested here — not a same-text port, as this step used to claim. Run
   back-to-back with the app read from step 8; do not touch Music or quit
   it in between (playlist `id` values are stable within a Music session,
   not across relaunches):

   ```bash
   cd <repo>
   python3 -c "from apple_music_consolidator.music_bridge import build_read_jxa; import sys; sys.stdout.write(build_read_jxa('Trance 2022'))" > /tmp/trance-read.jxa
   osascript -l JavaScript /tmp/trance-read.jxa > /tmp/trance-osascript-raw.json
   ```

   (If Terminal has never automated Music, this triggers Terminal's own
   Automation prompt — allow it; it is the same grant your normal audits
   use.)

2. Scalar-diff the two artifacts (Python `==` over `str` is code-point
   exact). The only sanctioned difference is the single trailing newline
   `osascript` appends to stdout, which the in-process runner does not:

   ```bash
   python3 - /tmp/trance-osascript-raw.json "$HOME/Desktop/trance-2022-app-raw.json" <<'EOF'
   import sys
   with open(sys.argv[1], encoding="utf-8") as handle:
       cli_text = handle.read()
   with open(sys.argv[2], encoding="utf-8") as handle:
       app_text = handle.read()
   # osascript appends exactly one trailing newline; the in-process runner
   # returns the script result without it.
   if cli_text.endswith("\n"):
       cli_text = cli_text[:-1]
   if cli_text == app_text:
       print(f"scalar-identical: {len(app_text)} code points")
   else:
       print(f"DIFFERS: cli={len(cli_text)} app={len(app_text)} code points")
       for index, (left, right) in enumerate(zip(cli_text, app_text)):
           if left != right:
               print(f"first divergence at index {index}: "
                     f"cli U+{ord(left):04X} app U+{ord(right):04X}")
               break
       else:
           shorter = min(len(cli_text), len(app_text))
           print(f"one is a prefix of the other; extra content starts at index {shorter}")
   EOF
   ```

3. Expected: `scalar-identical: <N> code points`.
   - A divergence in track data usually means Music changed between the two
     reads — re-run both back-to-back and diff again.
   - A **leading U+FEFF** (or any invisible-scalar) divergence is the R3
     descriptor-fidelity signature: record it in the M6b report and stop
     before M7.

## Appendix — troubleshooting

### Reset the Automation decision (clean re-prompt)

```bash
tccutil reset AppleEvents com.sergiofarfan.AppleMusicConsolidator
```

Forgets only this app's Apple-events decisions; the next Preflight click
re-prompts. (Do not run the bare `tccutil reset AppleEvents` — it resets
every app's automation grants.)

### Error numbers

- **-1743** (`errAEEventNotPermitted`): the user or a policy denied
  automation of Music. Re-enable under System Settings > Privacy &
  Security > Automation > AppleMusicConsolidator > Music, or `tccutil
  reset` (above) and answer the fresh prompt.
- **-1744** (`errAEEventWouldRequireUserConsent`): consent not determined
  and the prompt was not shown — typically a non-GUI launch context.
  Launch from Xcode or Finder in the logged-in session.
- **-600** (`procNotFound`): Music is not running. Open Music first; the
  preflight requires the target app to be running.
- **-1701** (`errAEDescNotFound`): in this project, the signature of an
  Apple-event sender with no usable GUI/TCC session — the known
  automation-runner failure recorded in AGENTS.md (`hiservices -1701`).
  Never launch the app via ssh or background runners; use Xcode/Finder.

### Signature and entitlements check

```bash
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/AppleMusicConsolidator-*/Build/Products/Debug/AppleMusicConsolidator.app | head -1)
codesign -dv --entitlements - "$APP"
codesign --verify --strict --verbose=2 "$APP"
```

Expect in the output:

- `Identifier=com.sergiofarfan.AppleMusicConsolidator`
- `Authority=Sergio Farfan Code Signing`
- CodeDirectory `flags` WITHOUT `runtime` (hardened runtime off)
- entitlements containing exactly one key:
  `com.apple.security.automation.apple-events` → `true`
  and NO `com.apple.security.app-sandbox`
- `--verify` reports the bundle valid on disk.

Usage-description check in the built app:

```bash
plutil -p "$APP/Contents/Info.plist" | grep -i appleevents
```

### Stable identity (why the grant survives rebuilds)

The TCC Automation grant is keyed to the app's code-signing identity plus
bundle identifier. Rebuilds re-signed with the same "Sergio Farfan Code
Signing" certificate and the same bundle id keep the grant. Regenerating
the certificate or changing the bundle id invalidates it (silent -1743) —
`tccutil reset` and re-grant. This is exactly why automatic ("Sign to Run
Locally" / ad-hoc) signing is not used: ad-hoc signatures change per build
and the grant would not stick.

### Prompt never appears

Check, in order: Music is running; `NSAppleEventsUsageDescription` is
present in the built `Info.plist` (command above); a previous decision is
recorded (System Settings > Privacy & Security > Automation) — if so,
enable it there or `tccutil reset`; then rebuild and retry from Xcode.

### Build errors after setup

- `cannot find 'ContentView' in scope` / duplicate `@main`: a template file
  survived step 2, or an `App/` file is missing target membership — select
  each file and check Target Membership in the File inspector.
- `no such module 'MusicBridge'`: the package products were not linked —
  redo step 6.2/6.3.
- Entitlements build error: the `CODE_SIGN_ENTITLEMENTS` path from step 4.6
  must be exactly `../App/AppleMusicConsolidator.entitlements`.
