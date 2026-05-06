# IC Workshop — Attendee Assignments

**Event:** Fine-Tune Gemma 4 on Your Data
**When:** Tue May 5 2026, 7:30pm PT
**Where:** Frontier Tower, Floor 16
**Capacity:** 35 attendees across 3 H100 shards
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
4. Save the key as `~/.ssh/ic-shard-N.pem` and `chmod 600` it.
5. Open your coding agent (Claude Code, Cursor, Cline, Aider, anything).
6. Drop this prompt in:

```
Read https://github.com/RayyanZahid/gemma-finetune/blob/master/TASK.md.
SSH into <YOUR-IP> as ubuntu using ~/.ssh/ic-shard-N.pem.
Run the workflow described in TASK.md. My output namespace is "attendee-X" (your number).
```

The agent does the rest. Walk over to Eric or Ray if it stalls 5+ min.

---

## Number → Shard map

| Numbers | Shard | IP |
|---|---|---|
| 1 - 12 | 1 | 89.169.114.123 |
| 13 - 24 | 2 | 89.169.115.238 |
| 25 - 35 | 3 | 89.169.123.133 |

### Overflow shards (Colin's H100s)

If your original shard is full or slow, OR you're starting late, use one of these instead:

| Numbers | Shard | IP |
|---|---|---|
| 1 - 17 (any not-yet-started) | 4 | 89.169.108.202 |
| 18 - 35 (any not-yet-started) | 5 | 89.169.120.70 |

The overflow shards are fresh empty H100s — no queue, instant capacity.

---

## Shards

### Shard 1 — attendees 1 to 12

**SSH:** `ssh -i ~/.ssh/ic-shard-1.pem ubuntu@89.169.114.123`
**Output dir:** `runs/attendee-N/` (replace N with your assigned number)

Save the following as `~/.ssh/ic-shard-1.pem`, then `chmod 600 ~/.ssh/ic-shard-1.pem`:

```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACAWxjNcTvSyp37gJeyIRqRW4GSlcTeP0/yaauRDdYHciQAAAKBvJI7QbySO
0AAAAAtzc2gtZWQyNTUxOQAAACAWxjNcTvSyp37gJeyIRqRW4GSlcTeP0/yaauRDdYHciQ
AAAECR3WftcR+oPgfAt8ogRlaahRDuBqh6WNCMbAA2hOgHsxbGM1xO9LKnfuAl7IhGpFbg
ZKVxN4/T/Jpq5EN1gdyJAAAAFndvcmtzaG9wLTFAaWMtd29ya3Nob3ABAgMEBQYH
-----END OPENSSH PRIVATE KEY-----
```

### Shard 2 — attendees 13 to 24

**SSH:** `ssh -i ~/.ssh/ic-shard-2.pem ubuntu@89.169.115.238`
**Output dir:** `runs/attendee-N/` (replace N with your assigned number)

Save the following as `~/.ssh/ic-shard-2.pem`, then `chmod 600 ~/.ssh/ic-shard-2.pem`:

```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACDkYns8fkBrP2pY2ump5Uhkzk72jIZkZP2LRlwgc/LHSAAAAKChbbJRoW2y
UQAAAAtzc2gtZWQyNTUxOQAAACDkYns8fkBrP2pY2ump5Uhkzk72jIZkZP2LRlwgc/LHSA
AAAECMGpwyQZLX7WKcSLUo1hiVLiDJiM70j3ymmPFT6o/ry+Riezx+QGs/alja6anlSGTO
TvaMhmRk/YtGXCBz8sdIAAAAFndvcmtzaG9wLTJAaWMtd29ya3Nob3ABAgMEBQYH
-----END OPENSSH PRIVATE KEY-----
```

### Shard 3 — attendees 25 to 35

**SSH:** `ssh -i ~/.ssh/ic-shard-3.pem ubuntu@89.169.123.133`
**Output dir:** `runs/attendee-N/` (replace N with your assigned number)

Save the following as `~/.ssh/ic-shard-3.pem`, then `chmod 600 ~/.ssh/ic-shard-3.pem`:

```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCnP0fHfTQTjRH5is8GpW4OzBE656MIjZ0kNyV07VgPSAAAAKAMR8jGDEfI
xgAAAAtzc2gtZWQyNTUxOQAAACCnP0fHfTQTjRH5is8GpW4OzBE656MIjZ0kNyV07VgPSA
AAAECZjaC+gG7iUQhgkn1ovdLWBsuvfCsh/XKAy/Qif67fWac/R8d9NBONEfmKzwalbg7M
ETrnowiNnSQ3JXTtWA9IAAAAFndvcmtzaG9wLTNAaWMtd29ya3Nob3ABAgMEBQYH
-----END OPENSSH PRIVATE KEY-----
```

---

### Shard 4 — Colin's H100 (overflow for numbers 1-17)

**SSH:** `ssh -i ~/.ssh/ic-shard-4.pem ubuntu@89.169.108.202`
**Output dir:** `runs/attendee-N/`

Save this private key as `~/.ssh/ic-shard-4.pem`, then `chmod 600 ~/.ssh/ic-shard-4.pem`:

```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACD9m3a3SoXULNW7V8vlzawng3BCE0Bw+rfUPZFB2jSimgAAAKClKzfXpSs3
1wAAAAtzc2gtZWQyNTUxOQAAACD9m3a3SoXULNW7V8vlzawng3BCE0Bw+rfUPZFB2jSimg
AAAEAQHlGtAKdkq03cnNBo4O/qj8zys+m/pCnY4SQYEHwcRP2bdrdKhdQs1btXy+XNrCeD
cEITQHD6t9Q9kUHaNKKaAAAAFndzLWNvbGluLTRAaWMtd29ya3Nob3ABAgMEBQYH
-----END OPENSSH PRIVATE KEY-----
```

### Shard 5 — Colin's H100 (overflow for numbers 18-35)

**SSH:** `ssh -i ~/.ssh/ic-shard-5.pem ubuntu@89.169.120.70`
**Output dir:** `runs/attendee-N/`

Save this private key as `~/.ssh/ic-shard-5.pem`, then `chmod 600 ~/.ssh/ic-shard-5.pem`:

```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACC2i/j4J2XobOiPzneTUTjy1osU2LbIy34l5EYRT+QFxQAAAKBc2Z5xXNme
cQAAAAtzc2gtZWQyNTUxOQAAACC2i/j4J2XobOiPzneTUTjy1osU2LbIy34l5EYRT+QFxQ
AAAEAfcTAKa6ptopu83CZnz396ZZrIgikWB53fI9B0YbcRW7aL+PgnZehs6I/Od5NROPLW
ixTYtsjLfiXkRhFP5AXFAAAAFndzLWNvbGluLTVAaWMtd29ya3Nob3ABAgMEBQYH
-----END OPENSSH PRIVATE KEY-----
```

---

## Need help?

- Walk over to Ray (host) or Eric (technical demo).
- Common failures: see [TASK.md § Failure recovery](TASK.md#failure-recovery).
- The full recipe: [SKILL.md](SKILL.md), [CHECKLIST.md](CHECKLIST.md), [PITFALLS.md](PITFALLS.md).

*This page rotates after teardown (~9:30pm). Don't share with anyone outside the room.*
