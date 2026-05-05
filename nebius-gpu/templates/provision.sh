#!/usr/bin/env bash
# Generic Nebius GPU provision template.
#
# Required env vars (set before running):
#   PROJECT_ID      e.g. project-e00g0tvwpr00bsmthbv05w
#   SUBNET_ID       e.g. vpcsubnet-e00mqv55h1a4t84hyx
#   PLATFORM        e.g. gpu-h100-sxm | gpu-h200-sxm | gpu-l40s-d
#   PRESET          e.g. 1gpu-16vcpu-200gb
#   IMAGE_FAMILY    e.g. mk8s-worker-node-v-1-33-ubuntu24.04-cuda12.8
#   INSTANCE_NAME   e.g. my-experiment   (lowercase, hyphens)
#   SSH_PUBKEY      contents of ~/.ssh/id_ed25519.pub (or your preferred key)
#
# Optional:
#   DISK_GB         default 200
#   IMAGE_PARENT    default project-e00public-images
#
# After success: capture the printed instance ID and proceed to run.sh / teardown.sh.

set -euo pipefail

# ---- validate ---------------------------------------------------------------
for var in PROJECT_ID SUBNET_ID PLATFORM PRESET IMAGE_FAMILY INSTANCE_NAME SSH_PUBKEY; do
  if [ -z "${!var:-}" ]; then
    echo "FATAL: \$$var is required. Set it and re-run." >&2
    echo "(See SKILL.md § Discover for how to find each value.)" >&2
    exit 1
  fi
done

DISK_GB="${DISK_GB:-200}"
IMAGE_PARENT="${IMAGE_PARENT:-project-e00public-images}"
NEBIUS="${NEBIUS:-$HOME/.nebius/bin/nebius}"

# ---- cloud-init -------------------------------------------------------------
# Sets the SSH key on both the default `ubuntu` user and root.
CLOUD_INIT=$(cat <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBKEY}
ssh_authorized_keys:
  - ${SSH_PUBKEY}
EOF
)

# ---- create -----------------------------------------------------------------
echo "[provision] creating $INSTANCE_NAME ($PLATFORM/$PRESET, ${DISK_GB}GB, $IMAGE_FAMILY)..."
"$NEBIUS" compute instance create \
  --parent-id "$PROJECT_ID" \
  --name "$INSTANCE_NAME" \
  --resources-platform "$PLATFORM" \
  --resources-preset "$PRESET" \
  --boot-disk-attach-mode READ_WRITE \
  --boot-disk-managed-disk-type NETWORK_SSD \
  --boot-disk-managed-disk-source-image-family-image-family "$IMAGE_FAMILY" \
  --boot-disk-managed-disk-source-image-family-parent-id "$IMAGE_PARENT" \
  --boot-disk-managed-disk-size-gibibytes "$DISK_GB" \
  --boot-disk-managed-disk-name "${INSTANCE_NAME}-boot" \
  --network-interfaces "[{\"name\":\"eth0\",\"subnet_id\":\"${SUBNET_ID}\",\"ip_address\":{},\"public_ip_address\":{\"static\":false}}]" \
  --cloud-init-user-data "${CLOUD_INIT}"

# ---- discover IP ------------------------------------------------------------
INSTANCE_ID=$("$NEBIUS" compute instance list --parent-id "$PROJECT_ID" 2>&1 | \
  awk -v n="$INSTANCE_NAME" '/^      id: computeinstance-/{id=$2} /^      name: /{if($2==n){print id; exit}}')

if [ -z "$INSTANCE_ID" ]; then
  echo "[provision] WARNING: couldn't auto-find instance id by name; check dashboard." >&2
  exit 0
fi

echo "[provision] INSTANCE_ID=$INSTANCE_ID"

PUBLIC_IP=$("$NEBIUS" compute instance get --id "$INSTANCE_ID" 2>&1 | \
  awk '/^status:/{f=1} f && /public_ip_address:/{p=1} p && /address:/{gsub("/32",""); print $2; exit}')

echo "[provision] PUBLIC_IP=$PUBLIC_IP"
echo
echo "Next steps:"
echo "  export INSTANCE_ID=$INSTANCE_ID"
echo "  export PUBLIC_IP=$PUBLIC_IP"
echo "  bash run.sh <your-script.py>     # SCP + execute"
echo "  bash teardown.sh                 # MANDATORY when done"
