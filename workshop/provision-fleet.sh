#!/usr/bin/env bash
# Provision a fleet of N Nebius H100 nodes for the workshop.
# Defaults to --dry-run. Add --submit to actually create instances.
#
# Required env (source .env.workshop first):
#   PROJECT_ID, SUBNET_ID, PLATFORM, PRESET, IMAGE_FAMILY
# Optional:
#   FLEET_SIZE (default 9), INSTANCE_PREFIX (default "workshop"),
#   DISK_GB (200), IMAGE_PARENT (project-e00public-images),
#   START_SHARD (1) — resume a partial fleet by skipping shards 1..START_SHARD-1
#   KEY_DIR (keys)
#
# Output: nodes.csv (shard,instance_id,public_ip,ssh_key)

set -euo pipefail

# ---- arg parsing ------------------------------------------------------------
SUBMIT=0
START_SHARD=1
for arg in "$@"; do
  case "$arg" in
    --submit) SUBMIT=1 ;;
    --dry-run) SUBMIT=0 ;;
    --start-shard=*) START_SHARD="${arg#*=}" ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *) echo "[fleet] unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---- env validation ---------------------------------------------------------
for var in PROJECT_ID SUBNET_ID PLATFORM PRESET IMAGE_FAMILY; do
  if [ -z "${!var:-}" ]; then
    echo "FATAL: \$$var is required. Run 'source .env.workshop' first." >&2
    exit 1
  fi
done

FLEET_SIZE="${FLEET_SIZE:-9}"
INSTANCE_PREFIX="${INSTANCE_PREFIX:-workshop}"
DISK_GB="${DISK_GB:-200}"
IMAGE_PARENT="${IMAGE_PARENT:-project-e00public-images}"
KEY_DIR="${KEY_DIR:-keys}"
NEBIUS="${NEBIUS:-$HOME/.nebius/bin/nebius}"
NEBIUS=$(command -v nebius 2>/dev/null || echo "$NEBIUS")

# ---- dry-run banner ---------------------------------------------------------
if [ "$SUBMIT" -eq 0 ]; then
  echo "[fleet] DRY-RUN — no instances will be created. Add --submit to provision."
  echo
fi

# ---- nodes.csv header (if not resuming) -------------------------------------
if [ "$START_SHARD" -eq 1 ] && [ "$SUBMIT" -eq 1 ]; then
  echo "shard,instance_id,public_ip,ssh_key" > nodes.csv
fi

# ---- per-shard loop ---------------------------------------------------------
for i in $(seq "$START_SHARD" "$FLEET_SIZE"); do
  NAME="${INSTANCE_PREFIX}-${i}"
  KEY="$KEY_DIR/${NAME}.pem.pub"

  if [ ! -f "$KEY" ]; then
    echo "[fleet] FATAL: missing public key $KEY. Run 'bash generate-keys.sh' first." >&2
    exit 1
  fi

  PUB=$(cat "$KEY")

  echo "----------------------------------------"
  echo "[fleet] shard $i  name=$NAME  platform=$PLATFORM  preset=$PRESET"
  echo "[fleet]   key=$KEY ($(echo "$PUB" | cut -c1-30)...)"
  echo "[fleet]   disk=${DISK_GB}GB  image=$IMAGE_FAMILY"

  if [ "$SUBMIT" -eq 0 ]; then
    echo "[fleet]   [dry-run] would call nebius compute instance create"
    continue
  fi

  # build cloud-init
  CLOUD_INIT=$(cat <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${PUB}
ssh_authorized_keys:
  - ${PUB}
write_files:
  - path: /etc/motd.d/ic-workshop
    content: |
      [ic-workshop] shard ${i} of ${FLEET_SIZE}. Anchor your work in ~/runs/<your-name>/ and ~/models/<your-name>/. Don't rm -rf anyone else's stuff.
    permissions: '0644'
EOF
)

  echo "[fleet]   submitting..."
  "$NEBIUS" compute instance create \
    --parent-id "$PROJECT_ID" \
    --name "$NAME" \
    --resources-platform "$PLATFORM" \
    --resources-preset "$PRESET" \
    --boot-disk-attach-mode READ_WRITE \
    --boot-disk-managed-disk-type NETWORK_SSD \
    --boot-disk-managed-disk-source-image-family-image-family "$IMAGE_FAMILY" \
    --boot-disk-managed-disk-source-image-family-parent-id "$IMAGE_PARENT" \
    --boot-disk-managed-disk-size-gibibytes "$DISK_GB" \
    --boot-disk-managed-disk-name "${NAME}-boot" \
    --network-interfaces "[{\"name\":\"eth0\",\"subnet_id\":\"${SUBNET_ID}\",\"ip_address\":{},\"public_ip_address\":{\"static\":false}}]" \
    --cloud-init-user-data "${CLOUD_INIT}"

  # discover instance id by name
  INSTANCE_ID=$("$NEBIUS" compute instance list --parent-id "$PROJECT_ID" 2>&1 | \
    awk -v n="$NAME" '/^      id: computeinstance-/{id=$2} /^      name: /{if($2==n){print id; exit}}')

  if [ -z "$INSTANCE_ID" ]; then
    echo "[fleet]   WARNING: could not auto-discover id for $NAME — check console" >&2
    continue
  fi

  PUBLIC_IP=$("$NEBIUS" compute instance get --id "$INSTANCE_ID" 2>&1 | \
    awk '/^status:/{f=1} f && /public_ip_address:/{p=1} p && /address:/{gsub("/32",""); print $2; exit}')

  echo "[fleet]   id=$INSTANCE_ID  ip=$PUBLIC_IP"
  echo "$i,$INSTANCE_ID,$PUBLIC_IP,$KEY_DIR/${NAME}.pem" >> nodes.csv
done

echo "----------------------------------------"
if [ "$SUBMIT" -eq 1 ]; then
  echo "[fleet] DONE. $FLEET_SIZE shards in nodes.csv. Meter is RUNNING."
  echo "[fleet] Next: bash dispatch.sh attendees.csv > shard-assignments.csv"
  echo "[fleet] When done: bash teardown-fleet.sh"
else
  echo "[fleet] dry-run complete. Re-run with --submit when ready."
fi
