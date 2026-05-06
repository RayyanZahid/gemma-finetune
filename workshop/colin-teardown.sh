#!/usr/bin/env bash
# colin-teardown.sh — kills every workshop shard YOU provisioned.
#
# Matches the naming convention from colin-add-shards.sh: instances named
# "ws-<your-username>-<N>" are torn down, plus their boot disks. Other
# people's shards (Ray's "workshop-N") are left untouched.
#
# Run this when the workshop ends. Mandatory — every minute of idle H100 burns ~$0.05.

set -uo pipefail
cd "$(dirname "$0")"

USER_PREFIX=$(whoami | tr -cd '[:alnum:]')
INSTANCE_PREFIX="ws-${USER_PREFIX}"

NEBIUS=""
if command -v nebius >/dev/null 2>&1; then
  NEBIUS=$(command -v nebius)
elif [ -x "$HOME/.nebius/bin/nebius" ]; then
  NEBIUS="$HOME/.nebius/bin/nebius"
else
  echo "FATAL: Nebius CLI not found." >&2; exit 1
fi

TENANT=$("$NEBIUS" iam whoami 2>&1 | awk '/tenant_id:/{print $2; exit}')
PROJECT_ID=$("$NEBIUS" iam project list --parent-id "$TENANT" 2>&1 | \
  awk '/^      id: project-/{print $2; exit}')

echo "[teardown] looking for instances named ${INSTANCE_PREFIX}-*..."
KILLED=0
for i in $(seq 1 50); do
  NAME="${INSTANCE_PREFIX}-${i}"
  ID=$("$NEBIUS" compute instance list --parent-id "$PROJECT_ID" 2>&1 | \
    awk -v n="$NAME" '/^      id: computeinstance-/{id=$2} /^      name: /{if($2==n){print id; exit}}')
  if [ -z "$ID" ]; then continue; fi

  echo "[teardown] deleting $NAME ($ID)..."
  "$NEBIUS" compute instance delete --id "$ID" 2>&1 | tail -2 || true
  sleep 2
  DISK_ID=$("$NEBIUS" compute disk list --parent-id "$PROJECT_ID" 2>&1 | \
    awk -v n="${NAME}-boot" '/^      id: computedisk-/{id=$2} /^      name: /{if($2==n){print id; exit}}')
  if [ -n "$DISK_ID" ]; then
    "$NEBIUS" compute disk delete --id "$DISK_ID" 2>&1 | tail -2 || true
  fi
  KILLED=$((KILLED + 1))
done

if [ "$KILLED" -eq 0 ]; then
  echo "[teardown] no ${INSTANCE_PREFIX}-* instances found. Nothing to do."
else
  echo "[teardown] killed $KILLED instances + their boot disks. Meter stopped."
fi
