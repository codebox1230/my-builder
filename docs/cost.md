# Cost and limits

## What is free

| Resource | Public repo | Private repo (this account) |
|---|---|---|
| Actions minutes | **unlimited** | 2,000/month (Free) or 3,000 (Pro) |
| Artifact storage | free, shared with Packages | 500 MB (Free) or 2 GB (Pro) |
| Package storage | free | 500 MB / 2 GB |
| Actions cache | 10 GB per repo | 10 GB per repo |
| Self-hosted runner platform fee | $0 | $0 (postponed indefinitely) |
| GitHub-hosted runner | $0 | $0.008-0.062/min depending on OS |

This is the entire economic basis of the design: the orchestration lives in a
public repo so the compute is free and unlimited, while the code stays in a
private repo.

## What costs money (only if you choose self-hosted VMs)

| Item | Approximate |
|---|---|
| Azure Spot VM, 4 vCPU / 16 GB | ~$0.02-0.05/hr vs on-demand |
| Azure Static Public IP | ~$3.65/month each |
| Azure NAT Gateway | ~$32/month + data |
| ARM64 Spot (`Standard_D4pds_v5`) | roughly 50x cheaper per core than comparable x64 |
| AWS Device Farm (after the free 1,000 min) | $0.17/device-minute |
| Firebase Test Lab (after the daily free quota) | $1/hr virtual, $5/hr physical |

Spot VMs can be evicted with ~30 s notice. `eviction_policy = "Deallocate"`
stops the VM but keeps the disk, so a rebuild is cheap.

## Practical economics of the current setup

A typical session run:

```
Windows session, 2 hours          = $0   (public repo minutes)
Mac session, 1 hour               = $0
Headless build, 10 minutes        = $0
Android matrix, 9 emulators       = $0
Android screen session, 2 hours   = $0
Tailscale (personal, 1 node)      = $0
Firebase Test Lab, 10 virtual/day = $0
```

Total: **$0/month**, for effectively unlimited CI plus interactive cloud
desktops.

The real costs are non-monetary: the Tailscale auth key, the PAT, and the
discipline of not leaving session workflows running unattended.

## Hard limits to design around

| Limit | Value | Consequence |
|---|---|---|
| Runner disk | 145 GB (~86 GB free measured) | several AVD images or huge artifacts can still exhaust it |
| Runner RAM | 16 GB (15 GiB usable measured) | heavy Gradle plus emulator in one job can OOM |
| Artifact retention | 90 days default | old artifacts vanish; download what you need |
| Session duration | 350 min workflow cap | `session_hours` max 5 |
| Public repo concurrency | 20 jobs | beyond that, dispatches queue |
| `mac-screen.yml` concurrency | 1 | one Mac session at a time by design |
| VNC password | 8 characters | protocol limit, not a policy |
| Repo size | 5 GB soft cap, 100 MB per file | use LFS for large binaries |
| Single push | 2 GB | split large pushes |

## Saving money if you outgrow the free tier

1. **Cache aggressively.** `actions/cache` on `~/.npm`, `~/.gradle`,
   `~/.m2` removes most of the download time - and the minutes that follow.
2. **Use ARM64 Spot** for your own VMs. Cheapest compute per core.
3. **Avoid public IPs** on ephemeral VMs - the hourly IP charge applies even
   when the VM is stopped.
4. **Scale to zero.** Scale sets that drop to 0 instances when the queue is
   empty avoid paying for idle capacity.
5. **Batch builds.** One matrix run beats twenty single dispatches.

## Billing safety notes

- `protected-cloud` has no required reviewers, so any session can start
  unattended. A forgotten session runs for its full `session_hours` window.
- The `concurrency` lock prevents a pile-up of Mac sessions, but the Windows
  workflow uses a separate group.
- A cancelled run still consumed the minutes it used.

## Free-tier quotas you will actually hit

| Quota | Free limit | Likely first to bite |
|---|---|---|
| Firebase Test Lab physical | 5/day | if you test on many real devices daily |
| GitHub Packages (private) | 500 MB | if you publish packages from a private repo |
| Actions cache | 10 GB/repo | large Gradle or npm caches |
| Azure Static IP | charged hourly | if you keep a public IP on an idle VM |

## Rough cost of the alternatives

| Approach | Monthly |
|---|---|
| This system (public repo + hosted runners) | $0 |
| Same, with your own persistent Azure VM (8 vCPU) | ~$60-100 + $3.65 IP |
| MacStadium / dedicated Mac hosting | $50-100+/mo |
| GitHub larger runners (private repo) | $0.10-0.90/hr per runner |
| Firebase Test Lab heavy use | $30-150/mo |
