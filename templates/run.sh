#!/usr/bin/env bash
# Remote-VM wrapper: SCP repo + finetune.py to a CUDA VM, install deps, execute.
#
# Usage:
#   bash run.sh <vm-ip> <user> [--model MODEL] [--rank N] [--epochs N] ...
#
# Assumes:
#   - SSH key at $SSH_KEY (override via env, default: ~/.ssh/id_ed25519)
#     Workshop attendees: `SSH_KEY=./workshop-N.pem bash run.sh <ip> <user>`
#   - On WSL, keep the key inside the Linux home — /mnt/c keys have bad perms
#   - VM has python3, pip, CUDA driver
#   - VM is Ubuntu 22.04 or 24.04 (PEP 668 handled either way)
#
# After this completes, compare.md lands in /tmp/compare.md (locally).

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <vm-ip> <user> [extra args for finetune.py]"
  exit 1
fi
IP="$1"
USER_NAME="$2"
shift 2
EXTRA_ARGS="$*"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
if [ ! -f "$SSH_KEY" ]; then
  echo "FATAL: SSH key not found at $SSH_KEY. Set SSH_KEY=./your-key.pem and retry." >&2
  exit 1
fi
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)

# Where this skill lives — copy templates from here
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES="$SKILL_DIR/templates"

echo "[run] waiting for SSH on $IP..."
for i in $(seq 1 30); do
  if ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "echo ssh-ok" 2>/dev/null | grep -q ssh-ok; then
    echo "[run] SSH up after ${i}0s"; break
  fi
  sleep 10
done

echo "[run] copying finetune.py + eval.py + eval_prompts.json..."
ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "mkdir -p ~/work/{prompts,runs,data,models}"
scp "${SSH_OPTS[@]}" "$TEMPLATES/finetune.py" "ubuntu@$IP:~/work/finetune.py"
scp "${SSH_OPTS[@]}" "$TEMPLATES/eval.py" "ubuntu@$IP:~/work/eval.py"
scp "${SSH_OPTS[@]}" "$TEMPLATES/eval_prompts.json" "ubuntu@$IP:~/work/prompts/eval_prompts.json"

echo "[run] installing deps + running fine-tune (this is the long one — ~15-25 min)..."
ssh "${SSH_OPTS[@]}" "ubuntu@$IP" bash <<REMOTE
set -eo pipefail
nvidia-smi --query-gpu=name,memory.total --format=csv 2>&1 | head -3 || echo "(no nvidia-smi yet)"

# venv (PEP 668 on 24.04)
if [ ! -d ~/venv ]; then
  python3 -m venv ~/venv
fi
source ~/venv/bin/activate
pip install --upgrade pip wheel -q
pip install -q unsloth trl peft datasets bitsandbytes accelerate

# Default dataset: Dolly-1k from HF (skip if already there)
if [ ! -f ~/work/data/dolly_1k.jsonl ]; then
  echo "[remote] fetching Dolly-1k..."
  curl -sL "https://huggingface.co/datasets/databricks/databricks-dolly-15k/resolve/main/databricks-dolly-15k.jsonl" \
    | head -n 1000 > ~/work/data/dolly_1k.jsonl
  wc -l ~/work/data/dolly_1k.jsonl
fi

cd ~/work
echo "[remote] launching finetune.py --user $USER_NAME $EXTRA_ARGS..."
python finetune.py --user "$USER_NAME" \
  --dataset data/dolly_1k.jsonl \
  --eval-prompts prompts/eval_prompts.json \
  --out-dir runs \
  $EXTRA_ARGS 2>&1 | tail -300
REMOTE

echo "[run] pulling compare.md back to /tmp/compare.md..."
scp "${SSH_OPTS[@]}" "ubuntu@$IP:~/work/runs/${USER_NAME}-r1.compare.md" /tmp/compare.md \
  || echo "[run] compare.md not found yet — check VM"

echo "[run] DONE. compare.md at /tmp/compare.md"
echo "[run] Adapter still on VM at ~/work/runs/${USER_NAME}-r1.adapter — pull manually if needed"
