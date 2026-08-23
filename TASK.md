# Task — Fine-tune Gemma 4 on your own GPU

You are fine-tuning a Gemma 4 model with QLoRA until it observably changes
behavior on a small held-out prompt set. You judge success by **diff against
baseline**, not by loss.

**The GPU is yours tonight.** We are not handing out SSH keys to a shared box.
You either already have a CUDA GPU, or you rent one for the next two hours on
your own account. That means you also own the meter — read § *The meter is
yours* before you provision anything.

---

## Step 0 — get a GPU (pick one lane)

| Lane | What it is | Cost | Time to ready |
|---|---|---|---|
| **A. Your own CUDA GPU** | 4090, 3090, laptop RTX, a box under your desk | $0 | ~5 min |
| **B. Rent a Nebius box** | H100 / L40S on your own Nebius account | ~$3/hr, ~$1 per run | ~15 min first time |
| **C. Free Colab / Kaggle** | T4 16 GB in a notebook | $0 | ~2 min |

Lane B is what the recipe was validated on. Lane A is fastest if you have the
card. Lane C works, but a T4 is roughly 4x slower than an H100 — stay on E2B
and expect ~30-40 min instead of ~12.

### Lane A — your own GPU

```bash
nvidia-smi                       # must print a card, driver CUDA >= 12.4
git clone https://github.com/RayyanZahid/gemma-finetune
cd gemma-finetune
bash workshop/bootstrap.sh       # venv + deps + Dolly-1k. Idempotent.
```

### Lane B — your own Nebius box

Read [`nebius-gpu/SKILL.md`](nebius-gpu/SKILL.md). It is the provision -> run ->
**teardown** loop, and it ships in this repo precisely so you can do this
yourself. Point your coding agent at it. Short version:

```bash
# on your laptop (WSL2 if you're on Windows — the nebius CLI is Linux/Mac only)
curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash
exec $SHELL
nebius profile create default \
  --endpoint api.nebius.cloud --federation-endpoint auth.nebius.com
nebius iam whoami                # should print your email

# then follow nebius-gpu/SKILL.md § 2 Discover and § 3 Provision.
# once the box is up and you can SSH in as ubuntu@<your-ip>:
ssh -i <your-key> ubuntu@<your-ip> \
  'curl -sSL https://raw.githubusercontent.com/RayyanZahid/gemma-finetune/master/workshop/bootstrap.sh | bash'
```

`bootstrap.sh` takes ~5 min on a cold box: apt deps, repo clone, venv, pip
install, Dolly-1k download, GPU verify. Safe to re-run.

**If account signup or GPU quota blocks you** — it can, on a brand-new Nebius
account — drop to Lane C and keep moving. Do not spend the workshop window
fighting a console.

### Lane C — Colab / Kaggle

New notebook, Runtime -> Change runtime type -> **T4 GPU**. Then:

```python
!git clone https://github.com/RayyanZahid/gemma-finetune
!pip install -q unsloth trl peft datasets bitsandbytes accelerate
!cd gemma-finetune && curl -sL "https://huggingface.co/datasets/databricks/databricks-dolly-15k/resolve/main/databricks-dolly-15k.jsonl" | head -n 1000 > data/dolly_1k.jsonl
!cd gemma-finetune && python templates/finetune.py --user <your-name> \
    --model unsloth/gemma-4-E2B-it --rank 4 --out-dir runs/<your-name>
```

Keep the tab awake. A disconnected Colab loses the run — download
`compare.md` as soon as VERDICT prints.

---

## Quickstart (once you have a box, any lane)

```bash
source ~/venv/bin/activate            # skip on Colab
cd ~/gemma-finetune
python templates/finetune.py --user <your-name> --out-dir runs/<your-name>
```

Replace `<your-name>` with whatever you registered with at the door. The whole
pipeline (load -> baseline -> train -> tuned -> compare) takes ~12 min on a warm
H100, ~30-40 min on a T4. While you wait, read `SKILL.md` § 3 to understand
what's happening.

---

## Hard constraints

- **Model**: size it to the VRAM *you actually have*, not to a shard you're
  sharing with anyone:

  | Your VRAM | Use | Flags |
  |---|---|---|
  | 6-12 GB (laptop, T4) | Gemma 4 E2B | `--model unsloth/gemma-4-E2B-it --rank 4` (script default) |
  | 16-24 GB (4090, L40S) | Gemma 4 E4B | `--model unsloth/gemma-4-E4B-it --rank 8` |
  | 80 GB (H100, solo) | E4B at higher rank, or 12B | `--model unsloth/gemma-4-E4B-it --rank 16` |

  On your own H100 you are **not** competing with seven other people for the
  card, so the old shared-shard default is too timid. Go E4B r8 or better.
- **LoRA rank**: 4 is the script default. Bump to 8 or 16 if your task is
  harder or you have headroom (`--rank 16`).
- **Training framework**: Unsloth (4-bit QLoRA). `bootstrap.sh` installs it.
- **Dataset**: `data/dolly_1k.jsonl` — first 1k rows of Databricks Dolly 15k,
  downloaded by `bootstrap.sh`. To specialize, subsample by category — the
  dataset has 8 (creative_writing, summarization, classification, ...).
- **Output adapter path**: `runs/<your-name>/<your-name>-r1.adapter`
- **Output compare**: `runs/<your-name>/<your-name>-r1.compare.md`

---

## Required workflow

1. **Baseline first.** `finetune.py` does this automatically before attaching
   the LoRA — five held-out prompts (`prompts/eval_prompts.json`) run against
   the naked base model. Save the outputs. Do not skip this step. Without
   baseline you cannot prove the tune did anything.

2. **Train.** LoRA rank 4, alpha 8, 3 epochs is the script default. You may
   bump rank to 8 or 16, change the dataset subset, or extend epochs. Every
   change goes in the **Notes** section of compare.md.

3. **Tuned inference.** `finetune.py` re-runs the same five prompts with the
   adapter attached, side-by-side with baseline.

4. **Reflect.** Open the compare.md, fill in the **Notes** section: what
   shifted, what surprised you, what you would brief differently next run.

---

## Success criterion

**At least 3 of 5 prompts show observable shift** in the tuned output vs the
baseline. Not lower loss — visible difference in *style*, *length*, *content*,
or *completion shape*. If you can't see it, the model can't.

The script's verdict line (last lines of stdout) will read e.g. `4/5 prompts
shifted vs baseline` — that's your number.

---

## The meter is yours

If you took Lane B, **you** are paying for that GPU, and Nebius bills by the
second from instance creation until deletion — not until you close your laptop,
not until the workshop ends.

- Write your teardown command down **before** you provision, not after.
- A forgotten H100 is about **$70/day**. Nobody in this room can see your
  console or stop your billing for you.
- The moment `compare.md` is on your laptop, tear the box down. You can always
  provision another one.

```bash
# pull the artifact FIRST
scp -i <your-key> ubuntu@<your-ip>:'~/gemma-finetune/runs/<your-name>/*.compare.md' .

# then stop the meter
nebius compute instance delete --id <instance-id>
nebius compute disk list --parent-id $PROJECT_ID   # delete the boot disk if it survived
nebius compute instance list --parent-id $PROJECT_ID   # must come back empty
```

Full teardown procedure, including the orphan-boot-disk case:
[`nebius-gpu/SKILL.md`](nebius-gpu/SKILL.md) § 4.

**Before you leave tonight, run teardown and verify the instance list is
empty.** That is the last checklist item, not an optional one.

---

## Failure recovery

| Symptom | What to try first |
|---|---|
| `CUDA out of memory` | Drop a size: E4B -> E2B, or `--rank 2`. On a 12 GB card, close other CUDA processes first — `nvidia-smi` shows who is holding the memory. |
| Outputs look identical (0/5 shift) | The adapter isn't loaded for tuned inference. Re-read `templates/finetune.py` step 7 — adapter must still be attached after `model.save_pretrained()`. |
| Training loss is flat or NaN | Tokenization issue. Check `ds["text"][0]` contains `<start_of_turn>user` and `<start_of_turn>model` markers (chat template applied). |
| `Python.h: No such file` from a Triton compile | `sudo apt-get install -y python3-dev build-essential` on your box (one-time). `bootstrap.sh` does this — re-run it. |
| `Gemma4ForConditionalGeneration` AttributeError | Unsloth wheel is stale. `pip install -U "unsloth @ git+https://github.com/unslothai/unsloth.git"` |
| Nebius signup or GPU quota rejected | Don't fight it. Switch to Lane C (Colab T4) and finish the run. Sort the account out after the workshop. |
| SSH: `Permissions 0777 ... are too open` | Your key is on a Windows mount. Copy it into your WSL/Linux home and `chmod 600`. See PITFALLS.md. |
| Colab disconnected mid-train | You lost the run. Re-run with `--max-samples 300 --epochs 2` so it finishes inside the idle timeout. |
| 30 min in, no usable output | **Stop.** Walk over to Eric or Ray. We will unblock faster than you can debug solo. |

---

## Things you should NOT do

- **Don't leave a rented GPU running.** See § *The meter is yours*. It is the
  only failure tonight that keeps costing you money after you go home.
- **Don't paste your Nebius credentials, HF token, or `.pem` into the repo, a
  shared doc, or a chat.** If you clone this repo on the box, `git status`
  stays clean of anything secret.
- **Don't `pip install -U torch`** into the venv mid-run. The dep set
  `bootstrap.sh` installs is known-good; upgrading torch under Unsloth is the
  fastest way to spend the workshop reinstalling.
- **Don't try to train 12B or 26B** unless you provisioned for it — ~24 GB and
  ~48 GB respectively at rank 8.

---

## What you ship

`runs/<your-name>/<your-name>-r1.compare.md` — that's the artifact you read out
at the round-table. **Pull it to your laptop before teardown.** The box is going
away; the compare.md should not go with it.

---

## Stretch (if you finish early)

- **Go bigger**: `--model unsloth/gemma-4-E4B-it --rank 8` (rank 16 on an H100).
  More capacity, more visible shift on hard prompts.
- **Hyperparameter sweep**: re-run at rank 8, rank 16, or epochs=5. Save each as
  `<name>-r2.adapter`. Diff the compares.
- **Report validation loss**: pass `--eval-dataset` with a held-out JSONL so the
  run reports val loss, not just train loss. Without it you cannot honestly rank
  two of your own runs against each other.
- **Specialize by category**: filter Dolly to one of its 8 categories before
  training. See if you get a "creative writer" or "classifier" Gemma.
- **Bring your own dataset**: any JSONL with `instruction` / `response` fields
  works. Put it at `data/<your-name>-mydata.jsonl` and point `--dataset` at it.

---

*If anything in this brief is ambiguous or wrong, that's the workshop. Ask.*
