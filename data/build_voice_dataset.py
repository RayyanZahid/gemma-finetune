#!/usr/bin/env python3
"""
Build instruction-tuned JSONL datasets in dolly-15k schema for the gemma-finetune workshop.

Sources (incremental — only the implemented ones run):
    shakespeare : 4-line sliding-window continuation + per-line style
    (others to be added: dolly, obama, trump, marktwain)

Output: data/<source>_15k.jsonl, exactly 15000 rows, schema {instruction, response, context, category}
matching templates/finetune.py:150-155.

Usage:
    python data/build_voice_dataset.py --source shakespeare
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

TARGET_ROWS = 15_000
SHAKESPEARE_HF = "benchaffe/shakespeare-lines"

THEMES = [
    "love", "fate", "death", "honor", "betrayal",
    "ambition", "jealousy", "loyalty", "time", "beauty",
]


def load_shakespeare_lines() -> list[str]:
    from datasets import load_dataset
    print(f"[shake] loading HF {SHAKESPEARE_HF}", file=sys.stderr)
    ds = load_dataset(SHAKESPEARE_HF, split="train")
    lines = [(row.get("text") or "").strip() for row in ds]
    lines = [ln for ln in lines if 10 <= len(ln) <= 200]
    print(f"[shake] usable lines: {len(lines)} / {len(ds)} raw", file=sys.stderr)
    return lines


def build_shakespeare(rng: random.Random, n: int) -> list[dict]:
    lines = load_shakespeare_lines()

    rows: list[dict] = []
    seen: set[tuple[str, str, str]] = set()

    def add(row: dict) -> bool:
        key = (row["instruction"], row.get("context", ""), row["response"])
        if key in seen or not row["instruction"] or not row["response"]:
            return False
        seen.add(key)
        rows.append(row)
        return True

    cont_target = int(n * 12500 / 15000)  # 12500
    style_target = n - cont_target         # 2500

    # Continuation: 4-line sliding windows, 2 lines context → 2 lines response.
    # Walk in stride=2 to avoid heavy overlap.
    for i in range(0, len(lines) - 3, 2):
        if sum(1 for r in rows if r["instruction"].startswith("Continue")) >= cont_target:
            break
        first2 = lines[i] + "\n" + lines[i + 1]
        next2 = lines[i + 2] + "\n" + lines[i + 3]
        add({
            "instruction": "Continue this passage in Shakespearean style.",
            "context": first2,
            "response": next2,
            "category": "creative_writing",
        })

    # Style: write a Shakespearean line about <theme> → actual line.
    style_pool = [ln for ln in lines if 20 <= len(ln) <= 120]
    rng.shuffle(style_pool)
    for idx, line in enumerate(style_pool):
        if sum(1 for r in rows if r["instruction"].startswith("Write")) >= style_target:
            break
        theme = THEMES[idx % len(THEMES)]
        add({
            "instruction": f"Write a Shakespearean line about {theme}.",
            "context": "",
            "response": line,
            "category": "creative_writing",
        })

    return rows[:n]


def validate(rows: list[dict], expected: int) -> None:
    assert len(rows) == expected, f"expected {expected} rows, got {len(rows)}"
    seen: set[tuple[str, str, str]] = set()
    for i, r in enumerate(rows):
        assert r.get("instruction"), f"row {i}: empty instruction"
        assert r.get("response"), f"row {i}: empty response"
        key = (r["instruction"], r.get("context", ""), r["response"])
        assert key not in seen, f"row {i}: duplicate of earlier row"
        seen.add(key)


def write_jsonl(rows: list[dict], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"[write] {len(rows)} rows → {path}", file=sys.stderr)


SOURCES = ["shakespeare"]  # extend as builders are added

BUILDERS = {
    "shakespeare": build_shakespeare,
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=SOURCES, required=True)
    ap.add_argument("--out", help="output path (default: data/<source>_15k.jsonl)")
    ap.add_argument("--rows", type=int, default=TARGET_ROWS)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    out = Path(args.out) if args.out else Path(f"data/{args.source}_15k.jsonl")
    print(f"\n=== building {args.source} → {out} ===", file=sys.stderr)
    rows = BUILDERS[args.source](rng, args.rows)
    validate(rows, args.rows)
    write_jsonl(rows, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
