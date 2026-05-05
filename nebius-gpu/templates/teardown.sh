#!/usr/bin/env bash
# Generic Nebius teardown. ALWAYS RUN THIS WHEN DONE.
#
# Required env vars:
#   INSTANCE_NAME   the name you used at provision time (used to find the boot disk)
#   PROJECT_ID      to scope the disk search
#
# Optional:
#   INSTANCE_ID     if you have it, this is faster (skips the name lookup)
#
# What this does:
#   1. Delete the instance (stops the compute meter).
#   2. Find any orphan boot disk named <INSTANCE_NAME>-boot.
#   3. Delete it (managed disks survive instance delete by default — bug or feature).
#   4. Verify the instance is NotFound.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:?need PROJECT_ID}"
INSTANCE_NAME="${INSTANCE_NAME:?need INSTANCE_NAME}"
NEBIUS="${NEBIUS:-$HOME/.nebius/bin/nebius}"

# ---- find instance id by name (if not provided) ----------------------------
if [ -z "${INSTANCE_ID:-}" ]; then
  INSTANCE_ID=$("$NEBIUS" compute instance list --parent-id "$PROJECT_ID" 2>&1 | \
    awk -v n="$INSTANCE_NAME" '/^      id: computeinstance-/{id=$2} /^      name: /{if($2==n){print id; exit}}')
fi

# ---- delete instance --------------------------------------------------------
if [ -n "${INSTANCE_ID:-}" ]; then
  echo "[teardown] deleting instance $INSTANCE_ID ($INSTANCE_NAME)..."
  "$NEBIUS" compute instance delete --id "$INSTANCE_ID" 2>&1 | head -10 || \
    echo "[teardown] instance delete returned non-zero (may already be gone)"
else
  echo "[teardown] no instance found by name '$INSTANCE_NAME' — already deleted?"
fi

# ---- delete orphan boot disk -----------------------------------------------
sleep 3  # give instance delete a moment to release the disk
DISK_ID=$("$NEBIUS" compute disk list --parent-id "$PROJECT_ID" 2>&1 | \
  awk -v n="${INSTANCE_NAME}-boot" '/^      id: computedisk-/{id=$2} /^      name: /{if($2==n){print id; exit}}')

if [ -n "$DISK_ID" ]; then
  echo "[teardown] deleting orphan boot disk $DISK_ID..."
  "$NEBIUS" compute disk delete --id "$DISK_ID" 2>&1 | head -10
else
  echo "[teardown] no orphan boot disk found"
fi

# ---- verify instance gone ---------------------------------------------------
if [ -n "${INSTANCE_ID:-}" ]; then
  echo "[teardown] verifying instance is gone..."
  out=$("$NEBIUS" compute instance get --id "$INSTANCE_ID" 2>&1 || true)
  if echo "$out" | grep -q "NotFound"; then
    echo "[teardown] CONFIRMED: instance NotFound (meter stopped)."
  else
    echo "[teardown] WARNING: instance still resolvable — re-run teardown" >&2
    echo "$out" | head -3 >&2
    exit 1
  fi
fi

echo "[teardown] done. Verify in console: https://console.nebius.com/$PROJECT_ID"
