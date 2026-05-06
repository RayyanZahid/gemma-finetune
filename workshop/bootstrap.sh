#!/usr/bin/env bash
# bootstrap.sh — pre-stage a Nebius H100 for the workshop.
# Idempotent: safe to re-run. Skips work that's already done.
#
# What this does (on the VM, run as ubuntu):
#   1. apt install python3-dev + build-essential (for Triton JIT — see PITFALLS.md)
#   2. clone or pull https://github.com/RayyanZahid/gemma-finetune to ~/gemma-finetune
#   3. create ~/venv (Python 3.12, PEP 668 compliant)
#   4. pip install unsloth + trl + peft + datasets + bitsandbytes + accelerate
#   5. download data/dolly_1k.jsonl (8.6 MB)
#   6. verify nvidia-smi sees the GPU + torch.cuda.is_available() returns True
#
# Usage on the VM:
#   curl -sSL https://raw.githubusercontent.com/RayyanZahid/gemma-finetune/master/workshop/bootstrap.sh | bash
# OR after a clone:
#   bash ~/gemma-finetune/workshop/bootstrap.sh

set -euo pipefail

REPO_URL="https://github.com/RayyanZahid/gemma-finetune.git"
REPO_DIR="$HOME/gemma-finetune"
VENV_DIR="$HOME/venv"
DOLLY_URL="https://huggingface.co/datasets/databricks/databricks-dolly-15k/resolve/main/databricks-dolly-15k.jsonl"

log() { echo "[bootstrap] $*"; }

# ---- 1. apt deps ------------------------------------------------------------
if ! dpkg -s python3-dev >/dev/null 2>&1; then
  log "installing python3-dev + build-essential (one-time, ~30s)..."
  sudo apt-get update -q
  sudo apt-get install -y -q python3-dev build-essential
else
  log "apt deps already present"
fi

# ---- 2. clone / pull repo ---------------------------------------------------
if [ ! -d "$REPO_DIR/.git" ]; then
  log "cloning $REPO_URL to $REPO_DIR..."
  git clone -q "$REPO_URL" "$REPO_DIR"
else
  log "pulling latest in $REPO_DIR..."
  git -C "$REPO_DIR" pull -q --ff-only
fi

cd "$REPO_DIR"

# ---- 3. venv ----------------------------------------------------------------
if [ ! -d "$VENV_DIR" ]; then
  log "creating venv at $VENV_DIR..."
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1090,SC1091
source "$VENV_DIR/bin/activate"

# ---- 4. python deps ---------------------------------------------------------
log "upgrading pip..."
pip install -q --upgrade pip wheel

if ! python -c "import unsloth" 2>/dev/null; then
  log "installing unsloth + trl + peft + datasets + bitsandbytes + accelerate (~3-4 min on first run)..."
  pip install -q unsloth trl peft datasets bitsandbytes accelerate sentencepiece protobuf
else
  log "python deps already installed"
fi

# ---- 5. datasets -------------------------------------------------------------
# dolly_1k.jsonl is the workshop default; the other datasets are built via
# data/build_voice_dataset.py (one source at a time, ~30-60s each on first run
# because HF downloads cache locally).

DOLLY_FULL="$REPO_DIR/data/databricks-dolly-15k.jsonl"
DOLLY_1K="$REPO_DIR/data/dolly_1k.jsonl"
if [ ! -f "$DOLLY_1K" ]; then
  log "downloading dolly-15k from HF (~13 MB)..."
  curl -sSL "$DOLLY_URL" -o "$DOLLY_FULL"
  head -n 1000 "$DOLLY_FULL" > "$DOLLY_1K"
  log "dolly_1k.jsonl ready ($(wc -l < "$DOLLY_1K") rows)"
else
  log "dolly_1k.jsonl already in place ($(wc -l < "$DOLLY_1K") rows)"
fi

# Build the voice/style datasets that data/build_voice_dataset.py knows about.
# Add new sources here as they're implemented in the build script.
for src in shakespeare; do
  out="$REPO_DIR/data/${src}_15k.jsonl"
  if [ ! -f "$out" ]; then
    log "building $src dataset (one-time, ~30-60s)..."
    if python "$REPO_DIR/data/build_voice_dataset.py" --source "$src"; then
      log "$src dataset ready ($(wc -l < "$out") rows)"
    else
      log "WARNING: $src build failed — attendees can pick another dataset" >&2
    fi
  else
    log "$src dataset already in place ($(wc -l < "$out") rows)"
  fi
done

# ---- 6. verify --------------------------------------------------------------
log "verifying GPU..."
if nvidia-smi --query-gpu=name,memory.total --format=csv 2>&1 | head -2; then
  :
else
  log "WARNING: nvidia-smi failed — GPU may not be present" >&2
fi

log "verifying torch CUDA..."
python -c "import torch; assert torch.cuda.is_available(), 'CUDA not available'; print('[bootstrap] torch CUDA OK,', torch.cuda.get_device_name(0))"

# ---- ergonomics -------------------------------------------------------------
mkdir -p "$REPO_DIR/runs" "$REPO_DIR/models"

# friendly login banner
DATA_LIST=$(ls -1 "$REPO_DIR/data/"*.jsonl 2>/dev/null | xargs -I{} sh -c 'printf "    %-32s %s rows\n" "$(basename {})" "$(wc -l < {})"')
cat > /tmp/ic-bootstrap-status <<EOF
[ic-experiment-1] bootstrap complete.
  repo:    $REPO_DIR
  venv:    $VENV_DIR (already activated)
  prompts: $REPO_DIR/prompts/eval_prompts.json
  GPU:     $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo unknown)

  datasets in $REPO_DIR/data/:
$DATA_LIST

To run (default = dolly_1k):
  source ~/venv/bin/activate
  cd ~/gemma-finetune
  python templates/finetune.py --user <your-name> --out-dir runs/<your-name>

To pick a different voice (e.g. Shakespeare):
  python templates/finetune.py --user <your-name> \\
    --dataset data/shakespeare_15k.jsonl \\
    --out-dir runs/<your-name>

See ~/gemma-finetune/TASK.md for the full agent briefing.
EOF
sudo cp /tmp/ic-bootstrap-status /etc/motd.d/ic-bootstrap 2>/dev/null || \
  cp /tmp/ic-bootstrap-status "$REPO_DIR/.bootstrap-status"

log "DONE. Activate the venv (source ~/venv/bin/activate) and you're ready to fine-tune."
log "Read ~/gemma-finetune/TASK.md for the agent briefing."
