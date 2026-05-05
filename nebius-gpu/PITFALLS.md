# nebius-gpu — Pitfalls (and how to fix them)

Every error encountered during the v1 dry-run (2026-05-01), with the exact fix. Ordered by how likely you'll hit it on first try. If you see one of these errors, jump to the matching section.

---

## 1. `unknown field "public_ip_address"` (network-interfaces JSON)

**Symptom:**
```
Error: read protojson from --network-interfaces: proto: (line 1:38): unknown field "public_ip_address"
```

**Root cause:** Nesting `public_ip_address` inside `ip_address`. They're siblings, not parent/child.

**Fix:** Use this shape:
```json
[{"name":"eth0","subnet_id":"<id>","ip_address":{},"public_ip_address":{"static":false}}]
```

Not this (wrong):
```json
[{"name":"eth0","subnet_id":"<id>","ip_address":{"public_ip_address":{}}}]
```

The `ip_address: {}` (empty) means "auto-allocate a private IP." The sibling `public_ip_address: {"static":false}` adds a dynamic public IP. If you want NO public IP (private-only), omit the `public_ip_address` field entirely.

---

## 2. `value is required` on multiple boot-disk fields

**Symptom:**
```
validation failed: validation errors:
 - spec.network_interfaces[0].ip_address: value is required
 - spec.boot_disk.attach_mode: value is required
 - spec.boot_disk.managed_disk.spec.type: value is required
```

**Root cause:** Three fields default to "unspecified" instead of sensible defaults. The CLI doesn't auto-fill them.

**Fix:** Always set:
```bash
--boot-disk-attach-mode READ_WRITE
--boot-disk-managed-disk-type NETWORK_SSD
```

And in `--network-interfaces` JSON, always include `"ip_address":{}` (empty object — means "auto-allocate").

---

## 3. `pip install --user` blocked: "externally-managed-environment"

**Symptom (Ubuntu 24.04):**
```
error: externally-managed-environment
× This environment is externally managed
```

**Root cause:** PEP 668 — Ubuntu 24.04 marks system Python as externally-managed to prevent pip from breaking apt packages.

**Fix:** Use a venv:
```bash
python3 -m venv ~/venv
source ~/venv/bin/activate
pip install <packages>
```

Or, if you accept the risk: `pip install --break-system-packages <packages>`. Don't do this on shared/multi-user VMs.

---

## 4. Instance `state: RUNNING` but SSH refuses connection

**Symptom:**
```
ssh: connect to host <ip> port 22: Connection refused
```
…even though `nebius compute instance get` says `state: RUNNING`.

**Root cause:** Cloud-init hasn't finished setting up SSH yet. Compute can be RUNNING for 30-90s before sshd accepts the cloud-init-installed key.

**Fix:** Wait + retry. The run.sh template loops 30× × 10s = 5 min ceiling. If still no SSH after 5 min, suspect cloud-init failure — SSH from the dashboard's web console (Compute → instance → Console) and `cat /var/log/cloud-init-output.log`.

---

## 5. Public IP shows `{}` in `instance get` output

**Symptom:** `nebius compute instance get` returns:
```yaml
spec:
  network_interfaces:
    - public_ip_address: {}
```

**Root cause:** You're reading `spec` (intent), not `status` (actual). The `spec.public_ip_address: {}` means "allocate dynamically — I don't care which IP." The actual allocated IP appears under `status.network_interfaces[0].public_ip_address.address` once the instance is RUNNING.

**Fix:** Parse `status`, not `spec`:
```bash
nebius compute instance get --id <id> | \
  awk '/^status:/{f=1} f && /public_ip_address:/{p=1} p && /address:/{gsub("/32",""); print $2; exit}'
```

The `/32` suffix is CIDR notation — strip it for SSH.

---

## 6. `nebius compute image list` returns empty for your project

**Symptom:** `nebius compute image list --parent-id $PROJECT_ID` prints `{}`.

**Root cause:** Public images don't live in user projects — they live in `project-e00public-images`.

**Fix:**
```bash
nebius compute image list --parent-id project-e00public-images
```

For the create command, also pass:
```bash
--boot-disk-managed-disk-source-image-family-parent-id project-e00public-images
```

---

## 7. `nebius profile create` opens browser but doesn't complete

**Symptom:** Browser opens to OAuth, you sign in, terminal still hangs.

**Possible causes:**
- WSLg failed to relay the redirect URL back to the CLI's local listener (port 38959-ish).
- Firewall blocking the loopback callback.
- Browser opened in a profile that's NOT signed in to the same Google account as your Nebius tenant.

**Fix:** Cancel (Ctrl-C). Re-run with the URL copied manually:
1. The CLI prints `Switch to your browser to complete...` with a URL.
2. Copy the URL into the browser tab where you're already signed in to console.nebius.com.
3. Approve. The redirect lands and the CLI returns.

If still failing, fall back to service-account auth (dashboard → IAM → Service Accounts → Create + Download key) and `nebius profile create --service-account-file <key.json>`.

---

## 8. Forgot to teardown — bill is climbing

**Symptom:** You closed your terminal and forgot. Or your VM survived a reboot.

**Fix:**
```bash
nebius compute instance list --parent-id $PROJECT_ID
# find any computeinstance-* that shouldn't be there
nebius compute instance delete --id <id>
```

If you don't even know what instances exist, log in at console.nebius.com → Compute → Instances. Anything you don't recognize: delete.

**Prevention:** Set up billing alerts at console.nebius.com → Notification settings. Recommended thresholds for personal accounts: $5 (catches a forgotten H100 within 2 hours), $20 (catches it within 8 hours).

---

## 9. Boot disk persists after instance delete

**Symptom:** `nebius compute disk list` shows a `<instance-name>-boot` disk you thought was gone.

**Root cause:** Managed disks have a separate lifecycle from instances by default. `instance delete` does NOT cascade to its disks.

**Fix:** The `teardown.sh` template handles this — it explicitly looks up and deletes the boot disk after the instance goes. If you ran a custom delete:
```bash
nebius compute disk list --parent-id $PROJECT_ID | grep <name>-boot
nebius compute disk delete --id <disk-id>
```

A 200GB orphan boot disk costs ~$16/month. Not catastrophic, but cumulative.

---

## 10. CLI hangs / `--async` flag confusion

**Symptom:** `instance create` returns immediately with just an operation ID, no instance details.

**Root cause:** You passed `--async`. Without it, the CLI waits synchronously for the operation to finish.

**Fix:** Either:
- Drop `--async` (synchronous mode — simpler for one-off provisioning)
- Keep `--async` and poll: `nebius operation get --id <op-id>` until `finished_at` appears

---

## 11. Quota exceeded

**Symptom:** `Error: rpc error: code = ResourceExhausted desc = quota exceeded`

**Root cause:** New Nebius accounts have low default quotas (1 H100, $X compute/mo).

**Fix:** Open dashboard → Limits → request a quota increase. Approval is usually fast (hours, not days) for reasonable single-GPU asks. For workshop scenarios where 12 attendees each need 1 H100, every attendee's account has its own quota — no issue.

---

## 12. Cloud-init key ignored / SSH still asks for password

**Symptom:** SSH fails with `Permission denied (publickey)` even though you provided the public key in cloud-init.

**Possible causes:**
- The pubkey in cloud-init is actually the *private* key (you copied `id_ed25519` instead of `id_ed25519.pub`).
- Cloud-init had a YAML parse error and silently skipped the keys block.

**Fix:**
1. Confirm pubkey: `cat ~/.ssh/id_ed25519.pub` should start with `ssh-ed25519 AAAA...` (not `-----BEGIN OPENSSH PRIVATE KEY-----`).
2. Verify the `--cloud-init-user-data` value started with `#cloud-config` on its own line.
3. From the dashboard's web console, run `cloud-init status` and `cat /var/log/cloud-init-output.log` to see what cloud-init actually executed.

---

## 13. WSL2 `nebius` CLI install: PATH not picked up

**Symptom:** After `curl ... | bash`, `nebius version` says command not found.

**Root cause:** The installer modifies `~/.bashrc` but the current shell doesn't reload it.

**Fix:** Either:
- `exec $SHELL` (reload bash in current session)
- Open a new WSL terminal
- Call via full path: `~/.nebius/bin/nebius version`

---

## 14. `wsl bash` from PowerShell hangs on commands with `<()`, `(...)`, or backticks

**Symptom:** Some bash idioms work in WSL terminal but fail when piped through `wsl bash` from a Windows tool (PowerShell, Git Bash, Claude Code's Bash tool).

**Root cause:** Quoting / escaping mangling between Windows shell → WSL bash.

**Fix:** Write the bash logic to a file in WSL or `/mnt/c/...`, then `cat <file> | wsl bash` (single-quoted heredoc), or `wsl bash -lc "<single command>"`. Avoid mixing `<(...)` process substitution with cross-shell invocation.

---

## When something else breaks

1. Read the error carefully — Nebius's API errors are usually descriptive (`spec.X: value is required` tells you exactly what to add).
2. Check `nebius compute operation list --parent-id $PROJECT_ID` for failed operations.
3. From dashboard: Compute → instance → Logs tab. Cloud-init logs and serial console live there.
4. If stuck > 10 min: teardown what you have, ask for help, restart with a fresh provision. The 3-min create cost is cheap; debugging a corrupted state is expensive.
