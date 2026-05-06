# Colin's Co-Host Runbook — Add Workshop Shards From Your Laptop

Dear Colin,

Ray's tenant hit the Nebius public-IP quota cap of 3. We need 2-3 more H100s and your tenant has its own quota pool.

## What you're doing

Spinning up N additional H100 SXM nodes on **your** Nebius account, bootstrapping each with the workshop recipe (Gemma 4 + Unsloth + Dolly), and sending Ray a markdown block that he pastes into the live attendee manifest.

Your N nodes get added as Shard 4, 5, ... in `ASSIGNMENTS.md`. The 19 attendees who haven't logged in yet route to your shards.

## Prereqs (~2 min)

- Mac, Linux, or WSL2 (Windows). Bash, git, ssh-keygen.
- Nebius account ([console.nebius.com](https://console.nebius.com)) with available H100 quota.
- A browser open for the OAuth dance (one-time per laptop).

## The one command

```bash
git clone https://github.com/RayyanZahid/gemma-finetune.git
cd gemma-finetune/workshop
bash colin-add-shards.sh 3
```

Replace `3` with whatever count Ray needs. The script:

1. Checks your Nebius CLI (installs it if missing — one curl line)
2. Confirms you're authed (prints OAuth instructions if not)
3. Auto-discovers your project + subnet
4. Generates 3 ed25519 keypairs in `keys/ws-colin-{4,5,6}.pem`
5. Provisions 3 × `gpu-h100-sxm` / `1gpu-16vcpu-200gb` (sequential, ~90 sec total)
6. Bootstraps each in parallel (~10 min cold first run: apt python3-dev, clone repo, venv, pip install unsloth, download Dolly, verify GPU)
7. **Prints a ready-to-paste markdown block for Ray**

Total wall-clock: ~12 min from "nothing" to "Ray pastes and 24 attendees can SSH in."

## What you send Ray

The script's last output is a fenced markdown block that looks like:

```md
<!-- BEGIN COLIN-PROVISIONED SHARDS — paste into ASSIGNMENTS.md -->

### Shard 4 — Colin's H100 (overflow)
**SSH:** `ssh -i ~/.ssh/ic-shard-4.pem ubuntu@<IP>`
...
-----BEGIN OPENSSH PRIVATE KEY-----
<key>
-----END OPENSSH PRIVATE KEY-----
...

<!-- END COLIN-PROVISIONED SHARDS -->
```

**Copy that whole block.** DM/text/Slack/email it to Ray. He appends it to ASSIGNMENTS.md and pushes. Attendees use it within 30 seconds.

## When the workshop ends (~9:30pm PT)

```bash
bash colin-teardown.sh
```

This kills only the instances YOU provisioned (named `ws-<your-username>-N`). Ray's `workshop-N` boxes are untouched. **Run it.** Forgotten H100s burn ~$70/day.

## Cost on you

| Count | Cost over 2 hours |
|---|---|
| 1 H100 | ~$6 |
| 2 H100s | ~$12 |
| 3 H100s | ~$18 |
| 5 H100s | ~$30 |

Nebius's $100 trial pool covers this many times over. If you used yours up earlier, ping Ray.

## If something fails

| Symptom | What to try |
|---|---|
| "Nebius CLI not found" | Script auto-installs. If it didn't, run: `curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh \| bash && exec $SHELL` |
| "not authed" | Run: `nebius profile create default --endpoint api.nebius.cloud --federation-endpoint auth.nebius.com`, click the OAuth URL it prints, sign in with your Google account |
| `Quota limit exceeded` | Your tenant's IP cap. Provision fewer nodes (e.g. `bash colin-add-shards.sh 1`). |
| `Not enough resources` | Nebius capacity. Wait 60s, retry, OR try a different region by editing PROJECT_ID. Try eu-west1 or me-west1 IDs. |
| Bootstrap log says "Permission denied" | The cloud-init key didn't propagate yet. Wait 30s, re-run `bash colin-add-shards.sh 3 --start-shard 4` (script is idempotent for already-provisioned shards). |

## Files this skill writes (gitignored)

- `keys/ws-<you>-N.pem` + `.pub` — your private+public keypairs
- `_colin-bootstrap-N.log` — per-shard bootstrap output

When teardown is run, you can also `rm -rf keys/ws-<you>-*` to clean up the keypairs.

## Why the markdown approach

You don't have write access to the public repo. Ray does. So you produce the markdown, Ray pastes + commits + pushes. 30 seconds total from your message to live.

If you want write access (for next time), Ray can `gh repo invite RayyanZahid/gemma-finetune <your-handle>`.

---

*Thank you Colin. The workshop is live and capacity-constrained — your shards unblock the late-arriving attendees.*
