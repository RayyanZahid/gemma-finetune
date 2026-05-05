#!/usr/bin/env bash
# Generate one ssh keypair per workshop shard.
# Output: keys/workshop-1.pem ... keys/workshop-9.pem (private)
#         keys/workshop-1.pem.pub ... (public, baked into nodes via cloud-init)
#
# Idempotent: skips shards whose key already exists.

set -euo pipefail

FLEET_SIZE="${FLEET_SIZE:-9}"
INSTANCE_PREFIX="${INSTANCE_PREFIX:-workshop}"
KEY_DIR="${KEY_DIR:-keys}"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

for i in $(seq 1 "$FLEET_SIZE"); do
  KEY="$KEY_DIR/${INSTANCE_PREFIX}-${i}.pem"
  if [ -f "$KEY" ]; then
    echo "[keys] $KEY exists — skipping"
    continue
  fi
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${INSTANCE_PREFIX}-${i}@ic-workshop" -q
  chmod 600 "$KEY"
  chmod 644 "$KEY.pub"
  echo "[keys] generated $KEY"
done

echo
echo "[keys] $FLEET_SIZE keypairs ready in $KEY_DIR/"
echo "[keys] private keys are 0600. Distribute to attendees via Luma DM or signed URL."
