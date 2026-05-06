# gemma-finetune — CHECKLIST

Step-by-step from "I have a CUDA GPU + a dataset" to "I have a tuned adapter + compare.md showing observable shift."

Use this in tandem with [`SKILL.md`](SKILL.md) (the why) and [`PITFALLS.md`](PITFALLS.md) (when something errors).

---

## Pre-flight (off-GPU, ~5 min)

- [ ] **GPU available.** `nvidia-smi` returns a card. ≥10 GB VRAM for E4B at QLoRA r=8. ≥6 GB for E2B. ≥24 GB for 12B.
- [ ] **Python 3.10+** on the GPU host. Ubuntu 22.04 / 24.04 stock works.
- [ ] **CUDA driver** ≥12.4 visible (`nvidia-smi` top-right). Newer is fine.
- [ ] **Dataset selected.** Pick one of the pre-staged datasets in `data/`: workshop default `dolly_1k.jsonl`, or voice/style alternatives `shakespeare_15k.jsonl`, `obama_15k.jsonl`, `trump_15k.jsonl`, `marktwain_15k.jsonl` — or bring your own JSONL. One row per example, fields `instruction`, `response`, optional `context`. Validate with `head -n 1 data/your_dataset.jsonl | python -m json.tool`. To build a voice/style dataset from a public corpus, see `data/build_voice_dataset.py`.
- [ ] **Eval prompts in JSON.** N held-out prompts, each `{id, category, prompt}`. Default at `templates/eval_prompts.json`.
- [ ] **Model name resolved.** Confirm the chosen `unsloth/gemma-4-*-it` repo on Hugging Face exists (`curl -sI -o /dev/null -w "%{http_code}\n" https://huggingface.co/unsloth/gemma-4-E4B-it/resolve/main/config.json` returns `200`).

If on Ubuntu 24.04 specifically — PEP 668 will block `pip install --user`. Use a venv:

```bash
python3 -m venv ~/venv && source ~/venv/bin/activate
```

---

## Phase 1: Install deps (~3-5 min on first run)

```bash
source ~/venv/bin/activate    # if you made one
pip install --upgrade pip wheel -q
pip install -q unsloth trl peft datasets bitsandbytes accelerate
```

- [ ] `python -c "from unsloth import FastModel; print(FastModel)"` runs without ImportError
- [ ] `python -c "import torch; print(torch.cuda.is_available())"` prints `True`

If the unsloth wheel doesn't recognize Gemma4 architecture (`AttributeError: ...Gemma4ForConditionalGeneration...`), pin to a newer release or install from source:

```bash
pip install -q "unsloth @ git+https://github.com/unslothai/unsloth.git"
```

---

## Phase 2: Baseline (~1-2 min)

- [ ] Load model in 4-bit **before** attaching LoRA — base inference must be on the naked model.
- [ ] Run inference on every prompt in eval set, deterministic decode (`do_sample=False`).
- [ ] Capture outputs in a dict keyed by prompt `id`.

The skill's `templates/finetune.py` does this automatically. Don't re-order — once `get_peft_model()` is called, you can't easily get clean baseline outputs without unloading.

---

## Phase 3: Train (~10-15 min for E4B/Dolly-1k/H100)

- [ ] Attach LoRA via `FastModel.get_peft_model(model, r=8, lora_alpha=16, target_modules=[...])`.
  Required `target_modules` for Gemma 4: `["q_proj","k_proj","v_proj","o_proj","gate_proj","up_proj","down_proj"]`. Skipping the MLP set leaves trainable signal on the floor.
- [ ] **Apply Gemma's chat template to the dataset** before passing to the trainer:
  ```python
  ds = ds.map(lambda r: {"text": tokenizer.apply_chat_template([
      {"role": "user", "content": r["instruction"] + ("\n\n" + r["context"] if r.get("context") else "")},
      {"role": "assistant", "content": r["response"]}
  ], tokenize=False)})
  ```
  This is the #1 silent-failure mode. Loss may tick down without it; the model still won't learn the conversation shape.
- [ ] `SFTTrainer` with the defaults from SKILL.md §3.
- [ ] Watch the training log: loss should decrease meaningfully across epochs. If it's flat or NaN — kill, fix, re-run (don't waste GPU time).
- [ ] `model.save_pretrained("models/<your-name>-r1.adapter")` after training.

---

## Phase 4: Tuned + Compare (~1-2 min)

- [ ] Re-run inference on the same eval set with the adapter still attached (no reload needed).
- [ ] Diff against baseline; tag each prompt `(shifted)` or `(IDENTICAL)`.
- [ ] Write `compare.md` with:
  - **Config** line (model, rank, alpha, epochs, samples)
  - **Train loss (final)**
  - **Timings (s)** per phase
  - One section per prompt: `## <id> (<category>)`, `**Prompt:**`, `### Baseline`, `### Tuned`, shift/identical tag
  - `## Notes` section — leave blank or fill with reflection

---

## Phase 5: Verdict

- [ ] **N/M prompts shifted vs baseline.**
- [ ] Workshop / validation success criterion: **≥3/5** (60%) shift on the default 5-prompt eval. Adjust threshold for your task.

If verdict fails:

| Failure | Most-likely cause | Fix |
|---|---|---|
| 0/5 shift, identical outputs | Adapter not loaded for tuned inference | Verify `model` is the same `get_peft_model` instance, OR if loading from disk, use `PeftModel.from_pretrained(base, adapter_path)` not `from_pretrained(adapter_path)` |
| 0/5 shift, garbage outputs | Chat template not applied during training | Check `ds["text"]` first row contains `<start_of_turn>user` / `<start_of_turn>model` markers |
| 1-2/5 shift, mostly identical | Under-trained | Bump epochs to 5, or rank to 16, or learning rate to 5e-4 |
| 5/5 shift but worse on factual prompts | Catastrophic forgetting | Lower epochs to 1-2, reduce dataset size, or mix in retention examples |

See PITFALLS.md for the full triage tree.

---

## Phase 6: (Optional) Merge adapter

For deployment without runtime adapter-load:

```python
merged = model.merge_and_unload()
merged.save_pretrained("models/<your-name>-r1.merged")
```

Doubles disk footprint vs adapter-only. Only do this if you're shipping the model and don't want the PEFT runtime dependency.

---

## Phase 7: Teardown (if on rented compute)

If on Nebius / RunPod / Lambda: **always teardown after pulling the artifact.** See [`nebius-gpu/SKILL.md`](../nebius-gpu/SKILL.md) §4 for the Nebius teardown.

The adapter is small (~30 MB for E4B at r=8). Pull it back with `scp` before tearing down. Compare.md is a few KB; pull that too.
