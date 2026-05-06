# gemma-finetune

QLoRA fine-tune **Gemma 4** on your own instruction data, end-to-end. Validated 2026-05-01 on a Nebius H100. Ships as a Claude Code skill, a standalone recipe, and a workshop fleet runbook.

> **Built for the May 5 2026 Immersive Commons workshop** — *Fine-Tune Gemma 4 on Your Data*. Repo doubles as the attendee-facing playbook.

## What's in this repo

| Path | What it is |
|---|---|
| [`SKILL.md`](SKILL.md) | The recipe — 4-phase loop (prepare → baseline → train → tuned), defaults that work, hard-won knowledge |
| [`CHECKLIST.md`](CHECKLIST.md) | Pre-flight to verdict, per-phase gates |
| [`PITFALLS.md`](PITFALLS.md) | Every error encountered during validation, with the exact fix |
| [`templates/`](templates/) | `finetune.py`, `eval.py`, `eval_prompts.json`, `run.sh` — copy and run |
| [`nebius-gpu/`](nebius-gpu/) | Sister skill: provision → run → mandatory teardown on Nebius AI Cloud |
| [`workshop/`](workshop/) | **Co-host fleet runbook** for batch-provisioning a 9-node H100 pool for ~72 attendees |

## Three ways to use this

### 1. As a Claude Code skill

Drop the folder into `~/.claude/skills/gemma-finetune/` (and `~/.claude/skills/nebius-gpu/`). Triggers on phrases like *"fine-tune gemma"*, *"qlora gemma 4"*, *"unsloth gemma"*. The agent reads SKILL.md and executes.

### 2. As a standalone recipe

```bash
git clone https://github.com/RayyanZahid/gemma-finetune
cd gemma-finetune
# you have a CUDA GPU already, locally or remote
pip install unsloth trl peft datasets bitsandbytes accelerate

# default: Dolly-1k (general instruction tuning)
python templates/finetune.py --user me --dataset data/dolly_1k.jsonl --out-dir runs

# voice/style alternatives — build first, then point --dataset at the result
python data/build_voice_dataset.py --source shakespeare
python templates/finetune.py --user me --dataset data/shakespeare_15k.jsonl --out-dir runs
```

`data/build_voice_dataset.py` produces 15k-row dolly-shaped JSONL from public corpora.
Sources online: `shakespeare`. More to come (`obama`, `trump`, `marktwain`).

Output: a LoRA adapter at `runs/me-r1.adapter` plus a `runs/me-r1.compare.md` showing baseline vs tuned on five held-out prompts.

### 3. As a workshop fleet (the May 5 night)

Co-host runbook is in [`workshop/README.md`](workshop/README.md). Provisions 9× H100 with 8 SSH users each, dispatches attendees to shards, tears down at the end. Cost ladder + dry-run flag included.

## What you get out of one fine-tune

A LoRA adapter that visibly changes the base model's behavior on a held-out prompt set. The success criterion is *"≥3 of N prompts show observable shift"* — not lower loss. Validation run hit **5/5**.

Total wall-clock for the validated recipe (Gemma 4 E4B + Dolly-1k + H100, warm caches): **~16 minutes**. Cost: **~$0.85** per warm run on Nebius on-demand.

## License

MIT (this repo). Dolly-15k dataset: CC-BY-SA 3.0. Gemma 4 weights: Apache 2.0 + [Gemma Terms of Use](https://ai.google.dev/gemma/docs/gemma_4_license).

## Authors

Rayyan Zahid · Eric Mockler · for Immersive Commons.
