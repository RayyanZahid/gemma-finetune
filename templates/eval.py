"""Evaluate an existing LoRA adapter against the base model — no training.

Use this to:
  - Sanity-check that an adapter was saved correctly (loads + generates)
  - Re-run the side-by-side compare on a different held-out prompt set
  - A/B compare two adapters trained from the same base

Usage:
    python eval.py --adapter <path> --prompts <path> [--model <repo>]

Defaults to the workshop's Gemma 4 E4B base. The adapter must have been
trained on the same base model (or a compatible quantization config).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load_eval_prompts(path: Path) -> list[dict]:
    raw = json.loads(path.read_text())
    return raw["prompts"] if isinstance(raw, dict) and "prompts" in raw else raw


def run_inference(model, tokenizer, prompts: list[dict], max_new_tokens: int) -> dict:
    """Gemma 4 multimodal processor needs content as blocks, not plain str."""
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


def main() -> int:
    ap = argparse.ArgumentParser(description="Eval an existing LoRA adapter against base.")
    ap.add_argument("--adapter", required=True, help="Path to LoRA adapter dir.")
    ap.add_argument("--prompts", required=True, help="Path to eval_prompts.json.")
    ap.add_argument("--model", default="unsloth/gemma-4-E4B-it",
                    help="HF repo id of the BASE model the adapter was trained on.")
    ap.add_argument("--out", default=None,
                    help="Where to write compare.md. Defaults next to adapter dir.")
    ap.add_argument("--max-eval-tokens", type=int, default=200)
    args = ap.parse_args()

    adapter_path = Path(args.adapter).resolve()
    if not adapter_path.exists():
        print(f"FATAL: adapter dir {adapter_path} does not exist", file=sys.stderr)
        return 2

    eval_prompts = load_eval_prompts(Path(args.prompts))
    print(f"[eval] {len(eval_prompts)} prompts loaded")

    # Load base in 4-bit
    print(f"[model] loading base {args.model}...")
    from unsloth import FastModel
    base, tokenizer = FastModel.from_pretrained(
        args.model, max_seq_length=1024,
        load_in_4bit=True, full_finetuning=False,
    )

    # Baseline (no adapter)
    print(f"[baseline] running inference on naked base...")
    base_out = run_inference(base, tokenizer, eval_prompts, args.max_eval_tokens)

    # Attach adapter
    print(f"[adapter] loading {adapter_path}...")
    from peft import PeftModel
    tuned = PeftModel.from_pretrained(base, str(adapter_path))

    # Tuned (base + adapter)
    print(f"[tuned] running inference with adapter attached...")
    tuned_out = run_inference(tuned, tokenizer, eval_prompts, args.max_eval_tokens)

    # Compare
    out_path = Path(args.out) if args.out else adapter_path.parent / f"{adapter_path.name}.eval.compare.md"
    lines = [f"# Eval — {adapter_path.name}\n",
             f"\n**Base:** {args.model}\n",
             f"**Adapter:** {adapter_path}\n"]
    for p in eval_prompts:
        lines.append(f"\n## {p['id']} ({p.get('category', 'eval')})\n")
        lines.append(f"\n**Prompt:** {p['prompt']}\n")
        lines.append(f"\n### Baseline\n\n{base_out[p['id']]}\n")
        lines.append(f"\n### Tuned\n\n{tuned_out[p['id']]}\n")
        flag = "shifted" if base_out[p["id"]] != tuned_out[p["id"]] else "IDENTICAL"
        lines.append(f"\n_({flag})_\n")
    out_path.write_text("".join(lines), encoding="utf-8")

    n_shifted = sum(1 for p in eval_prompts if base_out[p["id"]] != tuned_out[p["id"]])
    print(f"\nVERDICT: {n_shifted}/{len(eval_prompts)} prompts shifted")
    print(f"Compare: {out_path}")
    return 0 if n_shifted >= 3 else 1


if __name__ == "__main__":
    sys.exit(main())
