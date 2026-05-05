#!/usr/bin/env bash
# Discover the Nebius IDs you need to provision the fleet.
# Writes a .env-shaped file to stdout. Pipe to .env.workshop:
#   bash discover.sh > .env.workshop
#
# Required: `nebius` CLI installed + `nebius profile create` already done.

set -euo pipefail

NEBIUS="${NEBIUS:-$HOME/.nebius/bin/nebius}"
if ! [ -x "$NEBIUS" ] && ! command -v nebius >/dev/null; then
  echo "FATAL: nebius CLI not found at $NEBIUS or on PATH." >&2
  echo "Install: curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash" >&2
  exit 1
fi
NEBIUS=$(command -v nebius || echo "$NEBIUS")

# ---- project ----------------------------------------------------------------
PROJECT_ID=$("$NEBIUS" iam project list 2>&1 | awk '/^      id: /{print $2; exit}')
if [ -z "$PROJECT_ID" ]; then
  echo "FATAL: could not discover project id. Run 'nebius iam whoami' to verify auth." >&2
  exit 1
fi

# ---- subnet -----------------------------------------------------------------
SUBNET_ID=$("$NEBIUS" vpc subnet list --parent-id "$PROJECT_ID" 2>&1 | \
  awk '/^      id: vpcsubnet-/{id=$2} /^      state: READY/{print id; exit}')
if [ -z "$SUBNET_ID" ]; then
  echo "FATAL: could not find a READY subnet in project $PROJECT_ID." >&2
  exit 1
fi

# ---- emit ------------------------------------------------------------------
cat <<EOF
PROJECT_ID=$PROJECT_ID
SUBNET_ID=$SUBNET_ID
PLATFORM=gpu-h100-sxm
PRESET=1gpu-16vcpu-200gb
IMAGE_FAMILY=mk8s-worker-node-v-1-33-ubuntu24.04-cuda12.8

# Optional overrides
DISK_GB=200
IMAGE_PARENT=project-e00public-images
FLEET_SIZE=9
INSTANCE_PREFIX=workshop
EOF
