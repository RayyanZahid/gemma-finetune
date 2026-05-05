# Workshop Co-Host Runbook — 9× H100 Pool for ~72 Attendees

**Event:** Immersive Commons · *Fine-Tune Gemma 4 on Your Data* · Tue May 5 2026 · 7-9pm PT · Frontier Tower 10F
**Co-hosts:** Rayyan Zahid · Eric Mockler

This runbook is the operator's view: how the 9-node H100 fleet gets provisioned, how 72 attendees get dispatched onto it, and how it gets torn down at 9:30pm sharp so the meter stops.

> **Status of this runbook:** dry-run only. `provision-fleet.sh` defaults to `--dry-run`. Add `--submit` only when you're ready to burn ~$53 of compute over the next 2 hours.

---

## What we're building

| Layer | Count | What it is |
|---|---|---|
| Nebius H100 SXM nodes | 9 | Each is a `gpu-h100-sxm / 1gpu-16vcpu-200gb` Ubuntu 24.04 + CUDA 12.8 box |
| SSH keys | 9 | One `workshop-N.pem` per node — shared across the 8 attendees on that shard |
| Attendees | 72 | 8 per node. Run their own coding agent from their laptop, agent SSHes in |
| Cost | ~$53 | 9 × $2.95/hr × 2 hours of on-demand. Add ~$0.50 for boot disks |

**Why one SSH key per node, not 72 individual keys.** 72 keypairs is a logistics nightmare 3 hours before doors. One key per shard is "good enough" isolation — attendees scope by `runs/<their-name>/` and `models/<their-name>/`, which the workshop's `TASK.md` enforces. If anyone rm -rfs anyone else's work mid-event, the fix is faster than the prevention would have been.

**Why 9 nodes, not 4 or 12.** Math: Gemma 4 E4B QLoRA needs ~10GB VRAM per kernel. H100 has 80GB. 80/10 = 8 concurrent kernels per box. 72/8 = 9 boxes. Anything fewer means a queue eating the workshop window.

---

## Phases

```
  T-3h (4pm)    bootstrap Nebius CLI in WSL          (one-time, ~5 min, free)
  T-3h          discover IDs (project, subnet, etc.)  (~1 min, free)
  T-2.5h        generate 9 SSH keypairs               (~30 sec, free)
  T-2.5h        provision-fleet.sh --dry-run          (preview, free)
  T-2h (5pm)    provision-fleet.sh --submit           (~5 min, METER STARTS, ~$0.20)
  T-1.5h        smoke-test one node end-to-end        (~10 min, ~$0.50)
  T-1h (6pm)    dispatch SSH credentials to attendees (~5 min, free)
  T+0  (7pm)    workshop runs                         (~2 hr, ~$53)
  T+2h (9pm)    workshop wraps                        
  T+2.5h(9:30)  teardown-fleet.sh                     (~30 sec, METER STOPS)
```

Total elapsed: 5.5 hours. Total cost (warm fleet): **~$54**.

---

## Phase 1 — Bootstrap the Nebius CLI in WSL (one-time, ~5 min)

```bash
# inside WSL2 Ubuntu (this is `rayyan@Alienwarem16` per your machine)
curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash
exec $SHELL  # reload PATH so `nebius` is on it
nebius version

# OAuth — opens a browser, sign in with the same Google account you use at console.nebius.com
nebius profile create default \
  --endpoint api.nebius.cloud \
  --federation-endpoint auth.nebius.com

nebius iam whoami   # should print your email + tenants list
```

If the CLI is already installed (Ray's WSL had it during the May 1 dry-run), skip to discovery.

---

## Phase 2 — Discover (one-time per project, ~1 min)

Run `discover.sh` to capture the IDs you need:

```bash
bash discover.sh > .env.workshop
cat .env.workshop
```

You should see five env vars, each with a real value:

```bash
PROJECT_ID=project-e00...
SUBNET_ID=vpcsubnet-e00...
PLATFORM=gpu-h100-sxm
PRESET=1gpu-16vcpu-200gb
IMAGE_FAMILY=mk8s-worker-node-v-1-33-ubuntu24.04-cuda12.8
```

**If `discover.sh` fails to find a value,** read the manual fallback in [`../nebius-gpu/SKILL.md` § 2 Discover](../nebius-gpu/SKILL.md). Each value is a one-liner away.

---

## Phase 3 — Generate the 9 SSH keypairs (~30 sec)

```bash
bash generate-keys.sh
ls keys/
# workshop-1.pem  workshop-1.pem.pub
# workshop-2.pem  workshop-2.pem.pub
# ...
# workshop-9.pem  workshop-9.pem.pub
```

These are the keys attendees on each shard will use. The `.pem` is the private key (never leaves this folder until dispatch), the `.pub` gets baked into the node via cloud-init.

---

## Phase 4 — Dry-run provisioning (free)

```bash
source .env.workshop
bash provision-fleet.sh --dry-run
```

Output: prints what it would do, for each of the 9 nodes. No instances created, no money spent. **Read it carefully** — verify the platform, preset, image family, and SSH key paths are what you want.

---

## Phase 5 — The actual provision (~5 min, METER STARTS, ~$0.20)

```bash
bash provision-fleet.sh --submit
```

Provisions 9 nodes sequentially. Each takes ~30s; full fleet up in ~5 minutes. The script writes `nodes.csv`:

```csv
shard,instance_id,public_ip,ssh_key
1,computeinstance-e00abc...,5.188.42.10,keys/workshop-1.pem
2,computeinstance-e00def...,5.188.42.22,keys/workshop-2.pem
...
9,computeinstance-e00xyz...,5.188.42.99,keys/workshop-9.pem
```

Once `nodes.csv` is written, **the meter is running** at $26.55/hr ($2.95 × 9). Tear down promptly.

---

## Phase 6 — Smoke-test one node (~10 min, ~$0.50)

Before sending 72 attendees at it, prove one node works end-to-end. Eric runs this from his laptop:

```bash
# pick the first shard
KEY=keys/workshop-1.pem
IP=$(awk -F, '$1==1 {print $3}' nodes.csv)

ssh -i $KEY -o StrictHostKeyChecking=no ubuntu@$IP \
  'nvidia-smi --query-gpu=name,memory.total --format=csv'
# expect: NVIDIA H100 80GB HBM3, 81920 MiB

# kick a fast smoke fine-tune
scp -i $KEY ../templates/finetune.py ubuntu@$IP:~/
ssh -i $KEY ubuntu@$IP bash <<'REMOTE'
sudo apt-get install -y python3-dev build-essential 2>&1 | tail -3
python3 -m venv ~/venv && source ~/venv/bin/activate
pip install -q unsloth trl peft datasets bitsandbytes accelerate
python finetune.py --model unsloth/gemma-4-E4B-it --max-steps 5 --out runs/smoke
REMOTE
```

If that returns *"5/5 prompts shifted"* (or any compare.md output), the recipe runs on this hardware. Replicate the smoke step on at least nodes 2 and 9 for variance.

---

## Phase 7 — Dispatch attendees to shards (~5 min)

You have a CSV of 72 RSVPs (download from Luma → CSV export). Run:

```bash
bash dispatch.sh attendees.csv > shard-assignments.csv
head shard-assignments.csv
# attendee_email,attendee_name,shard,ssh_command
# alice@example.com,Alice,1,ssh -i workshop-1.pem ubuntu@5.188.42.10
# bob@example.com,Bob,1,ssh -i workshop-1.pem ubuntu@5.188.42.10
# ...
```

Each attendee gets a Luma DM (or door handout):
1. Their `ssh_command` line
2. The matching `workshop-N.pem` (attached or via signed URL)
3. The repo URL: `https://github.com/RayyanZahid/gemma-finetune` for the recipe

Round-robin assignment is fine. If you want to balance by self-declared experience level (RSVP tags), tweak the CSV before running dispatch.

---

## Phase 8 — Workshop runs (~2 hr, ~$53)

Eric drives the live demo on shard 1. Ray walks the room. Attendees' coding agents do the work. Common failures and how to coach:

| Failure | Symptom | Coach with |
|---|---|---|
| OOM mid-train | `CUDA out of memory` | "Drop to E2B or rank 4. The H100 is shared 8-ways = 10GB per kernel." |
| Skipped baseline | compare.md only has tuned outputs | "Re-brief: baseline first, otherwise the tune is unfalsifiable." |
| No adapter saved | `models/` empty after train | "Check `model.save_pretrained(path)` is called after training." |
| Adapter saved but inference identical | Outputs look the same | "Make sure inference loads `base + adapter`, not just base." |
| Path drift | Files in `/tmp` or `~` | "Anchor your agent to `~/ic-fine-tune-gemma4/runs/<name>/`." |
| Tokenization garbage | Loss never drops | "Apply Gemma's chat template — see SKILL.md § 3." |
| Shared-VM cleanup churn | Agent tries to rm to recover | "Tell it never to delete. Snapshot/checkpoint instead." |

**Eric's golden rule**: at any failure, walk over physically. Faster than DMs.

---

## Phase 9 — Teardown (~30 sec, MANDATORY)

```bash
bash teardown-fleet.sh
```

Deletes all 9 instances + their boot disks. Verify the meter stopped:

```bash
nebius compute instance list --parent-id $PROJECT_ID | grep workshop-
# should print nothing
```

If anything survives, the script will warn and exit non-zero. **Run it again until it's clean.** A forgotten H100 is $70/day.

---

## Cost ladder

| Phase | Time | Cost |
|---|---|---|
| Bootstrap + discover | 6 min | $0 |
| Provision (9 sequential) | 5 min | $0.20 |
| Smoke-test (3 nodes) | 10 min | $1.50 |
| Workshop window (full fleet at 8-way) | 120 min | $53 |
| Teardown | 30 sec | $0 |
| **Total** | **~140 min** | **~$54.70** |

Add ~$0.20-0.50 if any boot disks survive past teardown — the script catches them but verify in console.

---

## Failure recovery

**Provision-fleet partial failure** (e.g. 6 of 9 came up, 3 errored): the script writes `nodes.csv` for the ones that succeeded. Re-run with `--submit --start-shard 7` to provision just shards 7-9.

**Mid-workshop node death**: the orphaned shard's 8 attendees migrate to the least-loaded other shard. Cap your most-loaded shard at 12 — beyond that, queue time blows up.

**Wifi gets congested**: the FT10 wifi has been the bottleneck twice this year. Backup hotspot lives in Ray's bag. Eric's instructor laptop should be on the hotspot, not the FT wifi.

**Doors-open and shards aren't ready**: spin attendees up on the BYO Nebius pattern (skill's [§ Pattern C](../SKILL.md#pattern-c-multi-attendee-workshop)). They each create their own free-tier H100 from scratch in ~5 min. Ugly but recoverable.

---

## Files in this folder

- [`README.md`](README.md) — this runbook
- [`discover.sh`](discover.sh) — captures Nebius project/subnet/platform IDs into `.env.workshop`
- [`generate-keys.sh`](generate-keys.sh) — makes 9 SSH keypairs in `keys/`
- [`provision-fleet.sh`](provision-fleet.sh) — provisions all 9 nodes (defaults to `--dry-run`)
- [`teardown-fleet.sh`](teardown-fleet.sh) — deletes all 9 nodes + boot disks
- [`dispatch.sh`](dispatch.sh) — assigns RSVPs to shards, writes ssh commands
- [`.env.template`](.env.template) — env var skeleton, copy to `.env.workshop` and fill

---

*Authored T-3h (2026-05-05). Lock and execute by T-2h.*
