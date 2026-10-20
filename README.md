# my-builder

Public-repo CI that builds **private** code on **cloud** VMs, with agent-grade
remote access.

Private repositories are never hosted here. This repo holds only workflows.
At runtime a workflow clones a private repo through an encrypted token,
compiles it on a GitHub-hosted VM (or your own Azure Spot VM), uploads the
artifacts, and wipes the source.

```
  private repo  --clone via token-->  cloud VM  --artifacts-->  GitHub storage
   (source never here)                  (CPU/RAM/battery)
```

## Why it exists

GitHub Actions gives public repos **unlimited** free minutes and private repos
a capped monthly allowance. Registering cloud VMs as self-hosted runners
against a public repo moves all compute off your laptop: no local CPU spikes,
no fan noise, no battery drain. The private source is cloned, built, and
deleted on the VM.

## Five ways in

| Need | Workflow | Access |
|---|---|---|
| Compile only | `build-private.yml` | none - artifacts download |
| Windows desktop | `rdp-cloud-vm.yml` | `mstsc` over Tailscale, or SSH for agents |
| macOS desktop | `mac-screen.yml` | Screen Sharing over Tailscale, or SSH for agents |
| Android device matrix | `android-device-matrix.yml` | none - APK tested on emulators, reports as artifacts |
| Android live device | `android-screen.yml` | ADB + scrcpy over SSH; the emulator is never published |

## Agent access

Session VMs run SSH with key auth. An agent on the tailnet can execute
commands and move files without touching your local machine:

```powershell
cloudvm up --os windows --hours 1
cloudvm ssh --os windows -c "npm test"
cloudvm push ./dist.zip /tmp/dist.zip
```

See [docs/remote-access.md](docs/remote-access.md) and
[docs/cli.md](docs/cli.md).

## Layout

```
.github/workflows/   the five workflows (this is the product)
cli/cloudvm.ps1      single-file CLI over gh + Tailscale + OpenSSH
tools/               validator: YAML parse + per-step shell syntax check
docs/                architecture, data flow, security, runbook, ...
infra/               Azure Terraform + cloud-init (LOCAL ONLY, not published)
lab/                 local Android Lab dashboard (LOCAL ONLY, not published)
```

`infra/`, `private-repo-trigger/`, and `lab/` are intentionally untracked -
they target your Azure subscription, your private repos, and your local
browser, not this public one.

## Documentation

| Doc | Read it when |
|---|---|
| [docs/architecture.md](docs/architecture.md) | How the pieces fit together |
| [docs/data-flow.md](docs/data-flow.md) | What happens to your code and secrets |
| [docs/diagrams.md](docs/diagrams.md) | You want the picture instead of prose |
| [docs/security.md](docs/security.md) | Threat model and access control |
| [docs/workflows.md](docs/workflows.md) | Reference for inputs, outputs, gates |
| [docs/cli.md](docs/cli.md) | Driving sessions from a terminal or agent |
| [docs/remote-access.md](docs/remote-access.md) | SSH, RDP, VNC access details |
| [docs/runbook.md](docs/runbook.md) | Something is broken |
| [docs/decisions.md](docs/decisions.md) | Why it works this way |
| [docs/android-device-testing.md](docs/android-device-testing.md) | Testing APKs on many devices |
| [docs/multi-agent.md](docs/multi-agent.md) | Handing builds to a second agent |
| [docs/cost.md](docs/cost.md) | What this costs |
| [AGENTS.md](AGENTS.md) | You are an agent working in this repo |

## Agent contribution rules

Read [AGENTS.md](AGENTS.md) first. In short:

- `gh` must be authenticated as `codebox1230`
- run `python tools/validate-workflows.py` before every push (must be 56/56)
- one idea per commit, push straight to `main`
- keep files ASCII-only
