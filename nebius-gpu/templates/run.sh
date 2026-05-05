#!/usr/bin/env bash
# Generic SSH + execute wrapper for a Nebius GPU instance.
#
# Args: $1 = path to local script to upload + run (defaults to ~/dry_run.py if missing).
# Required env: PUBLIC_IP. Optional: SSH_KEY (default ~/.ssh/id_ed25519), PIP_PACKAGES.
#
# Behavior:
#   1. Wait up to 5 min for SSH to come up (cloud-init can be slow).
#   2. Verify GPU visible.
#   3. SCP the script.
#   4. Create venv, pip install PIP_PACKAGES (or skip if empty), run script.
#   5. Tail last 200 lines of output back to the local terminal.
#
# Note: outputs from the remote run are NOT pulled back automatically. Add a
# trailing scp call below if your script writes artifacts you want locally.

set -euo pipefail

SCRIPT="${1:-$HOME/dry_run.py}"
PUBLIC_IP="${PUBLIC_IP:?need PUBLIC_IP}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
PIP_PACKAGES="${PIP_PACKAGES:-unsloth trl peft datasets bitsandbytes accelerate}"

# WSL fallback to /mnt/c if the Linux home doesn't have the key
if [ ! -f "$SSH_KEY" ] && [ -f "/mnt/c/Users/$USER/.ssh/id_ed25519" ]; then
  SSH_KEY="/mnt/c/Users/$USER/.ssh/id_ed25519"
fi
if [ ! -f "$SSH_KEY" ]; then
  echo "FATAL: SSH key not found at $SSH_KEY" >&2; exit 1
fi
if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found at $SCRIPT" >&2; exit 1
fi

USER_REMOTE=ubuntu
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)

echo "[run] waiting for SSH on $PUBLIC_IP..."
for i in $(seq 1 30); do
  if ssh "${SSH_OPTS[@]}" "$USER_REMOTE@$PUBLIC_IP" "echo ssh-ok" 2>/dev/null | grep -q ssh-ok; then
    echo "[run] SSH up after ${i}0s"; break
  fi
  sleep 10
done

echo "[run] verifying GPU..."
ssh "${SSH_OPTS[@]}" "$USER_REMOTE@$PUBLIC_IP" \
  'nvidia-smi --query-gpu=name,memory.total --format=csv 2>&1 | head -3' || \
  echo "[run] WARNING: nvidia-smi not available — GPU may not be present"

echo "[run] copying $(basename "$SCRIPT")..."
scp "${SSH_OPTS[@]}" "$SCRIPT" "$USER_REMOTE@$PUBLIC_IP:~/$(basename "$SCRIPT")"

echo "[run] installing deps + executing..."
ssh "${SSH_OPTS[@]}" "$USER_REMOTE@$PUBLIC_IP" bash <<REMOTE
set -e
if [ ! -d ~/venv ]; then
  python3 -m venv ~/venv
fi
source ~/venv/bin/activate
pip install --upgrade pip wheel -q
pip install -q ${PIP_PACKAGES}
echo "[remote] launching $(basename "$SCRIPT")..."
python ~/$(basename "$SCRIPT") 2>&1 | tail -200
REMOTE

echo "[run] DONE. (Remember to run teardown.sh — meter is still running!)"
