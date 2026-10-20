# Architecture

## Components

```
+----------------------------------------------------------------------+
|  PUBLIC REPO (codebox1230/my-builder)                                 |
|  Contains ONLY: 4 workflows, CLI, validator, docs                   |
|  Contains NO source code of the project being built. Ever.           |
+---------------+------------------------------------------------------+
                |  trigger (workflow_dispatch | repository_dispatch)
                v
+----------------------------------------------------------------------+
|  GITHUB CONTROL PLANE                                                |
|  - decrypts secrets into job memory only                            |
|  - queues jobs to a matching runner                                  |
|  - stores artifacts, masks secrets in logs                          |
+---------------+------------------------------------------------------+
                |  job assignment (outbound HTTPS from runner only)
                v
+----------------------------------------------------------------------+
|  CLOUD VM  (GitHub-hosted, or your Azure Spot VM)                    |
|  +----------------------------------------------------------------+  |
|  |  runner agent --> clone private repo --> build --> upload     |  |
|  |  sshd / RDP / VNC        (token)          (toolchain)          |  |
|  |  cleanup: rm -rf source                                      |  |
|  +----------------------------------------------------------------+  |
+---------------+------------------------------------------------------+
                |  WireGuard (Tailscale), outbound only
                v
+----------------------------------------------------------------------+
|  YOUR DEVICES (tailnet)                                              |
|  - agents: ssh / scp, fully non-interactive                         |
|  - humans: mstsc (Windows) or Screen Sharing (macOS)                |
+----------------------------------------------------------------------+
```

## Two source-of-truth repos

| Repo | Visibility | Holds | Who reads it |
|---|---|---|---|
| `codebox1230/my-builder` | public | workflows only | GitHub runner, agents |
| `<owner>/<your-app>` | private | your source | cloned at runtime by the VM |

The public repo is the *orchestration*; the private repo is the *payload*. The
only bridge is an encrypted token, injected into one job's memory.

## Runner topologies

### A. GitHub-hosted (default, zero setup)

GitHub boots an Azure VM per job and deletes it when the job ends.

| Runner | CPU | RAM | Disk | Notes |
|---|---|---|---|---|
| `ubuntu-24.04` | 4 vCPU | 15 GiB | 145 GB (~86 GB free) | measured Oct 2026; exposes `/dev/kvm` |
| `windows-2022` | 4 vCPU | 16 GB | 145 GB | RDP + OpenSSH Server |
| `macos-latest` | 3 vCPU (M1) | 7 GB | 14 GB | real Mac hardware |

The Android device matrix runs many short-lived `ubuntu-24.04` jobs (one per
device profile x API level) with hardware acceleration via `/dev/kvm`. The
Android screen session uses one long-lived `ubuntu-24.04` job instead, so the
emulator can be held for hours and driven remotely.

Public repos get **unlimited** minutes. Standard runners cannot be kept alive
between runs - no snapshot, no resume. Persistence comes from
`actions/cache` and from artifacts, not from the VM.

### B. Self-hosted on your Azure Spot VM

`infra/terraform/main.tf` provisions a Spot VM (up to ~90% cheaper than
pay-as-you-go), registers it as a runner, and gives you a public IP for
direct SSH/RDP.

- `priority = "Spot"`, `eviction_policy = "Deallocate"`
- ARM64 SKUs (`Standard_D4pds_v5`) are the cheapest per core
- `infra/scripts/cloud-init-linux.sh` installs the toolchain and the runner
  agent, then enables it as a systemd service
- Ephemeral runners should use the `--ephemeral` flag: register, run one job,
  unregister, self-destruct

Trade-off versus A: you manage the lifecycle, but you can snapshot the disk,
bake custom images, and keep a warm dependency cache.

### C. Cirun-managed (middle ground)

`.cirun.yml` declares `cirun-azure-win` and `cirun-azure-linux` (Azure Spot,
`preemptible: true`). Cirun provisions on demand from the job trigger and
destroys after. Cheapest to operate, requires a linked Cirun account, and
its control plane is a third party.

## Component inventory

| Component | Where | Responsibility |
|---|---|---|
| `build-private.yml` | `.github/workflows/` | headless build, artifact upload, cleanup |
| `rdp-cloud-vm.yml` | `.github/workflows/` | Windows session: RDP + SSH + Tailscale |
| `mac-screen.yml` | `.github/workflows/` | macOS session: VNC + SSH + Tailscale |
| `android-device-matrix.yml` | `.github/workflows/` | headless APK matrix on KVM emulators, artifacts only |
| `android-screen.yml` | `.github/workflows/` | interactive Android session: build, boot AVD, install, hold for N hours, reachable over SSH |
| `cli/cloudvm.ps1` | `cli/` | drive sessions from a terminal or agent |
| `tools/validate-workflows.py` | `tools/` | pre-push syntax gate |
| `tools/validate-docs.py` | `tools/` | pre-push docs gate: ASCII, links, secret scan |
| `infra/terraform/main.tf` | `infra/` (local only) | Azure Spot VM provisioning |
| `infra/scripts/cloud-init-linux.sh` | `infra/` (local only) | VM boot: toolchain + runner |
| `private-repo-trigger/trigger-build.yml` | `private-repo-trigger/` (local only) | auto-trigger builds from private repos |
| `lab/lab.py` | `lab/` (local only) | local Android Lab dashboard driving the session VM |

## Trust boundaries

| Boundary | Crossing | Guard |
|---|---|---|
| Public repo -> private repo | clone | `PRIVATE_REPO_TOKEN`, Contents:Read-only, fine-grained |
| Public repo -> fork PR | never | `workflow_dispatch` only; no `pull_request` trigger |
| GitHub -> VM | secrets | libsodium sealed box; values never returned by API |
| VM -> tailnet | SSH/RDP | WireGuard, key auth, ephemeral Tailscale node |
| Tailnet -> internet | none | all tunnels are outbound-only |
| VM -> artifact store | upload | GitHub-managed, 90-day default retention |

## Component lifecycle of one session

```
 1. dispatch          workflow_dispatch / repository_dispatch
 2. authorize         actor must be owner or in ALLOWED_ACTORS
 3. environment       protected-cloud approval (currently no reviewers)
 4. provision         GitHub boots VM, installs toolchain
 5. tunnel            Tailscale joins tailnet (ephemeral node)
  6. access surface    SSH (always) + RDP (Windows) or VNC (macOS)
                       Android sessions add ADB on the runner's loopback,
                       reached over the same SSH tunnel
 7. work              build / debug / verify
 8. cleanup           rm source, logout tailnet, disable remote access
 9. destroy           GitHub deallocates the VM
```

Steps 8 and 9 are unconditional (`if: always()`). A crashed job still gets
its source removed.
