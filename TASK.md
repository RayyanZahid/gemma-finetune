# Task — Fine-tune Gemma 4 E4B on Dolly 1k

You are working on a remote Nebius H100 VM accessed via SSH. The VM is shared
with other workshop attendees. Your goal is a fine-tuned LoRA adapter on
Gemma 4 E4B that observably changes the model's behavior on a small held-out
prompt set. You will judge success by **diff against baseline**, not by loss.

## Quickstart

```bash
ssh -i <your-key.pem> ubuntu@89.169.103.92
cd ~/gemma-finetune
source ~/venv/bin/activate
python templates/finetune.py --user <your-name> --out-dir runs/<your-name>
```

Replace `<your-name>` with whatever you registered with at the door. The whole
pipeline (load → baseline → train → tuned → compare) takes ~12 minutes on a
warm box. While you wait, read `SKILL.md` § 3 to understand what's happening.

## Hard constraints

- **Model**: `unsloth/gemma-4-E2B-it` (default — small, ~5 GB VRAM, fits 8+
  concurrent on a shared H100). For a bigger model on a solo run, override
  with `--model unsloth/gemma-4-E4B-it` (~10 GB) or larger — see SKILL.md § 1.
- **LoRA rank**: 4 (default — fast train, smaller adapter). Bump to 8 or 16
  if your task is harder (`--rank 16`).
- **Training framework**: Unsloth (4-bit QLoRA). Already installed in `~/venv`.
- **Dataset**: `data/dolly_1k.jsonl` — first 1k rows of Databricks Dolly 15k.
  Already on the VM. If you want to specialize, subsample by category — the
  dataset has 8 (creative_writing, summarization, classification, ...).
- **Output adapter path**: `runs/<your-name>/<your-name>-r1.adapter`
- **Output compare**: `runs/<your-name>/<your-name>-r1.compare.md`

## Required workflow

1. **Baseline first.** `finetune.py` does this automatically before attaching
   the LoRA — five held-out prompts (`prompts/eval_prompts.json`) run against
   the naked base model. Save the outputs. Do not skip this step. Without
   baseline you cannot prove the tune did anything.

2. **Train.** LoRA rank 4, alpha 8, 3 epochs is the workshop default
   (smaller than the May-1 5/5 validation, but sized for a shared H100).
   You may bump rank to 8 or 16, change the dataset subset, or extend
   epochs. Every change goes in the **Notes** section of compare.md.

3. **Tuned inference.** `finetune.py` re-runs the same five prompts with the
   adapter attached, side-by-side with baseline.

4. **Reflect.** Open the compare.md, fill in the **Notes** section: what
   shifted, what surprised you, what you would brief differently next run.

## Success criterion

**At least 3 of 5 prompts show observable shift** in the tuned output vs the
baseline. Not lower loss — visible difference in *style*, *length*, *content*,
or *completion shape*. If you can't see it, the model can't.

The script's verdict line (last lines of stdout) will read e.g. `4/5 prompts
shifted vs baseline` — that's your number.

## Failure recovery

| Symptom | What to try first |
|---|---|
| `CUDA out of memory` | You're already on E2B+r4 by default. Drop to E2B+r2 (`--rank 2`) or wait 2 min for a peer to finish. The H100 is shared up to 8 ways. |
| Outputs look identical (0/5 shift) | The adapter isn't loaded for tuned inference. Re-read `templates/finetune.py` step 7 — adapter must still be attached after `model.save_pretrained()`. |
| Training loss is flat or NaN | Tokenization issue. Check `ds["text"][0]` contains `<start_of_turn>user` and `<start_of_turn>model` markers (chat template applied). |
| `Python.h: No such file` from a Triton compile | `sudo apt-get install -y python3-dev build-essential` on the VM (one-time). The bootstrap script does this — re-run it. |
| `Gemma4ForConditionalGeneration` AttributeError | Unsloth wheel is stale. `pip install -U "unsloth @ git+https://github.com/unslothai/unsloth.git"` |
| 30 min in, no usable output | **Stop**. Walk over to Eric or Ray. We will unblock faster than you can debug solo. |

## Things you should NOT do

- Don't `rm -rf` outside `runs/<your-name>/` and `models/<your-name>/`. The
  VM is shared with up to 5 other attendees. Their work is also under
  `runs/` and `models/`. Don't touch theirs.
- Don't change global Python deps (`pip install -U torch` etc.). The venv
  is sized for 6-way concurrent. Stomping it breaks everyone.
- Don't change anyone else's adapter, dataset, or compare.md.
- Don't try to train the 12B or 26B variant on this hardware concurrently.
  They fit one at a time — not at the same time as 5 other people.

## What you ship

`runs/<your-name>/<your-name>-r1.compare.md` — that's the artifact you read
out at the round-table. Optional: download it locally with `scp` so you
keep a copy after the meter stops at 9:30pm.

## Stretch (if you finish early)

- **Try E4B (the bigger sibling)**: `--model unsloth/gemma-4-E4B-it --rank 8`.
  ~10 GB VRAM — check that your shard isn't peaked before launching. More
  capacity, more visible shift on hard prompts.
- **Hyperparameter sweep**: re-run with rank 8, rank 16, or epochs=5. Save
  each as `<name>-r2.adapter`. Diff the compares.
- **Specialize by category**: filter Dolly to one of its 8 categories before
  training. See if you get a "creative writer" or "classifier" Gemma.
- **Bring your own dataset**: any JSONL with `instruction` / `response`
  fields works. SCP it up to `data/<your-name>-mydata.jsonl` and point
  `--dataset` at it.

---

*If anything in this brief is ambiguous or wrong, that's the workshop. Ask.*
