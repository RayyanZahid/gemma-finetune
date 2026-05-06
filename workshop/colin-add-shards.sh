#!/usr/bin/env bash
# colin-add-shards.sh — co-host one-command shard addition for the IC Gemma 4 workshop.
#
# Provisions N additional H100 SXM nodes on YOUR Nebius account (separate
# tenant from Ray's, so the public-IP quota is YOUR quota), bootstraps each,
# and prints a markdown snippet that Ray pastes into ASSIGNMENTS.md.
#
# Run on Mac or Linux (or WSL2 on Windows).
#
# Usage:
#   bash colin-add-shards.sh <count> [--start-shard N]
#
# Examples:
#   bash colin-add-shards.sh 3                   # 3 shards numbered 4,5,6 (default)
#   bash colin-add-shards.sh 2 --start-shard 5   # 2 shards numbered 5,6
#
# When done: copy the markdown block from stdout, DM/Slack/text it to Ray.
# Ray pastes it into ASSIGNMENTS.md and commits.

set -euo pipefail

# ---- args ------------------------------------------------------------------
COUNT="${1:-}"
START_SHARD=4
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --start-shard) START_SHARD=$2; shift 2 ;;
    --start-shard=*) START_SHARD="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "[colin] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: bash $0 <count> [--start-shard N]" >&2
  echo "  <count> must be a positive integer." >&2
  exit 2
fi

USER_PREFIX=$(whoami | tr -cd '[:alnum:]')
INSTANCE_PREFIX="ws-${USER_PREFIX}"
END_SHARD=$((START_SHARD + COUNT - 1))

cd "$(dirname "$0")"
mkdir -p keys
chmod 700 keys

banner() { echo ""; echo "================================================================"; echo "  $*"; echo "================================================================"; }

# ---- 1. Nebius CLI check ---------------------------------------------------
banner "1/5  Verifying Nebius CLI"
NEBIUS=""
if command -v nebius >/dev/null 2>&1; then
  NEBIUS=$(command -v nebius)
elif [ -x "$HOME/.nebius/bin/nebius" ]; then
  NEBIUS="$HOME/.nebius/bin/nebius"
else
  echo "[colin] Nebius CLI not found. Installing..."
  curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash
  NEBIUS="$HOME/.nebius/bin/nebius"
fi
echo "[colin] using $NEBIUS"
"$NEBIUS" version

if ! "$NEBIUS" iam whoami >/dev/null 2>&1; then
  echo ""
  echo "[colin] not authed. Run this once, complete OAuth in your browser:"
  echo "    $NEBIUS profile create default --endpoint api.nebius.cloud --federation-endpoint auth.nebius.com"
  echo "Then re-run me."
  exit 1
fi
WHO=$("$NEBIUS" iam whoami 2>&1 | awk '/email:/{print $2; exit}')
echo "[colin] authed as $WHO"

# ---- 2. Discover IDs --------------------------------------------------------
banner "2/5  Discovering Nebius project + subnet"
TENANT=$("$NEBIUS" iam whoami 2>&1 | awk '/tenant_id:/{print $2; exit}')
PROJECT_ID=$("$NEBIUS" iam project list --parent-id "$TENANT" 2>&1 | \
  awk '/^      id: project-/{id=$2} /^      name: default-project-eu-north1/{print id; exit}')
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$("$NEBIUS" iam project list --parent-id "$TENANT" 2>&1 | \
    awk '/^      id: project-/{print $2; exit}')
fi
SUBNET_ID=$("$NEBIUS" vpc subnet list --parent-id "$PROJECT_ID" 2>&1 | \
  awk '/^      id: vpcsubnet-/{id=$2} /^      state: READY/{print id; exit}')

echo "[colin] tenant:  $TENANT"
echo "[colin] project: $PROJECT_ID"
echo "[colin] subnet:  $SUBNET_ID"
[ -z "$PROJECT_ID" ] && { echo "FATAL: no project found"; exit 1; }
[ -z "$SUBNET_ID"  ] && { echo "FATAL: no READY subnet found"; exit 1; }

# ---- 3. Generate keypairs --------------------------------------------------
banner "3/5  Generating $COUNT SSH keypairs"
for i in $(seq "$START_SHARD" "$END_SHARD"); do
  KEY="keys/${INSTANCE_PREFIX}-${i}.pem"
  if [ ! -f "$KEY" ]; then
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "${INSTANCE_PREFIX}-${i}@ic-workshop" -q
    chmod 600 "$KEY"
    echo "[colin] generated $KEY"
  fi
done

# ---- 4. Provision sequentially ---------------------------------------------
banner "4/5  Provisioning $COUNT H100s (this takes ~$((COUNT * 30))s sequentially)"
for i in $(seq "$START_SHARD" "$END_SHARD"); do
  NAME="${INSTANCE_PREFIX}-${i}"
  PUB=$(cat "keys/${NAME}.pem.pub")

  CLOUD_INIT="#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUB
ssh_authorized_keys:
  - $PUB
"
  echo "[colin] creating $NAME..."
  "$NEBIUS" compute instance create \
    --parent-id "$PROJECT_ID" \
    --name "$NAME" \
    --resources-platform gpu-h100-sxm \
    --resources-preset 1gpu-16vcpu-200gb \
    --boot-disk-attach-mode READ_WRITE \
    --boot-disk-managed-disk-type NETWORK_SSD \
    --boot-disk-managed-disk-source-image-family-image-family mk8s-worker-node-v-1-33-ubuntu24.04-cuda12.8 \
    --boot-disk-managed-disk-source-image-family-parent-id project-e00public-images \
    --boot-disk-managed-disk-size-gibibytes 200 \
    --boot-disk-managed-disk-name "${NAME}-boot" \
    --network-interfaces "[{\"name\":\"eth0\",\"subnet_id\":\"${SUBNET_ID}\",\"ip_address\":{},\"public_ip_address\":{\"static\":false}}]" \
    --cloud-init-user-data "$CLOUD_INIT" 2>&1 | tail -3
done

# ---- 5. Discover IPs + bootstrap in parallel + emit markdown ---------------
banner "5/5  Discovering IPs + bootstrapping in parallel"
sleep 5

declare -A IPS
declare -A IDS
for i in $(seq "$START_SHARD" "$END_SHARD"); do
  NAME="${INSTANCE_PREFIX}-${i}"
  ID=$("$NEBIUS" compute instance list --parent-id "$PROJECT_ID" 2>&1 | \
    awk -v n="$NAME" '/^      id: computeinstance-/{id=$2} /^      name: /{if($2==n){print id; exit}}')
  IDS[$i]=$ID
  IP=""
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    IP=$("$NEBIUS" compute instance get --id "$ID" 2>&1 | awk '
      /^status:/ {f=1; next}
      f && /public_ip_address:/ {p=1; next}
      p && /^[[:space:]]+address:/ { gsub("/32","",$2); print $2; exit }
    ')
    if [ -n "$IP" ]; then break; fi
    echo "[colin] waiting for $NAME IP (attempt $attempt/12)..."
    sleep 8
  done
  IPS[$i]=$IP
  echo "[colin] $NAME ip=$IP"
done

# Parallel bootstrap
echo "[colin] bootstrapping all $COUNT in parallel (~7-10 min)..."
PIDS=()
for i in $(seq "$START_SHARD" "$END_SHARD"); do
  IP="${IPS[$i]}"
  KEY="keys/${INSTANCE_PREFIX}-${i}.pem"
  WSL_KEY="$HOME/.ssh/${INSTANCE_PREFIX}-${i}.pem"
  mkdir -p "$HOME/.ssh"
  cp "$KEY" "$WSL_KEY"
  chmod 600 "$WSL_KEY"
  LOG="_colin-bootstrap-${i}.log"
  (
    SSH="ssh -i $WSL_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o LogLevel=ERROR ubuntu@$IP"
    {
      echo "==== shard $i / $IP ===="
      $SSH 'sudo cloud-init status --wait 2>&1 | tail -2' || true
      $SSH "curl -sSL https://raw.githubusercontent.com/RayyanZahid/gemma-finetune/master/workshop/bootstrap.sh | bash 2>&1"
    } > "$LOG" 2>&1
  ) &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do wait "$pid" || echo "[colin] one bootstrap returned non-zero (see _colin-bootstrap-*.log)"; done
echo "[colin] all bootstraps done."

# ---- emit markdown snippet -------------------------------------------------
banner "DONE — copy this markdown block and send to Ray"

cat <<EOF

\`\`\`md
<!-- BEGIN COLIN-PROVISIONED SHARDS — paste into ASSIGNMENTS.md -->

EOF

for i in $(seq "$START_SHARD" "$END_SHARD"); do
  IP="${IPS[$i]}"
  KEY_FILE="keys/${INSTANCE_PREFIX}-${i}.pem"
  cat <<SHARD

### Shard $i — Colin's H100 (overflow)

**SSH:** \`ssh -i ~/.ssh/ic-shard-${i}.pem ubuntu@${IP}\`
**Output dir:** \`runs/attendee-N/\`

Save this private key as \`~/.ssh/ic-shard-${i}.pem\`, then \`chmod 600 ~/.ssh/ic-shard-${i}.pem\`:

\`\`\`
$(cat "$KEY_FILE")
\`\`\`
SHARD
done

cat <<'EOF'

<!-- END COLIN-PROVISIONED SHARDS -->
```

EOF

echo ""
echo "Send the block above to Ray. He pastes it into the bottom of ASSIGNMENTS.md."
echo ""
echo "When the workshop ends, run:"
echo "  bash colin-teardown.sh   # tears down everything you provisioned"
