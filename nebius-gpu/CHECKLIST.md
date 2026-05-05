# nebius-gpu — Run-Order Checklist

The exact sequence from "I have a Nebius account" to "I have my output and the meter is stopped." Each step has a single purpose. If a step fails, fix it before the next — they depend on each other.

---

## Phase 0 — Prerequisites (skip if already done)

- [ ] Nebius account created at `console.nebius.com` (sign in with Google)
- [ ] Billing entity created (auto-prompted on first VM, or via dashboard → Billing)
- [ ] (Windows) WSL2 installed: `wsl --install` from PowerShell, reboot if first time
- [ ] (Windows) Confirmed `wsl bash` works from PowerShell
- [ ] (All) An SSH keypair exists at `~/.ssh/id_ed25519` (or generate: `ssh-keygen -t ed25519 -C your@email`)

## Phase 1 — Setup (one-time, ~5 min)

- [ ] Run in WSL/Linux/Mac: `curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash`
- [ ] Reload shell: `exec $SHELL` (or open a new terminal)
- [ ] Verify install: `nebius version` prints version + build info
- [ ] Run: `nebius profile create default --endpoint api.nebius.cloud --federation-endpoint auth.nebius.com`
- [ ] CLI prints OAuth URL → browser opens (or paste URL into browser)
- [ ] Sign in with the same Google account used at console.nebius.com
- [ ] Terminal returns with `profile "default" configured and activated`
- [ ] Verify auth: `nebius iam whoami` prints your email + tenants

## Phase 2 — Discover (one-time per project, ~1 min)

Set these env vars in your shell so the rest of the flow is copy-paste:

- [ ] `export PROJECT_ID=$(nebius iam project list 2>&1 | awk '/id: project-/{print $2; exit}')`
- [ ] Confirm: `echo $PROJECT_ID` shows `project-e00...`
- [ ] `export SUBNET_ID=$(nebius vpc subnet list --parent-id $PROJECT_ID 2>&1 | awk '/id: vpcsubnet-/{print $2; exit}')`
- [ ] Confirm: `echo $SUBNET_ID` shows `vpcsubnet-e00...`
- [ ] Pick GPU class: `export PLATFORM=gpu-h100-sxm` (or `gpu-h200-sxm`, `gpu-l40s-d`)
- [ ] Pick preset: `export PRESET=1gpu-16vcpu-200gb` (smallest single-GPU for any platform)
- [ ] Pick image: `export IMAGE_FAMILY=mk8s-worker-node-v-1-33-ubuntu24.04-cuda12.8`
- [ ] Pick a name: `export INSTANCE_NAME=my-experiment` (lowercase, hyphens; appears in dashboard)
- [ ] Load pubkey: `export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"`
- [ ] (Optional) Confirm preset is in the platform: `nebius compute platform list | grep -A20 "name: $PLATFORM" | grep "name:"`

## Phase 3 — Provision (~3 min)

- [ ] Run `templates/provision.sh` (or paste its inline command)
- [ ] Watch output. Should end with `state: RUNNING` after ~3 min
- [ ] If `state: ERROR` — read the error, run teardown (Phase 5), fix, retry
- [ ] Capture the instance ID from output: `export INSTANCE_ID=computeinstance-...`
- [ ] Get public IP:
  ```bash
  export PUBLIC_IP=$(nebius compute instance get --id $INSTANCE_ID 2>&1 | \
    awk '/^status:/{f=1} f && /public_ip_address:/{p=1} p && /address:/{gsub("/32",""); print $2; exit}')
  ```
- [ ] Confirm: `echo $PUBLIC_IP` shows e.g. `195.242.13.172`
- [ ] **Set a sanity timer**: `at now + 1 hour` or just calendar — "did I tear down?"

## Phase 4 — Run (variable, 5-30 min)

- [ ] Wait for SSH (cloud-init usually finishes 30-90s after RUNNING):
  ```bash
  for i in $(seq 1 12); do ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
    ubuntu@$PUBLIC_IP echo OK 2>/dev/null && break; sleep 10; done
  ```
- [ ] Confirm GPU visible:
  ```bash
  ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    ubuntu@$PUBLIC_IP nvidia-smi --query-gpu=name,memory.total --format=csv
  ```
- [ ] SCP your script: `scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null ./your_script.py ubuntu@$PUBLIC_IP:~/`
- [ ] Run with venv (Ubuntu 24.04 needs PEP-668 venv, not `pip install --user`):
  ```bash
  ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    ubuntu@$PUBLIC_IP bash <<'REMOTE'
  set -e
  python3 -m venv ~/venv
  source ~/venv/bin/activate
  pip install --upgrade pip wheel -q
  pip install -q <your-deps>
  python ~/your_script.py
  REMOTE
  ```
- [ ] Pull outputs: `scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null ubuntu@$PUBLIC_IP:~/output.json ./`

## Phase 5 — Teardown (MANDATORY, ~30 sec)

- [ ] `nebius compute instance delete --id $INSTANCE_ID` → wait for `finished_at`
- [ ] Check for orphan boot disk:
  ```bash
  nebius compute disk list --parent-id $PROJECT_ID | \
    grep -B1 "name: $INSTANCE_NAME-boot" | grep "id: computedisk" | awk '{print $2}'
  ```
- [ ] If a disk ID came back: `nebius compute disk delete --id <disk-id>`
- [ ] Verify instance is gone: `nebius compute instance get --id $INSTANCE_ID` should print
      `Error: rpc error: code = NotFound desc = instance not found`
- [ ] (Optional) Check usage in dashboard: console.nebius.com → Usage

---

## Habits

- **Always teardown.** Every flow ends with Phase 5. No exceptions. If you need to come back tomorrow, teardown today and re-provision tomorrow — the meter cost of leaving an instance overnight ($60-70 for an idle H100) dwarfs the 3-min provision next time.
- **Name instances by purpose**, not date. `gemma-dry-run` is searchable in dashboard; `vm-2026-05-01-attempt-3` is not.
- **Run `nebius compute instance list` periodically** to confirm no orphans. If you see an instance you don't recognize, teardown immediately.
- **Set up billing alerts** at console.nebius.com → Notification settings. A $20 alert catches a forgotten instance within ~7 hours of an H100 idle.
