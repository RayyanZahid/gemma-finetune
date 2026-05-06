#!/usr/bin/env bash
# 6:30pm one-command workshop kickoff.
#
# Tears down ic-experiment-1, provisions a 10-node H100 fleet, bootstraps
# everything in parallel, smoke-tests one shard, generates ASSIGNMENTS.md.
#
# Run in WSL. Defaults to dry-run preview; add --submit for the real fleet.
#
# Required env: PROJECT_ID, SUBNET_ID (in .env.workshop)
# Optional: FLEET_SIZE (10), ATTENDEE_COUNT (80), EXPERIMENT_INSTANCE_ID

set -uo pipefail

cd "$(dirname "$0")"   # workshop/

SUBMIT=0
for arg in "$@"; do
  case "$arg" in
    --submit) SUBMIT=1 ;;
    --dry-run) SUBMIT=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "[run] unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---- env --------------------------------------------------------------------
if [ -f .env.workshop ]; then
  # shellcheck disable=SC1091
  source .env.workshop
fi

: "${PROJECT_ID:?PROJECT_ID not set — run 'bash discover.sh > .env.workshop' first}"
: "${SUBNET_ID:?SUBNET_ID not set}"

FLEET_SIZE="${FLEET_SIZE:-10}"
ATTENDEE_COUNT="${ATTENDEE_COUNT:-80}"
INSTANCE_PREFIX="${INSTANCE_PREFIX:-workshop}"
EXPERIMENT_INSTANCE_ID="${EXPERIMENT_INSTANCE_ID:-computeinstance-e00dfq6gmmy8xf96gh}"
NEBIUS="${NEBIUS:-$HOME/.nebius/bin/nebius}"

START=$(date +%s)
banner() {
  echo ""
  echo "================================================================"
  echo "  $*"
  echo "================================================================"
}

if [ "$SUBMIT" -eq 0 ]; then
  banner "DRY-RUN — no instances will be touched"
  echo "Would do:"
  echo "  1. Teardown ic-experiment-1 ($EXPERIMENT_INSTANCE_ID)"
  echo "  2. Provision $FLEET_SIZE × H100 (workshop-1..$FLEET_SIZE)"
  echo "  3. Bootstrap all $FLEET_SIZE in parallel (~10 min)"
  echo "  4. Smoke-test shard 1 (~3 min)"
  echo "  5. Generate ASSIGNMENTS.md for $ATTENDEE_COUNT attendees"
  echo "  6. Commit + push to RayyanZahid/gemma-finetune"
  echo ""
  echo "Cost estimate: ~\$$(awk "BEGIN{printf \"%.2f\", $FLEET_SIZE * 2.95 * 3}") for 3 hours of $FLEET_SIZE H100s"
  echo ""
  echo "Re-run with --submit when ready."
  exit 0
fi

# ---- 1. teardown experiment box ---------------------------------------------
banner "1/6  Teardown ic-experiment-1 (single H100 from earlier)"
"$NEBIUS" compute instance delete --id "$EXPERIMENT_INSTANCE_ID" 2>&1 | tail -3 || \
  echo "[run] experiment teardown returned non-zero — may already be gone"

sleep 3

# orphan boot disk
DISK_ID=$("$NEBIUS" compute disk list --parent-id "$PROJECT_ID" 2>&1 | \
  awk '/^      id: computedisk-/{id=$2} /^      name: ic-experiment-1-boot/{print id; exit}')
if [ -n "$DISK_ID" ]; then
  echo "[run] deleting experiment boot disk $DISK_ID..."
  "$NEBIUS" compute disk delete --id "$DISK_ID" 2>&1 | tail -3
fi

# ---- 2. provision fleet -----------------------------------------------------
banner "2/6  Provision $FLEET_SIZE × H100 fleet (sequential, ~5 min)"
PROJECT_ID="$PROJECT_ID" SUBNET_ID="$SUBNET_ID" \
  PLATFORM="${PLATFORM:-gpu-h100-sxm}" \
  PRESET="${PRESET:-1gpu-16vcpu-200gb}" \
  IMAGE_FAMILY="${IMAGE_FAMILY:-mk8s-worker-node-v-1-33-ubuntu24.04-cuda12.8}" \
  FLEET_SIZE="$FLEET_SIZE" INSTANCE_PREFIX="$INSTANCE_PREFIX" \
  bash provision-fleet.sh --submit

if [ ! -f nodes.csv ]; then
  echo "[run] FATAL: nodes.csv not produced — provision failed" >&2; exit 1
fi
PROVISIONED=$(($(wc -l < nodes.csv) - 1))
echo "[run] $PROVISIONED / $FLEET_SIZE shards provisioned"

# ---- 3. bootstrap fleet (parallel) ------------------------------------------
banner "3/6  Bootstrap all $PROVISIONED shards in parallel (~10 min)"
bash bootstrap-fleet.sh

# ---- 4. smoke-test shard 1 --------------------------------------------------
banner "4/6  Smoke-test shard 1 (fast: 50 samples, 1 epoch, ~3 min)"
SMOKE_IP=$(awk -F, '$1==1 {print $3}' nodes.csv)
SMOKE_KEY="$HOME/.ssh/workshop-1.pem"
cp keys/workshop-1.pem "$SMOKE_KEY"
chmod 600 "$SMOKE_KEY"

ssh -i "$SMOKE_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  ubuntu@"$SMOKE_IP" "cd ~/gemma-finetune && mkdir -p runs/fleet-smoke && \
  nohup bash -lc 'source ~/venv/bin/activate && python templates/finetune.py --user fleet-smoke --max-samples 50 --epochs 1 --max-eval-tokens 50 --out-dir runs/fleet-smoke' > runs/fleet-smoke/_stdout.log 2>&1 < /dev/null &
  sleep 1; echo smoke-launched"

echo "[run] smoke launched detached — output will appear in runs/fleet-smoke/_stdout.log on shard 1"

# ---- 5. generate ASSIGNMENTS.md --------------------------------------------
banner "5/6  Generate ASSIGNMENTS.md for $ATTENDEE_COUNT attendees"
ATTENDEE_COUNT="$ATTENDEE_COUNT" bash generate-assignments.sh > ../ASSIGNMENTS.md
WORDS=$(wc -w < ../ASSIGNMENTS.md)
echo "[run] ASSIGNMENTS.md written, $WORDS words"

# ---- 6. commit + push -------------------------------------------------------
banner "6/6  Commit + push ASSIGNMENTS.md to public repo"
cd ..
git add ASSIGNMENTS.md
git commit -q -m "TEMP: workshop assignments for May 5 (rotated after teardown)" || \
  echo "[run] nothing to commit"
git push -q origin master 2>&1 | tail -3 || \
  echo "[run] push failed — assignments saved locally"

# ---- summary ---------------------------------------------------------------
END=$(date +%s)
ELAPSED=$((END - START))
banner "READY. Fleet up, ASSIGNMENTS.md live."
echo "Elapsed: ${ELAPSED}s"
echo ""
echo "Public URL:  https://github.com/RayyanZahid/gemma-finetune/blob/master/ASSIGNMENTS.md"
echo "Cost meter:  $FLEET_SIZE × \$2.95/hr starting now"
echo ""
echo "At workshop end (9:30pm-ish), run:"
echo "  bash workshop/teardown-fleet.sh"
echo "Then commit a removal of ASSIGNMENTS.md from master."
