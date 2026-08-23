# gemma-finetune — PITFALLS

Every error encountered during validation, with the exact fix. Loaded as needed by the skill — keep adding entries when new failure modes surface.

This file populates from the [TBD] validation run on Nebius H100 SXM. Sections marked `[TBD]` get filled in as failures actually appear; sections without that tag are predicted from prior runs of similar recipes.

---

## Install / environment

### `error: externally-managed-environment` on `pip install`

**Where:** Ubuntu 24.04, fresh.
**Why:** PEP 668 marks the system Python as externally managed.
**Fix:** Use a venv. `python3 -m venv ~/venv && source ~/venv/bin/activate`, then `pip install`.

### Unsloth import says `Gemma4ForConditionalGeneration not found`

**Where:** Older unsloth wheel.
**Why:** Gemma 4 architecture was added after the cut of the wheel on PyPI you're pulling.
**Fix:** Install from source: `pip install -q "unsloth @ git+https://github.com/unslothai/unsloth.git"`. Or pin to ≥2026.4.

### `bitsandbytes` import warning about CUDA version mismatch

**Where:** When CUDA 12.8 is the host driver but bnb wheels target 12.4.
**Why:** bnb pins to specific CUDA minor versions in its prebuilt wheels.
**Fix:** Usually harmless — runs at slightly lower throughput. To silence: `pip install bitsandbytes --no-binary bitsandbytes` (compiles against host CUDA, ~2 min).

### `fatal error: Python.h: No such file or directory` mid-generate

**Where:** First call to `model.generate()` on a fresh Ubuntu VM.
**Why:** Triton JIT-compiles a tiny CUDA helper in C; Ubuntu ships without Python dev headers by default.
**Fix:** Install dev headers + a C toolchain on the VM **before** the first generate call:

```bash
sudo apt-get install -y python3-dev python3.12-dev build-essential
```

The Nebius `mk8s-worker-node-*-ubuntu24.04-cuda12.8` image does NOT include these. Bake into provisioning (cloud-init `runcmd:` or first SSH step). Without this, every torch.compile / inductor / triton kernel codegen path will fail.

### Unsloth audio_tower hook warning

**Where:** Model load on Gemma 4 multimodal (E2B/E4B-it).
**Symptom:** `Unsloth: Failed to register input-embedding hook for ...audio_tower: get_input_embeddings not auto-handled for Gemma4AudioModel; please override in the subclass.. Falling back to pre-forward hook.`
**Why:** Gemma 4's audio tower doesn't expose `get_input_embeddings` the way Unsloth expects.
**Fix:** None needed — Unsloth's pre-forward hook fallback works. Warning is cosmetic.

### Flash Attention 2 unavailable, falls back to Xformers

**Where:** Model load on H100.
**Symptom:** `Your Flash Attention 2 installation seems to be broken. Using Xformers instead.`
**Why:** FA2 prebuilt wheel missing or mismatched.
**Fix:** Optional. To get FA2 (~10-20% faster generate): `pip install -q "flash-attn>=2.6" --no-build-isolation`. Compile takes 5-10 min on first install. Skip for short workshops; throughput diff isn't worth the wait.

---

## Model load

### `OutOfMemoryError` on `FastModel.from_pretrained`

**Why:** Wrong model size for the GPU. Gemma 4 12B doesn't fit in ~10GB.
**Fix:** Either drop to E4B/E2B, or use a bigger GPU. The 4-bit quant is already on; you can't squeeze further without going to 3-bit (quality cliff).

### `ValueError: max_seq_length too large`

**Why:** Some configs enforce a hard cap.
**Fix:** Drop `max_seq_length` to 1024 (works for most instruction-tune workloads; Dolly/Alpaca rarely exceed 512 tokens).

### Model loads but tokenizer is missing pad token

**Why:** Some Gemma checkpoints don't ship `pad_token_id`.
**Fix:** `tokenizer.pad_token = tokenizer.eos_token`. Unsloth's loader does this automatically; only an issue with raw HF transformers.

### `apply_chat_template` returns a string instead of a tensor

**Where:** Gemma 4 (E2B/E4B/etc) — the "tokenizer" returned by `FastModel.from_pretrained` is actually `Gemma4Processor` (multimodal).
**Symptom:** `AttributeError: 'str' object has no attribute 'to'` when calling `.to(model.device)` on the chat-template result.
**Why:** `Gemma4Processor.apply_chat_template` defaults to `tokenize=False` for plain-string content, returning a formatted text string, not token ids.
**Fix (option A — recommended):** Pass content as multimodal blocks:

```python
ids = tokenizer.apply_chat_template(
    [{"role": "user",
      "content": [{"type": "text", "text": prompt}]}],
    return_tensors="pt", add_generation_prompt=True, tokenize=True,
).to(model.device)
```

Returns a Tensor; rest of inference path (`model.generate(ids, ...)`, slice with `gen[0][ids.shape[1]:]`, `tokenizer.decode(...)`) works unchanged.

**Fix (option B — alternative):** Two-step text-then-tokenize:

```python
text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
inputs = tokenizer(text=text, return_tensors="pt").to(model.device)
gen = model.generate(**inputs, max_new_tokens=...)
out = tokenizer.batch_decode(gen[:, inputs.input_ids.shape[1]:], skip_special_tokens=True)[0]
```

Returns BatchFeature; works with `**inputs` unpacking. Pick A for minimum diff to existing code; B if your model is text-only and you want canonical HF idiom.

**Note:** For *training* dataset format (`tokenize=False`), plain-string content is fine — the template renders text without iterating block types. The bug only triggers when `tokenize=True` is requested (which is implicit when `return_tensors="pt"` is passed without `tokenize=False`).

---

## Training

### Loss is flat / NaN from step 1

**Most likely:** Chat template not applied, OR labels not masked properly.
**Fix:** Inspect `ds["text"][0]` — it should contain `<start_of_turn>user\n...<end_of_turn>\n<start_of_turn>model\n...`. If you see raw `instruction:` / `response:` strings, you skipped `apply_chat_template`.

### Loss decreases but tuned outputs are identical to baseline

**Most likely:** Adapter not active during tuned inference.
**Diagnose:**

```python
print(model.peft_config)  # should show r, alpha, target_modules
# during inference, the adapter is auto-active if model is the get_peft_model instance
# only an issue if you reload from disk
```

**Fix (loaded-from-disk case):** `from peft import PeftModel; tuned = PeftModel.from_pretrained(base, "models/<name>-r1.adapter")` — then call `tuned.generate(...)`. Calling `from_pretrained(adapter_path)` alone returns just the adapter, not base+adapter.

### `CUDA out of memory` mid-training

**Why:** Effective batch (per-device × grad-accum) is too large for the residual VRAM after 4-bit weights.
**Fix:** Drop `per_device_train_batch_size` from 2 → 1. Or `gradient_accumulation_steps` from 4 → 2. Or `max_seq_length` from 1024 → 512. Or LoRA rank from 8 → 4.

### Training log spams `RuntimeError: probability tensor contains either inf, nan or element < 0`

**Why:** Numerical instability — usually from too-high learning rate at fp16/bf16.
**Fix:** Lower `learning_rate` from 2e-4 → 1e-4. Or switch optimizer to `adamw_torch` (slower, more stable).

[TBD — fill from validated run]

---

## Save + load

### `RuntimeError: ... safetensors_rust.SafetensorError`

**Why:** Adapter dir is incomplete (training crashed before save, or disk full).
**Fix:** Verify `models/<name>-r1.adapter/adapter_model.safetensors` exists and is non-zero.

### Tuned inference works in the same script but not on reload

**Why:** Adapter loaded onto a *fresh* base model that was loaded with different quantization config.
**Fix:** Match the quant config exactly when reloading:

```python
base, tok = FastModel.from_pretrained("unsloth/gemma-4-E4B-it",
    max_seq_length=1024, load_in_4bit=True, full_finetuning=False)
tuned = PeftModel.from_pretrained(base, "models/<name>-r1.adapter")
```

[TBD — fill from validated run]

---

## Eval / compare

### All 5 prompts shift but the shift looks like garbage

**Why:** Over-fit on a small dataset, or chat-template mismatch causing mode collapse.
**Fix:** Lower epochs to 1-2. Or use a larger dataset. Or check that the chat template you trained with matches what `apply_chat_template` produces at inference (sometimes the assistant role differs between training format and inference format).

### One prompt shifts dramatically; rest are identical

**Why:** Data distribution skew — one of your training rows happens to be very close to that one eval prompt.
**Fix:** Either accept (you confirmed the model can be steered) or hold a stricter eval set out of the same source.

[TBD — fill from validated run]

---

## Workshop-specific — attendees on their own compute

This is the default workshop shape (see `workshop/README.md` Pattern A). The
failure modes move from "they stomped each other" to "they never got a GPU" and
"they left one running."

### Attendee never gets a box — signup or GPU quota rejected

**Why:** A brand-new Nebius account does not always come with GPU quota granted,
and the console gives you this news at provision time, not at signup time.
**Fix:** Ask the room to create accounts the day BEFORE. On the night, don't
debug a console — move them to the free Colab T4 lane (`TASK.md` Lane C) and
finish the run. Sort billing/quota out afterwards.

### Attendee leaves a rented GPU running after they go home

**Why:** No host teardown script covers a box the host never provisioned. Closing
a laptop stops nothing; Nebius bills to instance deletion. ~$70/day, on their card.
**Fix:** Run the teardown call out loud at T+2h with the room, before the
round-table breaks up. `nebius compute instance list --parent-id $PROJECT_ID`
must come back empty, and the boot disk has to die too. This is a facilitation
step, not a documentation step — the doc alone does not do it.

### Attendee's key won't authenticate from Windows

**Why:** `.pem` saved under `/mnt/c/...` in WSL. DrvFs mounts 0777 and SSH refuses
the key: `Permissions 0777 for ... are too open`.
**Fix:** Copy it into the Linux home and `chmod 600`. On native PowerShell:
`icacls .\key.pem /inheritance:r /grant:r "$env:USERNAME:R"`.

### `nebius` CLI "installs" on Windows and then isn't there

**Why:** The CLI is Linux/Mac only. The install line appears to work in PowerShell
and leaves nothing on PATH.
**Fix:** `wsl --install`, then run the installer inside WSL. Budget 10 min for a
first-time WSL setup — this is a T-1d task, not a T+0 task.

### Colab run vanishes mid-training

**Why:** Idle-timeout or a tab disconnect. The VM is reclaimed with the adapter on it.
**Fix:** Size the run to finish inside the window — `--max-samples 300 --epochs 2`
on a T4 — and download `compare.md` the moment VERDICT prints.

### Attendee OOMs on a laptop card that "has enough VRAM"

**Why:** A browser, a game launcher, or a previous crashed run is still holding
CUDA memory. `nvidia-smi` names the process.
**Fix:** Kill the holder, or drop to E2B at `--rank 2`.

---

## Workshop-specific — host-provisioned shared box (Patterns B/C)

Only applies when the host hands out SSH keys to one shared VM.

### Multiple attendees writing to the same model file

**Why:** They forgot the `--user <name>` flag and all defaulted to `models/dryrun-r1.adapter`.
**Fix:** Add a guard at the top of `finetune.py` that fails loudly if `--user` is the default.

### One attendee's training run starves everyone else's GPU

**Why:** They asked for full Gemma 4 12B and the H100 spent 70GB on their weights, leaving 10GB for the other 7 kernels.
**Fix:** Lock `templates/finetune.py` to `unsloth/gemma-4-E4B-it` for the workshop. Bigger models = different event.

### One attendee `rm -rf`'d the shared dataset

**Why:** Agent went to "clean up" and reached too far.
**Fix:** Set `data/` and `prompts/` to read-only at attendee provisioning. `chmod 555 ~/gemma-finetune/data ~/gemma-finetune/prompts`.
