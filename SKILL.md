---
name: gemma-finetune
description: QLoRA fine-tune a Gemma 4 family model on an instruction dataset, save the LoRA adapter, run a baseline-vs-tuned eval, and emit a compare.md showing observable behavior shift. Recipe layer — assumes you already have a CUDA GPU (use nebius-gpu skill for infra).
triggers: fine-tune gemma, qlora gemma 4, train gemma adapter, gemma 4 lora, gemma e4b finetune, finetune gemma 4 e4b, gemma 4 dolly, gemma instruction tuning, unsloth gemma
allowed-tools:
  - "Read"
  - "Write"
  - "Edit"
  - "Bash"
  - "Glob"
  - "Grep"
---

# gemma-finetune — QLoRA Fine-tune Gemma 4 on an Instruction Dataset

The user wants to take a Gemma 4 family model (E4B-it default, but E2B / 1B / 4B / 12B all in scope) and shape it on their own data — instruction tuning, voice transfer, domain adaptation — using a 4-bit QLoRA recipe that fits on a single GPU and finishes in minutes, not hours.

**This skill owns the recipe, not the infra.** It assumes you're already SSHed into a CUDA VM (or sitting at a local box with a 4090+). For provisioning a Nebius H100, compose with the [`nebius-gpu`](nebius-gpu/SKILL.md) sister skill (in this repo) — `nebius-gpu` gets you the box, `gemma-finetune` does the work.

The recipe encoded here is the one Ray validated **2026-05-01** on a Nebius H100 SXM (1gpu-16vcpu-200gb preset, ~$3.50 burn including a 25-min cold first run + a 17-min warm validation run + provisioning/teardown). Every flag, default, and gotcha below is what actually worked end-to-end — not what the docs imply. The validation hit **5/5 prompts shifted vs baseline** on the workshop's default eval set.

Supporting files in this skill (read as needed):

- `CHECKLIST.md` — step-by-step from "I have a GPU + dataset" to "I have a tuned adapter + compare.md"
- `PITFALLS.md` — every error encountered during validation, with the exact fix
- `templates/finetune.py` — single-file end-to-end recipe (mirror of `dry_run.py`)
- `templates/eval.py` — re-run baseline + tuned inference against an existing adapter
- `templates/run.sh` — SCP + SSH + execute wrapper for remote-VM use

---

## When to Use

All of these:

1. The model fits in QLoRA-compatible 4-bit on the available GPU (E4B fits in ~10GB; full Gemma 4 12B needs ~24GB; 26B needs H100).
2. The dataset is in instruction/response shape (Dolly-style, ShareGPT-style, OpenAssistant-style — anything `apply_chat_template` can render).
3. The user wants observable behavior change, not just lower loss. The skill's success criterion is "≥3 of N held-out prompts visibly shift" — not perplexity.
4. The user is fine with a LoRA adapter as output, not a merged full-precision model. (Merge is a one-line follow-up; the skill's default keeps adapter separate for portability.)

## When NOT to Use

- Pretraining from scratch. Use Megatron / GPT-NeoX / OLMo flows.
- RLHF / DPO. Different recipe (need a preference dataset and `trl.DPOTrainer`); shape is similar but the data + loss differ. Future skill.
- Multimodal fine-tuning of Gemma 4's vision/audio heads. The defaults here freeze those; you'd need a different `target_modules` set.
- Models outside the Gemma 4 family. The chat template + Unsloth `FastModel` paths are Gemma-tuned; for Llama / Qwen / Mistral, swap the model loader and template.

---

## The Four-Phase Loop

```
  1. Prepare         → dataset in JSONL, eval prompts in JSON, model name resolved (~5 min)
        |
        v
  2. Baseline        → load model 4-bit, inference on N held-out prompts, capture (~2 min)
        |
        v
  3. Train + Save    → QLoRA SFT, save adapter, capture training log (~10-15 min E4B/Dolly-1k/H100)
        |
        v
  4. Tuned + Compare → re-run held-out prompts on base+adapter, write compare.md, verdict (~2 min)
```

Total wall-clock for the validated recipe (Gemma 4 E4B + Dolly-1k + H100, warm caches): **~16.4 min** (model load 32s, baseline 72s, train 862s, tuned 20s). Cold first run adds ~2 min for HF model fetch + ~3 min for pip install.

---

## 1. Prepare (~5 min, no GPU yet)

### Dataset

Required shape: JSONL, one row per example, fields `instruction`, `response`, optional `context`. Dolly-15k is the canonical reference:

```bash
curl -L https://huggingface.co/datasets/databricks/databricks-dolly-15k/resolve/main/databricks-dolly-15k.jsonl \
  -o data/dolly_15k.jsonl
head -n 1000 data/dolly_15k.jsonl > data/dolly_1k.jsonl
```

For your own data: convert to JSONL with the same keys. If you only have `prompt` + `completion`, rename them to `instruction` + `response` — the chat-template wrapper in `finetune.py` keys off those.

### Eval prompts

A JSON file with N held-out prompts, each tagged with `id` and `category`. The skill's default is 5 prompts spanning 5 categories (closed_qa, creative_writing, general_qa, summarization, classification) — see `templates/eval_prompts.json`. Use **prompts the model has not seen during training**; the whole point is to surface behavior shift.

### Model name

The Unsloth-mirrored 4-bit-ready Gemma 4 family on Hugging Face:

| Model | Repo | VRAM (4-bit) | Notes |
|---|---|---|---|
| Gemma 4 E2B-it | `unsloth/gemma-4-E2B-it` | ~5 GB | Shared-VM workshop default (8+ concurrent). Laptop-class. |
| Gemma 4 E4B-it | `unsloth/gemma-4-E4B-it` | ~10 GB | Solo/2-attendee default. Best quality/cost. |
| Gemma 4 1B-it | `unsloth/gemma-4-1b-it` | ~3 GB | Tiny baseline |
| Gemma 4 4B-it | `unsloth/gemma-4-4b-it` | ~12 GB | |
| Gemma 4 12B-it | `unsloth/gemma-4-12b-it` | ~24 GB | Needs L40S+ |
| Gemma 4 26B-it | `unsloth/gemma-4-26b-it` | ~48 GB | H100 only |

`unsloth/gemma-4-*` mirrors are 4-bit-quant-ready and license-clean (Apache 2.0 wrapper around Google's Gemma weights). Always prefer them over `google/gemma-4-*` for fine-tuning — saves a quantization step and avoids the gated-model auth dance.

---

## 2. Baseline (~2 min)

Before training, capture the unmodified model's behavior on the eval set. This is the **evidence** that fine-tuning did anything. Without it the tuned outputs are unfalsifiable.

```python
from unsloth import FastModel

model, tokenizer = FastModel.from_pretrained(
    "unsloth/gemma-4-E4B-it",
    max_seq_length=1024,
    load_in_4bit=True,
    full_finetuning=False,
)
# baseline inference happens BEFORE get_peft_model() — naked base
baseline_outputs = run_inference(model, tokenizer, eval_prompts)
```

`templates/finetune.py` does this before calling `get_peft_model()`. Don't rearrange — once LoRA adapters are attached, you can't easily get clean baseline outputs without unloading.

---

## 3. Train + Save (~10-15 min on H100, more on smaller GPUs)

### LoRA defaults that work

```python
model = FastModel.get_peft_model(
    model,
    r=8,                    # rank — 8 is the workshop default. Up to 32 for harder tasks.
    lora_alpha=16,          # alpha — 2× rank is the convention
    target_modules=[
        "q_proj", "k_proj", "v_proj", "o_proj",
        "gate_proj", "up_proj", "down_proj",
    ],
)
```

`target_modules` is the **non-obvious one**. The Gemma family uses both attention (`q/k/v/o`) and MLP (`gate/up/down`) projections. Skipping the MLP set leaves a measurable amount of trainable signal on the floor.

### SFTTrainer config

```python
SFTConfig(
    num_train_epochs=3,
    per_device_train_batch_size=2,
    gradient_accumulation_steps=4,    # effective batch = 8
    learning_rate=2e-4,
    warmup_steps=5,
    logging_steps=10,
    save_strategy="no",                # adapter saved manually after train
    dataset_text_field="text",
    max_seq_length=1024,
    optim="adamw_8bit",                # halves optimizer state vs fp32
    report_to="none",
)
```

### Chat-template formatting

Apply Gemma's chat template to the dataset BEFORE passing to the trainer. Skipping this is the #1 silent-failure mode (loss ticks down but the model never learns the conversation shape):

```python
def fmt(r):
    return {"text": tokenizer.apply_chat_template([
        {"role": "user", "content": r["instruction"] + ("\n\n" + r["context"] if r.get("context") else "")},
        {"role": "assistant", "content": r["response"]},
    ], tokenize=False)}
ds = ds.map(fmt)
```

### Save the adapter

```python
model.save_pretrained("models/<your-name>-r1.adapter")
```

LoRA adapter dir is small (~30 MB for E4B at rank 8). Portable — drop it on any machine that has the base model and load with `PeftModel.from_pretrained(base, adapter_path)`.

---

## 4. Tuned + Compare (~2 min)

Re-run the same eval prompts on `base + adapter` (no model reload needed if you're still in the same script — the adapter is already attached after `get_peft_model`). Diff against baseline. Write `compare.md`:

```markdown
## factual-qa (closed_qa)

**Prompt:** What is the capital of France...

### Baseline
[base model output]

### Tuned
[adapter-attached output]

_(shifted | IDENTICAL)_
```

### Verdict

```
N/M prompts shifted vs baseline
Workshop success criterion: ≥3/5
```

If <3/5 shift, something is wrong:
- Loss didn't go down → tokenization issue (re-check chat template)
- Loss went down but outputs identical → adapter not loaded for tuned inference (verify `PeftModel.from_pretrained` if loading from disk)
- Outputs shifted but garbage → over-trained (lower epochs / lower lr) or dataset mismatch (chat template wrong key)

---

## Cost ladder

What a typical session burns on H100 SXM (~$2.95/hr ≈ $0.049/min on Nebius on-demand). Numbers are from the validated 2026-05-01 warm run:

| Phase | Time | Cost |
|---|---|---|
| Prepare (data, no GPU) | 5 min | $0 |
| Provision (instance create → RUNNING) | ~3 min | $0.15 |
| First-time pip install (unsloth + torch + bnb + …) | ~3 min | $0.15 |
| First-time HF model fetch (Gemma 4 E4B, ~5.7 GB) | ~2 min | $0.10 |
| Model load (4-bit, weights cached after first run) | 32 s | $0.026 |
| Baseline inference (5 prompts, includes Triton JIT) | 72 s | $0.060 |
| Train (1k Dolly × 3 epochs, batch=2, accum=4 → 375 steps) | 14 min 22 s | $0.71 |
| Save adapter (~30 MB on disk) | < 1 s | $0 |
| Tuned inference (5 prompts, kernels cached) | 20 s | $0.017 |
| Compare write + verdict | < 1 s | $0 |
| Teardown (instance + boot disk delete) | ~30 s | $0.025 |
| **Total — cold first run** | **~25 min** | **~$1.25** |
| **Total — warm subsequent runs** | **~17 min** | **~$0.85** |

For larger datasets: Dolly-15k full × 3 epochs ≈ 15× the training time → ~$11. For larger models: Gemma 4 12B ≈ 3× the training time at same rank → ~$2.10/run. E2B/E4B at LoRA rank 8 fit on a 4090; 12B+ needs L40S or H100.

**For a 20-attendee workshop on a shared H100**: each attendee runs 1-2 fine-tunes during a 2-hour window. Single-VM cost ≈ 2 hr × $2.95 = ~$5.90. Multi-VM (one per attendee, parallel) ≈ 20 × $1.25 = ~$25. Shared-VM is the right call if you can isolate users with namespaces or separate `/runs/<name>/` dirs.

---

## Common Patterns

### Pattern A: One-shot validation (this skill's default)

```
prepare → baseline → train → tuned → compare → done
```

For: validating a fine-tune recipe, A/B-testing a dataset, demoing fine-tuning.

### Pattern B: Hyperparameter sweep

```
prepare once
for r, alpha in [(4, 8), (8, 16), (16, 32)]:
    baseline (cached) → train → tuned → compare → save adapter as r{r}-a{alpha}
```

For: finding the rank/alpha sweet spot. Reuse baseline outputs across runs (deterministic generate, same seed).

### Pattern C: Multi-attendee workshop

Each attendee runs `templates/finetune.py --user <name>` against the same shared VM. Adapters land in `models/<name>-r1.adapter`, compares in `runs/<name>-r1.compare.md`. For a fleet pattern with 9 H100 nodes serving ~72 attendees in parallel, see [`workshop/README.md`](workshop/README.md) — co-host runbook from the May 5 2026 Immersive Commons workshop.

---

## Hard-won knowledge (read PITFALLS.md for the full list)

The five things that bit Ray during the 2026-05-01 validation:

1. **`apply_chat_template` returns a string instead of a tensor.** Gemma 4's "tokenizer" is actually `Gemma4Processor` (multimodal). For `tokenize=True` paths (anything that asks for `return_tensors="pt"`), the `content` field must be **multimodal blocks** — `[{"type":"text","text":"..."}]` — not a plain string. Plain strings silently default to `tokenize=False` and return a formatted text string, which then crashes with `AttributeError: 'str' object has no attribute 'to'` when you call `.to(model.device)`.

2. **Triton needs `python3-dev` headers to JIT-compile its CUDA helper.** The Nebius `mk8s-worker-node-*-ubuntu24.04-cuda12.8` image ships without `Python.h`. First call to `model.generate()` blows up with `fatal error: Python.h: No such file or directory` from `gcc`. Fix on the VM **before first generate**: `sudo apt-get install -y python3-dev python3.12-dev build-essential`. Bake into provisioning.

3. **SSH key from `/mnt/c/...` has bad WSL permissions.** WSL2 mounts Windows files as 0777. SSH refuses with `Permissions 0777 for ...id_ed25519 are too open. This private key will be ignored.` Copy to WSL-native `~/.ssh/id_ed25519` with `chmod 600` before SSHing to the VM. The skill's `templates/run.sh` already prefers `~/.ssh/id_ed25519`; populate it first.

4. **Flash Attention 2 is broken on the stock Nebius image.** Falls back to Xformers, which costs ~10-20% throughput. For workshops, accept the loss; FA2 install requires a 5-10 min compile that's not worth the wait. For repeated runs, install once: `pip install -q "flash-attn>=2.6" --no-build-isolation`.

5. **Unsloth's audio-tower hook fails silently for Gemma 4.** You'll see `Unsloth: Failed to register input-embedding hook for ...audio_tower: get_input_embeddings not auto-handled for Gemma4AudioModel`. Falls back to a pre-forward hook that works. Cosmetic warning — don't chase it.

---

## Templates (one-liner-ready)

- `templates/finetune.py` — full pipeline, parameterized via argparse
- `templates/eval.py` — re-run eval on existing adapter (no training)
- `templates/run.sh` — SCP + SSH + execute wrapper for remote-VM use
- `templates/eval_prompts.json` — 5-prompt default eval set

Read CHECKLIST.md for the exact run-order. Read PITFALLS.md when something errors.
