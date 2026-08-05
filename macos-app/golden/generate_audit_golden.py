#!/usr/bin/env python3
"""Export audit ARTIFACT goldens from the Python reference implementation for the Swift M3
persistence gate: the rendered `.detail.csv` text, the rendered `.summary.md`
text, and the plan JSON as a parsed object (shape comparison; fingerprints are
Swift-owned and never compared byte-for-byte).

Run from the project root so `apple_music_consolidator` is importable:

    python3 macos-app/golden/generate_audit_golden.py

Writes macos-app/golden/audit_golden.json. Byte-reproducible: every input is a
static literal (or the checked-in tests/fixtures/music_snapshot.json) and the
CSV/markdown/JSON renderers are pure functions of the plan (timestamps and
paths appear only in artifact FILE NAMES, never in artifact content).

The case corpus is reused verbatim from generate_plan_golden.py
(BUILD_PLAN_SOURCES / BUILD_MERGE_PLAN_SOURCES). Importing that module also
re-exports plan_golden.json as a side effect; that export is byte-reproducible
(verified in M2), so the rewrite is a no-op byte-wise.

Schema:
    {
      "write_audit_cases": [
        {"name", "source": <PlaylistSnapshot.to_dict()>,
         "detail_csv": <write_csv output text>,
         "summary_md": <write_markdown output text>,
         "plan_json": <ConsolidationPlan.to_dict()>}
      ],
      "write_merge_audit_cases": [
        {"name", "merged_name", "copies": [<PlaylistSnapshot.to_dict()>],
         "detail_csv": <write_merge_csv output text>,
         "summary_md": <write_merge_markdown output text>,
         "plan_json": <MergePlan.to_dict()>}
      ]
    }

Volatility notes for the Swift comparison side (derived from audit.py):
- detail_csv contains NO volatile parts -> full byte-level parity expected.
- summary_md contains the fingerprint hex on the "- Fingerprint: `...`" /
  "- Merge fingerprint: `...`" lines (Python SHA-256 here; Swift computes its
  own canonical fingerprint) -> those values must be normalized out; every
  other byte is pinned.
- plan_json is compared as decoded shape minus the source_fingerprint /
  merge_fingerprint values.
"""

import io
import json
import sys
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = OUT_DIR.parents[1]  # macos-app/golden -> macos-app -> project root
for entry in (str(PROJECT_ROOT), str(OUT_DIR)):
    if entry not in sys.path:
        sys.path.insert(0, entry)

import generate_plan_golden as plan_corpus  # noqa: E402  (reuses the M2 cases)

from apple_music_consolidator.audit import (  # noqa: E402
    write_csv,
    write_markdown,
    write_merge_csv,
    write_merge_markdown,
)
from apple_music_consolidator.resolver import build_merge_plan, build_plan  # noqa: E402


def rendered(writer, plan) -> str:
    buffer = io.StringIO()
    writer(buffer, plan)
    return buffer.getvalue()


write_audit_cases = []
for name, source in plan_corpus.BUILD_PLAN_SOURCES:
    plan = build_plan(source)
    write_audit_cases.append(
        {
            "name": name,
            "source": source.to_dict(),
            "detail_csv": rendered(write_csv, plan),
            "summary_md": rendered(write_markdown, plan),
            "plan_json": plan.to_dict(),
        }
    )

write_merge_audit_cases = []
for name, merged_name, copies in plan_corpus.BUILD_MERGE_PLAN_SOURCES:
    plan = build_merge_plan(merged_name, copies)
    write_merge_audit_cases.append(
        {
            "name": name,
            "merged_name": merged_name,
            "copies": [copy.to_dict() for copy in copies],
            "detail_csv": rendered(write_merge_csv, plan),
            "summary_md": rendered(write_merge_markdown, plan),
            "plan_json": plan.to_dict(),
        }
    )

payload = {
    "write_audit_cases": write_audit_cases,
    "write_merge_audit_cases": write_merge_audit_cases,
}
out_path = OUT_DIR / "audit_golden.json"
out_path.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
print(
    f"wrote {len(write_audit_cases)} write_audit cases and "
    f"{len(write_merge_audit_cases)} write_merge_audit cases -> {out_path}"
)
