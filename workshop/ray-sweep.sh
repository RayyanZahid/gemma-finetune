#!/usr/bin/env bash
# Nine QLoRA runs around the anchor config, on Ray's own corpus.
#
# Anchor (T1) is exactly what was asked for: Gemma 4 E4B-it, rank 16, alpha 32,
# 3 epochs, QLoRA, 336 steps. Every other run moves ONE thing, so a difference in
# the result is attributable to that thing. T9 moves the data instead of a knob.
#
# Steps: 556 rows / effective batch 5 = 112 optimiser steps per epoch.
#   T1-T7  3 epochs -> 336 steps   (eff 4 would be 417, eff 6 would be 279)
#   T8     2 epochs -> 224 steps
#   T9     472 rows -> 285 steps
#
# Ranking is on VALIDATION loss against the 40 held-out rows, never on training
# loss. On a 556-row corpus the lowest training loss is the most memorised model.
#
# Resumable: a run whose .json already exists is skipped, so if the box dies you
# re-run this and it picks up. Does not stop on a failed run.
#
# Usage, from ~/gemma-finetune on the H100 box:
#   bash workshop/ray-sweep.sh              # all nine
#   bash workshop/ray-sweep.sh 1 9 3        # only T1, T9, T3
set -uo pipefail

MODEL="${MODEL:-unsloth/gemma-4-E4B-it}"
DATA="${DATA:-data/ray_combined.jsonl}"
EVAL="${EVAL:-data/ray_combined.eval.jsonl}"
DATA_VOICE="${DATA_VOICE:-data/ray_voice_only.jsonl}"
PROMPTS="${PROMPTS:-data/ray-eval.json}"
SEQ="${SEQ:-2048}"
BS="${BS:-5}"
GA="${GA:-1}"
OUT="${OUT:-runs}"

# id | rank | alpha | epochs | lr | dataset | what it asks
CONFIGS=(
  "t01|16|32|3|2e-4|$DATA|ANCHOR as specified: r16 a32 3ep, 336 steps"
  "t02| 8|16|3|2e-4|$DATA|half the rank, same 2x alpha ratio: is 16 needed?"
  "t03|32|64|3|2e-4|$DATA|double the rank: more capacity, or just more overfit?"
  "t04|16|16|3|2e-4|$DATA|alpha ratio 1x: weaker adapter scaling"
  "t05|16|64|3|2e-4|$DATA|alpha ratio 4x: stronger adapter scaling"
  "t06|16|32|3|1e-4|$DATA|half the learning rate: gentler fit"
  "t07|16|32|3|3e-4|$DATA|1.5x the learning rate: faster fit"
  "t08|16|32|2|2e-4|$DATA|two epochs, 224 steps: is the third epoch memorising?"
  "t09|16|32|3|2e-4|$DATA_VOICE|voice rows only, 285 steps: did the 84 writing rows help?"
)

want=("$@")
selected() {
  [ ${#want[@]} -eq 0 ] && return 0
  for w in "${want[@]}"; do [ "$(printf 't%02d' "$w")" = "$1" ] && return 0; done
  return 1
}

echo "=== preflight ==="
fail=0
for f in "$DATA" "$EVAL" "$DATA_VOICE" "$PROMPTS" templates/finetune.py; do
  if [ -r "$f" ]; then printf '  ok      %s (%s lines)\n' "$f" "$(wc -l <"$f")"
  else printf '  MISSING %s\n' "$f"; fail=1; fi
done
# The deck flags the repo id as unverified. Cheaper to find out now than after
# the meter has been running for a minute.
code=$(curl -s -o /dev/null -w '%{http_code}' "https://huggingface.co/api/models/${MODEL}")
printf '  http %s  %s\n' "$code" "$MODEL"
[ "$code" = "200" ] || fail=1
# Leakage check. The whole comparison is void if a held-out answer is in train.
python - "$DATA" "$EVAL" <<'PY' || fail=1
import json, re, sys, unicodedata
def norm(s):
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", s.lower())).strip()
rd = lambda p: [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]
tr, ev = rd(sys.argv[1]), rd(sys.argv[2])
ek = {norm(r["instruction"]) for r in ev} | {norm(r["response"]) for r in ev}
bad = sum(1 for r in tr if norm(r["instruction"]) in ek or norm(r["response"]) in ek)
print(f"  leak    {bad} train rows overlap the held-out set")
sys.exit(1 if bad else 0)
PY
[ "$fail" = "0" ] || { echo "PREFLIGHT FAILED -- fix before spending GPU time"; exit 1; }
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  gpu     /'

mkdir -p "$OUT"
sweep_t0=$(date +%s)
for cfg in "${CONFIGS[@]}"; do
  IFS='|' read -r id rank alpha epochs lr dset note <<<"$cfg"
  id=$(echo "$id" | tr -d ' '); rank=$(echo "$rank" | tr -d ' '); alpha=$(echo "$alpha" | tr -d ' ')
  selected "$id" || continue
  dir="$OUT/ray-$id"
  if [ -f "$dir/ray-$id-r1.json" ]; then
    echo "=== $id  SKIP (already done) ==="
    continue
  fi
  echo ""
  echo "=================================================================="
  echo "  $id  r=$rank a=$alpha ep=$epochs lr=$lr"
  echo "  $note"
  echo "  $(basename "$dset")"
  echo "=================================================================="
  t0=$(date +%s)
  mkdir -p "$dir"
  python templates/finetune.py \
    --user "ray-$id" \
    --model "$MODEL" \
    --dataset "$dset" \
    --eval-dataset "$EVAL" \
    --eval-prompts "$PROMPTS" \
    --rank "$rank" --alpha "$alpha" --epochs "$epochs" --lr "$lr" \
    --batch-size "$BS" --grad-accum "$GA" --max-seq-length "$SEQ" \
    --out-dir "$dir" 2>&1 | tee "$dir/train.log"
  rc=${PIPESTATUS[0]}
  echo "--- $id finished rc=$rc in $(( $(date +%s) - t0 ))s ---"
done

echo ""
echo "sweep wall-clock: $(( ($(date +%s) - sweep_t0) / 60 )) min"
python workshop/ray-summarize.py "$OUT"
echo ""
echo "COPY THESE OFF THE BOX BEFORE TEARDOWN:"
echo "  tar czf ray-sweep.tgz $OUT data/ray-eval.json data/ray-eval.reference.md"
echo "  # then from your laptop:  scp -i <key> ubuntu@<ip>:~/gemma-finetune/ray-sweep.tgz ."
