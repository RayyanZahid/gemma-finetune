# gemma-finetune

QLoRA fine-tune **Gemma 4** on your own instruction data, end-to-end. Validated 2026-05-01 on a Nebius H100. Ships as a Claude Code skill, a standalone recipe, and a workshop host runbook.

> **Running at the Immersive Commons workshop, Sat Aug 22 2026** — *Fine-Tune Gemma 4 on Your Data*. Repo doubles as the attendee-facing playbook.
>
> **You bring the GPU.** We are not provisioning a shared box for attendees this round. Start at [`TASK.md`](TASK.md) § *Step 0 — get a GPU*: your own CUDA card, your own Nebius account, or a free Colab T4. The provisioning recipe you need is in [`nebius-gpu/`](nebius-gpu/) and it ends in a mandatory teardown, because tonight the meter is yours.

## What's in this repo

| Path | What it is |
|---|---|
| [`TASK.md`](TASK.md) | **Start here if you're an attendee** — get a GPU, run the tune, ship a compare.md, stop the meter |
| [`SKILL.md`](SKILL.md) | The recipe — 4-phase loop (prepare → baseline → train → tuned), defaults that work, hard-won knowledge |
| [`CHECKLIST.md`](CHECKLIST.md) | Pre-flight to verdict, per-phase gates |
| [`PITFALLS.md`](PITFALLS.md) | Every error encountered during validation, with the exact fix |
| [`templates/`](templates/) | `finetune.py`, `eval.py`, `eval_prompts.json`, `run.sh` — copy and run |
| [`nebius-gpu/`](nebius-gpu/) | Sister skill: provision → run → mandatory teardown on Nebius AI Cloud |
| [`workshop/`](workshop/) | Host runbook — `bootstrap.sh` for any box, plus the shared-box and 9-node fleet patterns if you're hosting for a room without accounts |

## Three ways to use this

### 1. As a standalone recipe (the default)

```bash
git clone https://github.com/RayyanZahid/gemma-finetune
cd gemma-finetune
bash workshop/bootstrap.sh        # venv + deps + Dolly-1k on any CUDA box. Idempotent.
python templates/finetune.py --user me --out-dir runs/me
```

Output: a LoRA adapter at `runs/me/me-r1.adapter` plus `runs/me/me-r1.compare.md` showing baseline vs tuned on five held-out prompts.

No GPU on hand? [`nebius-gpu/SKILL.md`](nebius-gpu/SKILL.md) rents one on your own account and tears it down again — ~$1 for a warm run. Or take the free Colab T4 lane in [`TASK.md`](TASK.md).

### 2. As a Claude Code skill

Drop the folder into `~/.claude/skills/gemma-finetune/` (and `~/.claude/skills/nebius-gpu/`). Triggers on phrases like *"fine-tune gemma"*, *"qlora gemma 4"*, *"unsloth gemma"*. The agent reads SKILL.md and executes.

### 3. As a workshop

Attendees bring their own compute and drive their own agent from [`TASK.md`](TASK.md); the host's job is coaching, not sysadmin. Host runbook — including the older host-provisioned patterns and what they cost — is in [`workshop/README.md`](workshop/README.md).

## What you get out of one fine-tune

A LoRA adapter that visibly changes the base model's behavior on a held-out prompt set. The success criterion is *"≥3 of N prompts show observable shift"* — not lower loss. Validation run hit **5/5**.

Total wall-clock for the validated recipe (Gemma 4 E4B + Dolly-1k + H100, warm caches): **~16 minutes**. Cost: **~$0.85** per warm run on Nebius on-demand. On a free Colab T4, budget ~30-40 minutes and $0.

## License

MIT (this repo). Dolly-15k dataset: CC-BY-SA 3.0. Gemma 4 weights: Apache 2.0 + [Gemma Terms of Use](https://ai.google.dev/gemma/docs/gemma_4_license).

## Authors

Rayyan Zahid · Eric Mockler · for Immersive Commons.
