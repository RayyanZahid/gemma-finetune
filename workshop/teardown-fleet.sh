#!/usr/bin/env bash
# Teardown the workshop fleet: delete every workshop-N instance and its boot disk.
# Run this AS SOON AS the workshop is over.
#
# Required env: PROJECT_ID
# Optional: FLEET_SIZE (default 9), INSTANCE_PREFIX (default "workshop")

set -euo pipefail

PROJECT_ID="${PROJECT_ID:?need PROJECT_ID — source .env.workshop}"
FLEET_SIZE="${FLEET_SIZE:-9}"
INSTANCE_PREFIX="${INSTANCE_PREFIX:-workshop}"
NEBIUS="${NEBIUS:-$HOME/.nebius/bin/nebius}"
NEBIUS=$(command -v nebius 2>/dev/null || echo "$NEBIUS")

ALL_GOOD=1

for i in $(seq 1 "$FLEET_SIZE"); do
  NAME="${INSTANCE_PREFIX}-${i}"
  echo "----------------------------------------"
  echo "[teardown] shard $i ($NAME)"

  # ---- find instance id by name --------------------------------------------
  INSTANCE_ID=$("$NEBIUS" compute instance list --parent-id "$PROJECT_ID" 2>&1 | \
    awk -v n="$NAME" '/^      id: computeinstance-/{id=$2} /^      name: /{if($2==n){print id; exit}}')

  if [ -n "$INSTANCE_ID" ]; then
    echo "[teardown]   deleting instance $INSTANCE_ID..."
    "$NEBIUS" compute instance delete --id "$INSTANCE_ID" 2>&1 | head -5 || \
      echo "[teardown]   instance delete returned non-zero (may already be gone)"
  else
    echo "[teardown]   no instance found by name '$NAME' — already deleted?"
  fi

  sleep 2
  DISK_ID=$("$NEBIUS" compute disk list --parent-id "$PROJECT_ID" 2>&1 | \
    awk -v n="${NAME}-boot" '/^      id: computedisk-/{id=$2} /^      name: /{if($2==n){print id; exit}}')

  if [ -n "$DISK_ID" ]; then
    echo "[teardown]   deleting orphan boot disk $DISK_ID..."
    "$NEBIUS" compute disk delete --id "$DISK_ID" 2>&1 | head -5
  else
    echo "[teardown]   no orphan boot disk for $NAME"
  fi

  # verify
  if [ -n "${INSTANCE_ID:-}" ]; then
    out=$("$NEBIUS" compute instance get --id "$INSTANCE_ID" 2>&1 || true)
    if echo "$out" | grep -q "NotFound"; then
      echo "[teardown]   CONFIRMED gone."
    else
      echo "[teardown]   WARNING: $NAME still resolvable" >&2
      ALL_GOOD=0
    fi
  fi
done

echo "----------------------------------------"
if [ "$ALL_GOOD" -eq 1 ]; then
  echo "[teardown] FLEET DOWN. Meter stopped. Verify in console:"
  echo "[teardown]   https://console.nebius.com/$PROJECT_ID"
  rm -f nodes.csv
else
  echo "[teardown] WARNING: some shards may still be running. Re-run this script." >&2
  exit 1
fi
