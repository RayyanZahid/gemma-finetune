#!/usr/bin/env bash
# Round-robin assign attendees to shards, emit ssh commands.
#
# Input: attendees.csv with columns (email,name) — order doesn't matter
# Reads nodes.csv (written by provision-fleet.sh)
# Output: shard-assignments.csv with (email,name,shard,ssh_command)
#
# Usage:  bash dispatch.sh attendees.csv > shard-assignments.csv

set -euo pipefail

ATTENDEES="${1:?usage: dispatch.sh attendees.csv}"
NODES="${NODES_CSV:-nodes.csv}"

if [ ! -f "$ATTENDEES" ]; then
  echo "FATAL: attendees file not found: $ATTENDEES" >&2; exit 1
fi
if [ ! -f "$NODES" ]; then
  echo "FATAL: nodes.csv not found. Run provision-fleet.sh --submit first." >&2; exit 1
fi

# load nodes (skip header)
mapfile -t NODE_LINES < <(tail -n +2 "$NODES")
if [ "${#NODE_LINES[@]}" -eq 0 ]; then
  echo "FATAL: nodes.csv has no rows" >&2; exit 1
fi

NODE_COUNT="${#NODE_LINES[@]}"
echo "email,name,shard,ssh_command"

# read attendees, skip header if present
i=0
while IFS=, read -r email name rest; do
  # skip header
  if [ "$i" -eq 0 ] && echo "$email" | grep -qi "^email"; then
    i=$((i+1)); continue
  fi
  shard_idx=$(( (i - 1) % NODE_COUNT ))
  IFS=, read -r shard inst ip key <<< "${NODE_LINES[$shard_idx]}"
  # explicit ./ so PowerShell finds the key in CWD (it won't on bare basename)
  key_basename=$(basename "$key")
  ssh_cmd="ssh -i ./$key_basename -o StrictHostKeyChecking=no ubuntu@$ip"
  printf '%s,%s,%s,%s\n' "$email" "$name" "$shard" "$ssh_cmd"
  i=$((i+1))
done < "$ATTENDEES"

echo "[dispatch] assigned $((i-1)) attendees across $NODE_COUNT shards" >&2
