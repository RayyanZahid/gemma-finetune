#!/usr/bin/env bash
# Generate ASSIGNMENTS.md — the door-time manifest mapping attendee numbers
# 1..N to shards, with embedded SSH keys + commands.
#
# Reads nodes.csv (from provision-fleet.sh).
# Block-distributes ATTENDEE_COUNT slots across the shards (8 per shard).
#
# Required: nodes.csv, workshop/keys/workshop-N.pem
# Optional: ATTENDEE_COUNT (default 80), KEY_DIR (default keys), VENUE
#
# Usage:  bash generate-assignments.sh > ../ASSIGNMENTS.md

set -uo pipefail

NODES="${NODES_CSV:-nodes.csv}"
KEY_DIR="${KEY_DIR:-keys}"
ATTENDEE_COUNT="${ATTENDEE_COUNT:-80}"
PER_SHARD="${PER_SHARD:-8}"
VENUE="${VENUE:-Frontier Tower, Floor 16}"
EVENT_NAME="${EVENT_NAME:-Fine-Tune Gemma 4 on Your Data}"
EVENT_TIME="${EVENT_TIME:-Sat Aug 22 2026, 7:30pm PT}"

if [ ! -f "$NODES" ]; then
  echo "FATAL: nodes.csv not found. Run provision-fleet.sh --submit first." >&2; exit 1
fi

# Load nodes (skip header)
mapfile -t NODE_LINES < <(tail -n +2 "$NODES")
NODE_COUNT="${#NODE_LINES[@]}"
if [ "$NODE_COUNT" -eq 0 ]; then
  echo "FATAL: nodes.csv has no shards" >&2; exit 1
fi

CAP=$((NODE_COUNT * PER_SHARD))
if [ "$ATTENDEE_COUNT" -gt "$CAP" ]; then
  echo "FATAL: $ATTENDEE_COUNT attendees > $CAP capacity ($NODE_COUNT shards × $PER_SHARD)" >&2; exit 1
fi

# ---- header -----------------------------------------------------------------
cat <<EOF
# IC Workshop — Attendee Assignments

**Event:** $EVENT_NAME
**When:** $EVENT_TIME
**Where:** $VENUE
**Capacity:** $ATTENDEE_COUNT attendees across $NODE_COUNT H100 shards
**Repo:** https://github.com/RayyanZahid/gemma-finetune
**Briefing:** [TASK.md](TASK.md)

> **Important:** SSH keys below are temporary. The H100 fleet vanishes at teardown
> (~9:30pm PT). Don't share outside this workshop. After teardown, this file is
> rotated out of the repo.

---

## How to use this page

1. Find your number (you got it at the door — written on your name tag).
2. Look up your shard in the table below.
3. Copy your shard's SSH command + private key.
4. Save the key as \`~/.ssh/ic-shard-N.pem\` and \`chmod 600\` it.
5. Open your coding agent (Claude Code, Cursor, Cline, Aider, anything).
6. Drop this prompt in:

\`\`\`
Read https://github.com/RayyanZahid/gemma-finetune/blob/master/TASK.md.
SSH into <YOUR-IP> as ubuntu using ~/.ssh/ic-shard-N.pem.
Run the workflow described in TASK.md. My output namespace is "attendee-X" (your number).
\`\`\`

The agent does the rest. Walk over to Eric or Ray if it stalls 5+ min.

---

## Number → Shard map

| Numbers | Shard | IP |
|---|---|---|
EOF

# Map block: attendees 1-8 on shard 1, 9-16 on shard 2, etc
i=1
for line in "${NODE_LINES[@]}"; do
  IFS=, read -r shard inst ip key <<< "$line"
  start=$(( (i - 1) * PER_SHARD + 1 ))
  end=$(( i * PER_SHARD ))
  if [ "$end" -gt "$ATTENDEE_COUNT" ]; then end=$ATTENDEE_COUNT; fi
  echo "| $start - $end | $shard | $ip |"
  i=$((i + 1))
  if [ "$start" -gt "$ATTENDEE_COUNT" ]; then break; fi
done

cat <<'EOF'

---

## Shards

EOF

# ---- per-shard sections -----------------------------------------------------
i=1
for line in "${NODE_LINES[@]}"; do
  IFS=, read -r shard inst ip key <<< "$line"
  start=$(( (i - 1) * PER_SHARD + 1 ))
  end=$(( i * PER_SHARD ))
  if [ "$end" -gt "$ATTENDEE_COUNT" ]; then end=$ATTENDEE_COUNT; fi
  if [ "$start" -gt "$ATTENDEE_COUNT" ]; then break; fi

  KEY_FILE="$KEY_DIR/workshop-${shard}.pem"
  if [ ! -f "$KEY_FILE" ]; then
    echo "<!-- shard $shard: missing key $KEY_FILE -->"
    i=$((i + 1)); continue
  fi

  cat <<SHARD_HEADER
### Shard $shard — attendees $start to $end

**SSH:** \`ssh -i ~/.ssh/ic-shard-$shard.pem ubuntu@$ip\`
**Output dir:** \`runs/attendee-N/\` (replace N with your assigned number)

Save the following as \`~/.ssh/ic-shard-$shard.pem\`, then \`chmod 600 ~/.ssh/ic-shard-$shard.pem\`:

\`\`\`
SHARD_HEADER
  cat "$KEY_FILE"
  cat <<SHARD_FOOTER
\`\`\`

SHARD_FOOTER

  i=$((i + 1))
done

cat <<'EOF'
---

## Need help?

- Walk over to Ray (host) or Eric (technical demo).
- Common failures: see [TASK.md § Failure recovery](TASK.md#failure-recovery).
- The full recipe: [SKILL.md](SKILL.md), [CHECKLIST.md](CHECKLIST.md), [PITFALLS.md](PITFALLS.md).

*This page rotates after teardown (~9:30pm). Don't share with anyone outside the room.*
EOF
