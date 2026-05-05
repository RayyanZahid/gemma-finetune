---
name: nebius-gpu
description: Provision a GPU VM on Nebius AI Cloud, run a workload via SSH, then tear down cleanly. Use when user asks to "spin up a GPU on Nebius", "fine-tune on Nebius", "provision an H100/H200/L40S", or sets up Nebius for the first time. Cost-safe — every flow ends in mandatory teardown.
triggers: nebius, nebius gpu, nebius h100, nebius h200, nebius l40s, fine-tune nebius, spin up gpu, provision gpu, nebius cli, nebius profile create, nebius compute instance, delete nebius instance, teardown nebius, gpu workshop, ic workshop gpu, dry-run gpu
allowed-tools:
  - "Read"
  - "Write"
  - "Edit"
  - "Bash"
  - "Glob"
  - "Grep"
---

# nebius-gpu — Provision, Run, Teardown a GPU on Nebius AI Cloud

The user wants to rent a GPU (H100, H200, L40S) on Nebius for a workload — fine-tune, training run, inference benchmark, anything CUDA-bound — drive it from their terminal, get the result, and stop the meter.

**Cost-safety is non-negotiable.** Nebius bills by the second from instance creation until deletion. Every flow this skill produces ends with `teardown`. If a session ends without teardown, the user is paying for an idle GPU.

This skill encodes the working recipe Ray validated 2026-05-01 in WSL2 on Windows 11. Every flag, JSON shape, and image family below is what actually works — not what the docs imply.

Supporting files in this skill (read as needed):

- `CHECKLIST.md` — step-by-step from "I have a Nebius account" to "I have my output and the meter is stopped"
- `PITFALLS.md` — every error encountered during the v1 dry-run, with the exact fix
- `templates/provision.sh` — fill-in-the-blanks GPU instance creation
- `templates/run.sh` — SCP + SSH + execute wrapper (with PEP-668 handling for Ubuntu 24.04)
- `templates/teardown.sh` — mandatory cleanup (instance + boot disk)
- `templates/cloud-init.yaml` — SSH key + default-user setup

---

## When to Use

All of these:
1. The user has a Nebius AI Cloud account (or is willing to create one — link them to `console.nebius.com`).
2. The workload needs a GPU (CUDA, ML training, large-batch inference, video/audio codec).
3. The workload is short-lived (hours, not days). For long jobs, use Nebius's reserved instances or GPU clusters via Terraform — different skill.
4. The user is comfortable with SSH + a terminal. Browser-only attendees: walk them through the dashboard wizard instead and use this skill only for the discovery + teardown halves.

## When NOT to Use

- The workload runs fine on a laptop GPU or free-tier Colab. Don't burn paid compute for a 5-min validation — Colab T4 handles up to ~13B parameters at QLoRA.
- The user wants serverless / pay-per-token inference. Use Nebius **Token Factory** (different product, OpenAI-compatible API) — this skill is for raw IaaS GPU.
- The user wants Kubernetes / multi-node distributed training. Use Nebius's managed Kubernetes (`mk8s`) or Slurm (`Soperator`) — separate flows.
- One-off scraping, no GPU needed. Use a CPU box (`cpu-d3` preset) or stay local.

---

## The Four-Phase Loop

```
  1. Setup           → install CLI + create profile (one-time, ~5 min)
        |
        v
  2. Discover        → project, subnet, platform, preset, image (~1 min)
        |
        v
  3. Provision+Run   → create VM, SSH in, install deps, execute (~5-30 min)
        |
        v
  4. Teardown        → MANDATORY. delete instance + boot disk (~30 sec)
```

If any phase fails, **always run teardown before retrying.** A failed provision can leave an orphan boot disk that bills $0.08/GB/month.

---

## 1. Setup (one-time, ~5 min)

The `nebius` CLI is **Linux/Mac only**. Windows users need WSL2 (built into Windows 11; `wsl --install` if needed).

### Install

```bash
curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash
exec $SHELL  # reload PATH
nebius version
```

Binary lands at `~/.nebius/bin/nebius` and is added to `$PATH` via `~/.bashrc`. If `nebius version` doesn't work after `exec $SHELL`, call it via the full path: `~/.nebius/bin/nebius`.

### Create profile (browser OAuth)

```bash
nebius profile create default \
  --endpoint api.nebius.cloud \
  --federation-endpoint auth.nebius.com
```

CLI prints an OAuth URL. If a browser is available (WSLg, native Linux, Mac), it opens automatically. Otherwise the user copies the URL to a browser. Sign in with the **same Google account** used at `console.nebius.com`. CLI returns to terminal with `profile "default" configured and activated`.

For multi-tenant accounts, also pass `--parent-id <project-id>` to bind the profile to a specific project.

### Verify

```bash
nebius iam whoami
```

Should print `user_profile.attributes.email` and the user's `tenants[]` array. If it prints `missing configuration: open ~/.nebius/config.yaml: no such file or directory`, the profile create didn't complete — re-run.

---

## 2. Discover (one-time per project, ~1 min)

The user needs five values to provision: project ID, subnet ID, platform name, preset name, image family. All are discoverable.

### Project ID

Two ways:
- Browser: open `console.nebius.com`, the URL shows `console.nebius.com/project-<id>`. The `project-<id>` is the value you want.
- CLI: `nebius iam project list` returns it under each project's `metadata.id`.

Save as `PROJECT_ID` for later commands.

### Subnet ID

```bash
nebius vpc subnet list --parent-id $PROJECT_ID
```

Pick the one with `status.state: READY`, usually named `default-subnet-*`. Save as `SUBNET_ID`.

### Platform + preset

```bash
nebius compute platform list
```

Each platform has `name` (e.g. `gpu-h100-sxm`) and `spec.presets[].name` (e.g. `1gpu-16vcpu-200gb`). For workshop / experimentation, **smallest preset is almost always right** — `1gpu-*` for any GPU platform.

| Platform | Smallest preset | $/hr (on-demand) | Use case |
|---|---|---|---|
| `gpu-h100-sxm` | `1gpu-16vcpu-200gb` | ~$2.95 | Big training, frontier-model fine-tune |
| `gpu-h200-sxm` | `1gpu-16vcpu-200gb` | ~$3.50 | Same as H100 with more VRAM |
| `gpu-l40s-d` (AMD) | `1gpu-16vcpu-96gb` | ~$1.55 | Inference, smaller training, CV/diffusion |
| `gpu-l40s-a` (Intel) | `1gpu-8vcpu-32gb` | ~$1.82 | Same |
| `cpu-d3` | `4vcpu-16gb` | ~$0.08 | No-GPU dev/CI |

Preemptible variants (~50% off) exist via `--preemptible-on-preemption RESCHEDULE` but get killed on capacity pressure — fine for fault-tolerant jobs, bad for interactive workshops.

### Image family

```bash
nebius compute image list --parent-id project-e00public-images
```

Note: images live in the **public-images** parent project, not the user's project.

Pick the most recent Ubuntu+CUDA version that matches the workload. Verified-working choices as of 2026-05-01:

| Image family | OS | CUDA | Driver | Notes |
|---|---|---|---|---|
| `mk8s-worker-node-v-1-33-ubuntu24.04-cuda12.8` | Ubuntu 24.04 | 12.8 | 570.x | Latest, broad H100/H200 support |
| `mk8s-worker-node-v-1-30-ubuntu22.04-cuda12` | Ubuntu 22.04 | 12.4 | 550.x | Older, more battle-tested for ML libs |
| `mk8s-worker-node-v-1-33-ubuntu24.04-cuda13.0` | Ubuntu 24.04 | 13.0 | 580.x | Newest CUDA, but torch wheels lag |

The `mk8s-worker-node-` prefix is a misnomer — these images work fine on standalone compute VMs. They have NVIDIA drivers + CUDA toolkit pre-installed. **Skip the cuda13.0 family unless you've already tested your wheels against it** — torch / unsloth typically support cuda12.x first.

---

## 3. Provision + Run (~5-30 min)

Use `templates/provision.sh` as the starting point. The script needs five env vars set:

```bash
export PROJECT_ID=project-e00g0tvwpr00bsmthbv05w
export SUBNET_ID=vpcsubnet-e00mqv55h1a4t84hyx
export PLATFORM=gpu-h100-sxm
export PRESET=1gpu-16vcpu-200gb
export IMAGE_FAMILY=mk8s-worker-node-v-1-33-ubuntu24.04-cuda12.8
export INSTANCE_NAME=my-experiment
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
```

Then `bash templates/provision.sh`. Emits the instance ID. Operation runs synchronously — terminal blocks until `RUNNING` or `ERROR`.

### Get the public IP

```bash
nebius compute instance get --id <instance-id> | \
  awk '/^status:/{f=1} f && /public_ip_address:/{p=1} p && /address:/{print $2; exit}'
```

The IP is under `status.network_interfaces[0].public_ip_address.address` (with `/32` suffix — strip it). The `spec.network_interfaces[]` object always shows `{}` because that's the user's intent ("allocate dynamically"); the actual allocation is in `status`.

### SSH and run

The default user is `ubuntu` (set by cloud-init in `templates/cloud-init.yaml`). First SSH may take 30-90s after `RUNNING` while cloud-init finishes.

```bash
SSH_OPTS=(-i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
ssh "${SSH_OPTS[@]}" ubuntu@<IP> 'nvidia-smi --query-gpu=name,memory.total --format=csv'
```

For **Ubuntu 24.04** (which is PEP 668-locked), use a venv — `pip install --user` will refuse:

```bash
ssh "${SSH_OPTS[@]}" ubuntu@<IP> bash <<'REMOTE'
set -e
python3 -m venv ~/venv
source ~/venv/bin/activate
pip install --upgrade pip wheel -q
pip install -q <your-deps>
python <your-script.py>
REMOTE
```

`templates/run.sh` wraps SCP + SSH + execute as a one-liner.

---

## 4. Teardown (MANDATORY, ~30 sec)

```bash
nebius compute instance delete --id <instance-id>
```

Wait for the operation to complete (`finished_at` field appears). Then check for orphan disks:

```bash
nebius compute disk list --parent-id $PROJECT_ID | grep -B1 "name: <instance-name>-boot"
```

If the boot disk survives the instance delete (it's a managed disk, separate lifecycle), explicitly delete it:

```bash
nebius compute disk delete --id <disk-id>
```

`templates/teardown.sh` handles both in one shot. **Always run teardown.** A 200GB boot disk left running for a month costs ~$16. A forgotten H100 instance running for a day costs $70.

### Verify the meter stopped

```bash
nebius compute instance get --id <id>
# Should print: Error: rpc error: code = NotFound desc = instance not found
```

---

## Cost ladder

What a typical session burns:

| Phase | Time | Cost @ $2.95/hr H100 |
|---|---|---|
| Setup + Discover | 6 min | $0 (no compute yet) |
| Provision (instance create → RUNNING) | 3 min | $0.15 |
| First SSH + cloud-init finish | 1 min | $0.05 |
| Pip install (unsloth + torch + datasets) | 4 min | $0.20 |
| Model download (e.g. Gemma 4 E4B, ~8GB) | 2 min | $0.10 |
| Workload (e.g. 1k Dolly QLoRA × 3 epochs) | 10 min | $0.50 |
| Pull results | 1 min | $0.05 |
| Teardown | 30 sec | $0.025 |
| **Total** | **~22 min** | **~$1.10** |

For a 2-hour workshop with 12 attendees each running their own VM end-to-end: ~$12-15 total compute (or ~$1.10 × 12 = $13.20). This is rounding error — don't optimize the cost, optimize the experience.

If the user is paying out-of-pocket, $30/mo of Nebius free credit (signup) covers this many times over. If the workshop has a Nebius credit grant via promo code, attendees enter the code at signup and the workshop is free for them.

---

## Common Patterns

### Pattern A: One-shot validation (this dry-run shape)

```
provision → ssh → run script → pull output → teardown
```

For: validating a recipe (does X actually train?), benchmark, single-question experiment.

### Pattern B: Interactive notebook session

```
provision → ssh-tunnel jupyter port → work in browser → teardown when done
```

```bash
ssh -L 8888:localhost:8888 -i ~/.ssh/id_ed25519 ubuntu@<IP>
# on remote: pip install jupyterlab && jupyter lab --no-browser
# then open localhost:8888 locally
```

For: exploratory notebook work. **Set a calendar reminder to teardown** — easy to forget when you walk away.

### Pattern C: Multi-attendee workshop

Each attendee provisions their own VM under their own Nebius account. The `provision.sh` template is given to them; they fill `INSTANCE_NAME=<their-name>`. The workshop host walks them through Setup + Discover live, then everyone provisions in parallel. Teardown is the closing ritual ("everyone run `bash teardown.sh` now") — checked by the host.

This skill's templates are designed for Pattern C ergonomics: a single attendee can read SKILL.md, copy templates, and execute end-to-end without further help.

---

## Hard-won knowledge (read PITFALLS.md for the full list)

The five things that are not obvious from the Nebius docs:

1. **`network_interfaces` JSON shape**: `public_ip_address` is a sibling of `ip_address`, not a nested field. The shape that works:
   ```json
   [{"name":"eth0","subnet_id":"<id>","ip_address":{},"public_ip_address":{"static":false}}]
   ```
2. **`--boot-disk-attach-mode READ_WRITE`** is required, not defaulted. Same for `--boot-disk-managed-disk-type NETWORK_SSD`.
3. **Image families live in `project-e00public-images`**, not the user's project. Always pass `--boot-disk-managed-disk-source-image-family-parent-id project-e00public-images`.
4. **Public IP is in `status`, not `spec`.** `spec.network_interfaces[0].public_ip_address` always shows `{}` (intent). The allocated IP appears under `status.network_interfaces[0].public_ip_address.address` after the instance reaches RUNNING.
5. **Ubuntu 24.04 enforces PEP 668.** `pip install --user` is blocked. Use `python3 -m venv` (templates do this).

---

## Templates (one-liner-ready)

All templates use env vars so the user fills in five values once and the rest is mechanical. See:

- `templates/provision.sh` — create the VM with cloud-init
- `templates/run.sh` — SCP a script + execute it via SSH
- `templates/teardown.sh` — delete instance + orphan boot disk
- `templates/cloud-init.yaml` — SSH key + default user setup

Read CHECKLIST.md for the exact run-order. Read PITFALLS.md when something errors.
