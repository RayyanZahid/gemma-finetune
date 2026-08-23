"""Gemma 4 QLoRA fine-tune — end-to-end recipe.

Loads a Gemma 4 model in 4-bit, runs baseline inference on N held-out prompts,
trains a LoRA adapter via SFTTrainer on an instruction-tuned JSONL dataset,
saves the adapter, runs tuned inference, and writes a side-by-side compare.md.

Usage:
    python finetune.py --user <name> [options]

Defaults match the ic-fine-tune-gemma4 workshop recipe:
    model=unsloth/gemma-4-E4B-it, rank=8, alpha=16, epochs=3, dataset=Dolly-1k

Run on a CUDA-enabled VM (any provider). Pair with nebius-gpu skill for infra.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


def load_eval_prompts(path: Path) -> list[dict]:
    raw = json.loads(path.read_text())
    return raw["prompts"] if isinstance(raw, dict) and "prompts" in raw else raw


def run_inference(model, tokenizer, prompts: list[dict], max_new_tokens: int) -> dict:
    """Greedy-decode each prompt; return {id: text}.

    Gemma 4 ships as Gemma4Processor (multimodal). apply_chat_template needs
    content as multimodal blocks [{"type":"text","text":...}], not a plain str.
    """
    out: dict[str, str] = {}
    for p in prompts:
        ids = tokenizer.apply_chat_template(
            [{"role": "user",
              "content": [{"type": "text", "text": p["prompt"]}]}],
            return_tensors="pt", add_generation_prompt=True, tokenize=True,
        ).to(model.device)
        gen = model.generate(ids, max_new_tokens=max_new_tokens, do_sample=False)
        out[p["id"]] = tokenizer.decode(
            gen[0][ids.shape[1]:], skip_special_tokens=True,
        ).strip()
    return out


def write_compare(prompts, base_out, tuned_out, config, train_loss, timings, dest: Path,
                  eval_loss: float | None = None) -> str:
    lines = [
        "# Compare\n",
        f"\n**Config:** {json.dumps(config)}\n",
        f"**Train loss (final):** {train_loss:.4f}\n",
    ]
    if eval_loss is not None:
        gap = eval_loss - train_loss
        verdict = "overfitting" if gap > 0.5 else "healthy"
        lines.append(f"**Val loss (held-out):** {eval_loss:.4f}\n")
        lines.append(f"**Gap (val - train):** {gap:+.4f} -> {verdict}\n")
    else:
        lines.append("**Val loss:** not measured (no --eval-dataset)\n")
    lines.append(f"**Timings (s):** {json.dumps(timings)}\n")
    for p in prompts:
        lines.append(f"\n## {p['id']} ({p.get('category', 'eval')})\n")
        lines.append(f"\n**Prompt:** {p['prompt']}\n")
        lines.append(f"\n### Baseline\n\n{base_out[p['id']]}\n")
        lines.append(f"\n### Tuned\n\n{tuned_out[p['id']]}\n")
        flag = "shifted" if base_out[p["id"]] != tuned_out[p["id"]] else "IDENTICAL"
        lines.append(f"\n_({flag})_\n")
    lines.append("\n## Notes\n\n_What shifted, what surprised, what to brief differently next run._\n")
    text = "".join(lines)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text, encoding="utf-8")
    return text


def main() -> int:
    ap = argparse.ArgumentParser(description="Gemma 4 QLoRA fine-tune end-to-end.")
    ap.add_argument("--user", required=True, help="Used in output filenames.")
    ap.add_argument("--model", default="unsloth/gemma-4-E2B-it",
                    help="HF repo id. unsloth/gemma-4-{E2B,E4B,1b,4b,12b,26b}-it. "
                         "Default E2B (~5GB VRAM) for shared-VM workshops; bump to "
                         "E4B (~10GB) for solo runs.")
    ap.add_argument("--dataset", default="data/dolly_1k.jsonl",
                    help="Path to JSONL with instruction/response/(context) fields.")
    ap.add_argument("--eval-dataset", default="",
                    help="Held-out JSONL, same shape as --dataset. Enables "
                         "validation loss. Without it the run reports train loss "
                         "only, which on a small corpus rewards memorisation and "
                         "cannot rank two runs against each other.")
    ap.add_argument("--eval-prompts", default="prompts/eval_prompts.json",
                    help="Path to JSON with held-out eval prompts.")
    ap.add_argument("--rank", type=int, default=4,
                    help="LoRA rank. Default 4 for shared-VM workshops; 8-16 for "
                         "harder tasks or solo runs.")
    ap.add_argument("--alpha", type=int, default=8,
                    help="LoRA alpha. Convention: 2x rank.")
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--batch-size", type=int, default=2)
    ap.add_argument("--grad-accum", type=int, default=4)
    ap.add_argument("--max-seq-length", type=int, default=1024)
    ap.add_argument("--max-eval-tokens", type=int, default=200)
    ap.add_argument("--max-samples", type=int, default=0,
                    help="Subsample dataset to N rows; 0 = use all.")
    ap.add_argument("--out-dir", default="runs",
                    help="Directory for adapter, compare.md, training log.")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    timings: dict[str, float] = {}

    print(f"[config] user={args.user} model={args.model} rank={args.rank} alpha={args.alpha} epochs={args.epochs}")

    # 1. Load eval prompts
    eval_prompts = load_eval_prompts(Path(args.eval_prompts))
    print(f"[eval] loaded {len(eval_prompts)} held-out prompts")

    # 2. Model load (4-bit, naked base)
    print(f"\n[model] loading {args.model} in 4-bit QLoRA mode...")
    t0 = time.time()
    from unsloth import FastModel
    model, tokenizer = FastModel.from_pretrained(
        args.model,
        max_seq_length=args.max_seq_length,
        load_in_4bit=True,
        full_finetuning=False,
    )
    timings["model_load_s"] = round(time.time() - t0, 2)
    print(f"[model] loaded in {timings['model_load_s']}s")

    # 3. Baseline inference (BEFORE attaching LoRA)
    print(f"\n[baseline] running {len(eval_prompts)} prompts...")
    t0 = time.time()
    base_out = run_inference(model, tokenizer, eval_prompts, args.max_eval_tokens)
    timings["baseline_s"] = round(time.time() - t0, 2)
    for pid, text in base_out.items():
        print(f"  [{pid}] {text[:80]}{'...' if len(text) > 80 else ''}")

    # 4. Attach LoRA
    print(f"\n[peft] attaching LoRA r={args.rank} alpha={args.alpha}...")
    model = FastModel.get_peft_model(
        model,
        r=args.rank,
        lora_alpha=args.alpha,
        target_modules=[
            "q_proj", "k_proj", "v_proj", "o_proj",
            "gate_proj", "up_proj", "down_proj",
        ],
    )

    # 5. Train
    print(f"\n[train] starting QLoRA SFT on {args.dataset}...")
    from datasets import load_dataset
    from trl import SFTTrainer, SFTConfig

    ds = load_dataset("json", data_files=args.dataset, split="train")
    if args.max_samples > 0:
        ds = ds.select(range(min(args.max_samples, len(ds))))

    def fmt(r):
        user_msg = r["instruction"] + ("\n\n" + r["context"] if r.get("context") else "")
        return {"text": tokenizer.apply_chat_template(
            [{"role": "user", "content": user_msg},
             {"role": "assistant", "content": r["response"]}],
            tokenize=False)}
    ds = ds.map(fmt)
    print(f"[train] dataset rows after format: {len(ds)}")

    eval_ds = None
    if args.eval_dataset:
        eval_ds = load_dataset("json", data_files=args.eval_dataset, split="train").map(fmt)
        print(f"[train] held-out rows for validation loss: {len(eval_ds)}")
    else:
        print("[train] WARNING no --eval-dataset: train loss alone cannot rank two runs")

    t0 = time.time()
    trainer = SFTTrainer(
        model=model, tokenizer=tokenizer, train_dataset=ds,
        eval_dataset=eval_ds,
        args=SFTConfig(
            output_dir=str(out_dir / f"{args.user}-trainer"),
            num_train_epochs=args.epochs,
            per_device_train_batch_size=args.batch_size,
            gradient_accumulation_steps=args.grad_accum,
            learning_rate=args.lr,
            warmup_steps=5,
            logging_steps=10,
            save_strategy="no",
            eval_strategy="epoch" if eval_ds is not None else "no",
            per_device_eval_batch_size=args.batch_size,
            dataset_text_field="text",
            max_seq_length=args.max_seq_length,
            optim="adamw_8bit",
            report_to="none",
        ),
    )
    train_out = trainer.train()
    timings["train_s"] = round(time.time() - t0, 2)
    train_loss = float(train_out.training_loss)
    print(f"[train] done in {timings['train_s']}s, final loss={train_loss:.4f}")

    eval_loss = None
    if eval_ds is not None:
        t0 = time.time()
        eval_loss = float(trainer.evaluate()["eval_loss"])
        timings["val_s"] = round(time.time() - t0, 2)
        gap = eval_loss - train_loss
        state = "OVERFITTING" if gap > 0.5 else "healthy"
        print(f"[val]   held-out loss={eval_loss:.4f}  gap={gap:+.4f}  ({state})")

    # 6. Save adapter
    adapter_path = out_dir / f"{args.user}-r1.adapter"
    model.save_pretrained(str(adapter_path))
    print(f"[adapter] saved to {adapter_path}")

    # 7. Tuned inference (adapter still attached)
    print(f"\n[tuned] running {len(eval_prompts)} prompts...")
    t0 = time.time()
    tuned_out = run_inference(model, tokenizer, eval_prompts, args.max_eval_tokens)
    timings["tuned_s"] = round(time.time() - t0, 2)

    # 8. Compare + write
    config = {
        "model": args.model, "rank": args.rank, "alpha": args.alpha,
        "epochs": args.epochs, "samples": len(ds), "lr": args.lr,
        "batch_size": args.batch_size, "grad_accum": args.grad_accum,
        "max_seq_length": args.max_seq_length,
        "eval_samples": len(eval_ds) if eval_ds is not None else 0,
    }
    compare_path = out_dir / f"{args.user}-r1.compare.md"
    text = write_compare(eval_prompts, base_out, tuned_out, config,
                         train_loss, timings, compare_path, eval_loss=eval_loss)

    # 9. Verdict
    n_shifted = sum(1 for p in eval_prompts if base_out[p["id"]] != tuned_out[p["id"]])
    print(f"\n{'=' * 60}")
    print(f"VERDICT: {n_shifted}/{len(eval_prompts)} prompts shifted vs baseline")
    print(f"Workshop success criterion: ≥3/{len(eval_prompts)} shifted")
    print(f"Compare file: {compare_path}")
    print(f"Adapter: {adapter_path}")
    print(f"Total wall-clock: {sum(timings.values()):.1f}s")
    print(f"{'=' * 60}")
    print(f"\n--- compare.md preview ---\n{text[:1000]}{'...' if len(text) > 1000 else ''}")

    # 10. Training log
    log = {
        "user": args.user, "config": config, "train_loss": train_loss,
        "eval_loss": eval_loss,
        "overfit_gap": (eval_loss - train_loss) if eval_loss is not None else None,
        "timings_s": timings, "verdict": f"{n_shifted}/{len(eval_prompts)}",
    }
    (out_dir / f"{args.user}-r1.json").write_text(json.dumps(log, indent=2))

    return 0 if n_shifted >= 3 else 1


if __name__ == "__main__":
    sys.exit(main())
