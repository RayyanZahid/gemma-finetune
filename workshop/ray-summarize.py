#!/usr/bin/env python3
"""Rank the sweep. Reads every runs/ray-t*/ray-t*-r1.json and prints a table.

Ranking is on validation loss. Training loss is shown because it is what the
script used to report, and because the gap between the two is the finding:
on a corpus this size the run with the lowest TRAIN loss is usually the most
memorised, and picking it would be picking the worst model.

The shifted count is not a quality score. It is a string comparison against the
baseline, so it saturates at 8/8 the moment training does anything at all.

Usage:
    python workshop/ray-summarize.py [runs_dir]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

NOTE = {
    "t01": "ANCHOR r16 a32 3ep",
    "t02": "rank 8",
    "t03": "rank 32",
    "t04": "alpha 1x rank",
    "t05": "alpha 4x rank",
    "t06": "lr 1e-4",
    "t07": "lr 3e-4",
    "t08": "2 epochs",
    "t09": "voice rows only",
}


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "runs")
    rows = []
    for f in sorted(root.glob("ray-t*/ray-t*-r1.json")):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except Exception as e:  # a truncated file should not kill the summary
            print(f"  unreadable {f}: {e}")
            continue
        c = d.get("config", {})
        rows.append({
            "id": d.get("user", f.parent.name).replace("ray-", ""),
            "r": c.get("rank"), "a": c.get("alpha"), "ep": c.get("epochs"),
            "lr": c.get("lr"), "n": c.get("samples"),
            "train": d.get("train_loss"),
            "val": d.get("eval_loss"),
            "gap": d.get("overfit_gap"),
            "shift": d.get("verdict", "-"),
            "secs": sum(d.get("timings_s", {}).values()),
        })

    if not rows:
        print(f"no completed runs under {root}/")
        return 1

    scored = [r for r in rows if r["val"] is not None]
    scored.sort(key=lambda r: r["val"])

    print()
    print("=" * 94)
    print(f"{'rank':<5}{'id':<6}{'what moved':<22}{'r':>3}{'a':>4}{'ep':>4}"
          f"{'lr':>7}{'rows':>6}{'train':>8}{'VAL':>8}{'gap':>8}{'shift':>7}{'min':>6}")
    print("=" * 94)
    for i, r in enumerate(scored, 1):
        lr = f"{r['lr']:.0e}" if isinstance(r["lr"], float) else str(r["lr"])
        print(f"{i:<5}{r['id']:<6}{NOTE.get(r['id'], ''):<22}{r['r']:>3}{r['a']:>4}"
              f"{r['ep']:>4}{lr:>7}{r['n']:>6}{r['train']:>8.4f}{r['val']:>8.4f}"
              f"{r['gap']:>+8.3f}{r['shift']:>7}{r['secs'] / 60:>6.1f}")
    unscored = [r for r in rows if r["val"] is None]
    for r in unscored:
        print(f"{'-':<5}{r['id']:<6}{'NO VAL LOSS':<22}{'':>32}{r['train']:>8.4f}"
              f"{'-':>8}{'-':>8}{r['shift']:>7}{r['secs'] / 60:>6.1f}")
    print("=" * 94)

    if scored:
        best, worst_gap = scored[0], max(scored, key=lambda r: r["gap"])
        by_train = min(scored, key=lambda r: r["train"])
        print(f"\nbest by validation loss   {best['id']}  "
              f"({NOTE.get(best['id'], '')})  val={best['val']:.4f}")
        if by_train["id"] != best["id"]:
            print(f"lowest TRAIN loss is      {by_train['id']}  val={by_train['val']:.4f}"
                  f"  <- ranking on train loss would have picked this one")
        print(f"most overfit              {worst_gap['id']}  gap={worst_gap['gap']:+.3f}")
        print(f"\nread runs/ray-{best['id']}/ray-{best['id']}-r1.compare.md against "
              f"data/ray-eval.reference.md")
        print("val loss ranks them; only reading the pairs tells you if the voice is right.")
    if unscored:
        print(f"\n{len(unscored)} run(s) have no val loss -- they cannot be ranked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
