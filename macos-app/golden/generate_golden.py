#!/usr/bin/env python3
"""Export golden fixtures from the Python reference implementation (apple_music_consolidator.normalize).

Run from the project root so `apple_music_consolidator` is importable:

    python3 macos-app/golden/generate_golden.py

Writes macos-app/golden/normalize.json and macos-app/golden/duration.json.
The Swift ConsolidatorCoreTests golden tests load these two files and assert
parity between the Swift port and this Python reference implementation.
"""

import json
import sys
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = OUT_DIR.parents[1]  # macos-app/golden -> macos-app -> project root
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from apple_music_consolidator.normalize import duration_to_ms, normalize_text  # noqa: E402

# ---------------------------------------------------------------------------
# normalize_text corpus
# ---------------------------------------------------------------------------
NORMALIZE_INPUTS = [
    # plain ASCII
    "Hello World",
    "Rock Song",
    "already lower case",
    "ALREADY UPPER CASE",
    # accented text must be PRESERVED (not stripped), only case-folded
    "Björk",
    "Café Müller",
    "Naïve Résumé",
    "Amélie",
    "Malmö",
    # German ß: casefold("ß") == "ss" (full case folding, not simple lowercase)
    "Straße",
    "GROßE",
    "ẞ",  # capital sharp s U+1E9E -> casefold -> "ss"
    "Weiß nicht",
    # ligatures: NFKC expands compatibility ligatures before casefold
    "ﬀice",  # U+FB00 LATIN SMALL LIGATURE FF + "ice" -> "ffice"
    "ﬁlm",  # U+FB01 LATIN SMALL LIGATURE FI + "lm" -> "film"
    "ﬂower",  # U+FB02 LATIN SMALL LIGATURE FL + "ower" -> "flower"
    "Soufflé",
    # curly single/double quotes -> straight
    "Rock’n Roll",  # ’
    "‘Quoted’",  # ‘ ... ’
    "“Björk” — Song",  # “Björk” — Song
    "“Björk”",  # “Björk”
    "It’s a “test”",
    # en/em dashes -> hyphen
    "Rock–Song",  # –
    "Rock—Song",  # —
    "  Björk—Song  ",
    "Bjork—Song",
    "A–B—C",
    # runs of mixed whitespace/tabs/newlines collapse to a single space, trimmed
    "  leading and trailing  ",
    "tabs\tand\tmore\ttabs",
    "line\nbreaks\n\nhere",
    "mixed \t \n whitespace   runs",
    "\n\t  \n",  # all-whitespace -> empty string after strip
    "",  # empty string stays empty
    # full-width forms: NFKC folds to normal-width ASCII
    "Ａｂｃ１２３",  # Ａｂｃ１２３ -> Abc123
    "ＡＬＬ ＣＡＰＳ",  # ＡＬＬ ＣＡＰＳ
    # mixed-case casefold
    "MiXeD CaSe TeXt",
    "PascalCaseWord",
    "snake_case_word",
    # combined: accents + punctuation + case + whitespace in one string
    "  “BJÖRK”— the  SÖNG  ",
    "Straße’s “Best” — Café",
    # --- fix round 1 (review Finding 3): plan-named casefold/trim edges ---
    # Turkish dotted capital I (U+0130): casefold -> "i" + U+0307 COMBINING DOT ABOVE
    "İstanbul",
    "İ",  # İ alone
    "ı",  # ı LATIN SMALL LETTER DOTLESS I (casefold no-op)
    "IİıI",  # ASCII I + dotted capital + dotless small + ASCII I
    # Greek sigma: final sigma ς and capital Σ both casefold to σ
    "Γιώργος",  # ends in final sigma U+03C2
    "ΚΑΛΟΣ",  # ALL-CAPS: trailing Σ U+03A3 -> σ U+03C3 (not final sigma)
    "ΟΔΥΣΣΕΥΣ Σ ς σ",
    # NBSP family: NFKC maps U+00A0 and U+202F to SPACE, then collapse/trim
    "Track\u00a0One",  # NO-BREAK SPACE U+00A0 between words
    "Track\u202fTwo",  # NARROW NO-BREAK SPACE U+202F between words
    "\u00a0Padded\u00a0",  # leading/trailing NBSP U+00A0
    # NFD-decomposed input: NFKC recomposes to precomposed form
    "Cafe\u0301",  # "Café" NFD: e + U+0301 COMBINING ACUTE ACCENT
    "Bjo\u0308rk",  # "Björk" NFD: o + U+0308 COMBINING DIAERESIS
    "Cafe\u0301 Mu\u0308ller",  # both accents NFD-decomposed
    # ZWSP U+200B: NOT whitespace to Python (str.strip keeps it, \s does not match)
    "\u200bSong",  # leading ZWSP U+200B must be PRESERVED
    "Song\u200b",  # trailing ZWSP must be PRESERVED
    "So\u200bng",  # interior ZWSP must be PRESERVED
    "\u200b",  # ZWSP-only stays non-empty (flips semantic_key eligibility)
    # Cherokee: casefold maps SMALL letters UP to capitals; capitals are fixed points
    "ᎠᎡᎢ",  # capitals U+13A0 U+13A1 U+13A2 (casefold no-op)
    "ꭰꭱꭲ",  # smalls U+AB70 U+AB71 U+AB72 -> capitals U+13A0 U+13A1 U+13A2
    "AᎠb",  # embedded capital (review repro)
    "Aꭰb",  # embedded small
    "ᏰᏵ",  # capitals U+13F0 U+13F5 (second Cherokee capital block)
    "ᏸᏽ",  # smalls U+13F8 U+13FD -> U+13F0 U+13F5
    "ᏣᎳᎩ ꮳꮃꭹ",  # "Cherokee" in capitals and in smalls
    # Historic Cyrillic U+1C80-1C88: casefold to modern Cyrillic small letters
    "ᲀ",  # ᲀ -> в U+0432
    "в",  # в (already the casefold target; alongside ᲀ per Finding 3)
    "ᲀᲁᲂᲃᲄᲅᲆᲇᲈ",  # full U+1C80-1C88 run
    "ᲀеᲂмᲄи",  # embedded with modern Cyrillic
]

normalize_cases = [
    {"input": value, "expected": normalize_text(value)} for value in NORMALIZE_INPUTS
]

# ---------------------------------------------------------------------------
# duration_to_ms corpus
# ---------------------------------------------------------------------------
DURATION_INPUTS = [
    None,
    0.0,
    1.0,
    183.0004,  # from tests/test_normalize.py -> 183000
    183.0006,  # from tests/test_normalize.py -> 183001
    # half-to-even (banker's rounding) probes: seconds*1000 lands near x.5
    0.0005,  # *1000 = 0.5 -> round-half-even -> 0
    0.0015,  # *1000 = 1.5 -> round-half-even -> 2
    0.0025,  # *1000 = 2.5 -> round-half-even -> 2
    0.0035,  # *1000 = 3.5 -> round-half-even -> 4
    0.0045,  # *1000 = 4.5 -> round-half-even -> 4
    0.0055,  # *1000 = 5.5 -> round-half-even -> 6
    183.4565,  # *1000 = 183456.5 -> round-half-even -> 183456
    183.4575,  # *1000 = 183457.5 -> round-half-even -> 183458
    2.5005,  # *1000 = 2500.5 -> round-half-even
    3600.9995,  # *1000 = 3600999.5 -> round-half-even
    0.1235,
    0.1245,
    1234.5,  # *1000 = 1234500 exact
    3600.0,
    59.999,
    0.001,
    0.0001,
]

duration_cases = [
    {"seconds": value, "ms": duration_to_ms(value)} for value in DURATION_INPUTS
]

normalize_path = OUT_DIR / "normalize.json"
duration_path = OUT_DIR / "duration.json"

normalize_path.write_text(json.dumps(normalize_cases, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
duration_path.write_text(json.dumps(duration_cases, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print(f"wrote {len(normalize_cases)} normalize cases -> {normalize_path}")
print(f"wrote {len(duration_cases)} duration cases -> {duration_path}")
