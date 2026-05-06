#!/usr/bin/env bash
# Run bootstrap.sh on every node in nodes.csv, in parallel.
# Captures per-node logs in workshop/_bootstrap-logs/. Reports any failures.
#
# Required: nodes.csv (from provision-fleet.sh --submit)
# Optional: KEY_DIR (default keys/), BOOTSTRAP_URL (default the public master)
#
# Usage:  bash bootstrap-fleet.sh

set -uo pipefail

NODES="${NODES_CSV:-nodes.csv}"
KEY_DIR="${KEY_DIR:-keys}"
LOG_DIR="${LOG_DIR:-_bootstrap-logs}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://raw.githubusercontent.com/RayyanZahid/gemma-finetune/master/workshop/bootstrap.sh}"

if [ ! -f "$NODES" ]; then
  echo "FATAL: nodes.csv not found. Run provision-fleet.sh --submit first." >&2; exit 1
fi

mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.log

# ---- launch each bootstrap in background ------------------------------------
declare -a PIDS
declare -a SHARDS

while IFS=, read -r shard inst ip key; do
  if [ "$shard" = "shard" ]; then continue; fi  # skip header
  if [ -z "$ip" ] || [ "$ip" = "" ]; then
    echo "[bootstrap-fleet] WARNING: shard $shard has no IP — skipping" >&2
    continue
  fi

  KEY_FILE="$KEY_DIR/workshop-${shard}.pem"
  if [ ! -f "$KEY_FILE" ]; then
    echo "[bootstrap-fleet] FATAL: missing key $KEY_FILE for shard $shard" >&2
    exit 1
  fi

  # WSL fallback: copy to ~/.ssh if /mnt/c perms reject
  if ! [[ "$KEY_FILE" =~ ^/mnt/c/ ]]; then
    SSH_KEY="$KEY_FILE"
  else
    WSL_KEY="$HOME/.ssh/workshop-${shard}.pem"
    cp "$KEY_FILE" "$WSL_KEY"
    chmod 600 "$WSL_KEY"
    SSH_KEY="$WSL_KEY"
  fi

  LOG="$LOG_DIR/shard-${shard}.log"
  echo "[bootstrap-fleet] launching shard $shard ($ip) → $LOG"

  (
    SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 ubuntu@$ip"
    {
      echo "===== SHARD $shard / $ip ====="
      echo "[wait] cloud-init..."
      $SSH 'sudo cloud-init status --wait 2>&1 | tail -2' || echo "[wait] cloud-init wait returned non-zero"
      echo "[bootstrap] piping bootstrap.sh..."
      $SSH "curl -sSL $BOOTSTRAP_URL | bash 2>&1"
      echo "===== shard $shard DONE ====="
    } > "$LOG" 2>&1
  ) &

  PIDS+=($!)
  SHARDS+=($shard)
done < "$NODES"

# ---- wait for all -----------------------------------------------------------
echo "[bootstrap-fleet] waiting for ${#PIDS[@]} parallel bootstraps to finish..."
FAILED=()
for i in "${!PIDS[@]}"; do
  if wait "${PIDS[$i]}"; then
    echo "[bootstrap-fleet]   shard ${SHARDS[$i]}: OK"
  else
    echo "[bootstrap-fleet]   shard ${SHARDS[$i]}: FAILED — see $LOG_DIR/shard-${SHARDS[$i]}.log"
    FAILED+=("${SHARDS[$i]}")
  fi
done

echo "----"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "[bootstrap-fleet] ALL ${#PIDS[@]} shards bootstrapped cleanly."
else
  echo "[bootstrap-fleet] ${#FAILED[@]} shard(s) FAILED: ${FAILED[*]}" >&2
  echo "[bootstrap-fleet] Re-run after fixing — script is idempotent." >&2
  exit 1
fi
