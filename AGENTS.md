# AGENTS.md - my-builder (public cloud-CI builder)

Public repo holding ONLY GitHub Actions workflows. No source code lives here, ever.
Private repos are cloned at runtime via token, built on cloud VMs, artifacts
uploaded, source wiped.

- Live repo: `codebox1230/my-builder` (public)
- Local copy: `C:\Users\prati\public-repo-builder` (this IS the git repo)
- The local copy has MORE than the repo: `infra/` (Terraform + cloud-init) and
  `private-repo-trigger/` (drop-in auto-trigger for private repos) are
  **local only, never pushed**. A fresh clone won't have them.
- `docs/` holds the human-facing documentation. `README.md` is the entry
  point; `docs/README.md` indexes the rest.

## Account rules (violations have caused 403s before)

- `gh` active account MUST be `codebox1230`. Never `CodeSmithPratik` or
  `special28`. Verify: `gh api user -q .login`
- After `gh auth switch --user codebox1230`, run `gh auth setup-git`, or
  `git push` silently authenticates as the stale cached account and fails.
- Commit identity: `user.name=codebox1230`,
  `user.email=codebox1230@users.noreply.github.com`.
- No PR process: commit + push to `main`. New dispatches use the new file
  immediately, so a bad push breaks live sessions immediately.

## Workflows (`.github/workflows/`)

| File | Runner | Purpose |
|---|---|---|
| `build-private.yml` | picker, default `windows-2022` | Headless build, no desktop. `repo` input is REQUIRED and defaults to the placeholder `YOUR_USERNAME/YOUR_PRIVATE_REPO` - always pass a real `owner/name`. |
| `rdp-cloud-vm.yml` | `windows-2022` | Windows session: RDP + SSH over Tailscale/Cloudflare. |
| `mac-screen.yml` | `macos-latest` | macOS session: Screen Sharing + SSH over Tailscale. |
| `android-device-matrix.yml` | `ubuntu-24.04` matrix | Headless APK matrix across AVD profiles and API levels on KVM emulators. No desktop, no tunnel, reports as artifacts. Pinned to 24.04: `ubuntu-latest` is migrating to Ubuntu 26. |

- Session workflows gate on an `authorize` job (actor must be repo owner or
  listed in `ALLOWED_ACTORS`) plus the `protected-cloud` environment.
- `mac-screen.yml` has `concurrency: mac-screen-session` - one Mac session at
  a time; further dispatches queue rather than run in parallel.
- `build-private.yml` needs `PRIVATE_REPO_TOKEN`; `actions/checkout`
  hard-errors on an empty token.
- `.cirun.yml` defines `cirun-azure-win` / `cirun-azure-linux` (Azure Spot
  VMs via Cirun). Those runners only exist if a Cirun account is linked.

## Secrets (names only - values are write-only and unrecoverable by design)

- `ALLOWED_ACTORS` = `codebox1230`
- `PRIVATE_REPO_TOKEN` = TEMPORARY broad OAuth token. Replace with a
  fine-grained PAT (Contents: Read-only, scoped to the private repos).
- `TAILSCALE_AUTHKEY` = reusable + ephemeral key. Ephemeral matters: dead
  VMs auto-leave the tailnet, otherwise corpses pile up as offline nodes.
- `SSH_PUBKEY` = ed25519 public key for agent SSH logins.
- `VNC_PASSWORD` = exactly 8 chars (classic VNC truncates beyond 8).
- `RDP_PASSWORD` = Windows `Builder` account password.
- `protected-cloud` environment exists with NO reviewers (test mode).
  Add required reviewers before treating any session as production.

## Validate before pushing (executable, not optional)

```
python tools/validate-workflows.py
python tools/validate-docs.py
```
`validate-workflows.py` YAML-parses every workflow, then syntax-checks each
step's script block: PowerShell via the .NET parser, bash via `bash -n`.
`${{ }}` expressions are stubbed before parsing. Must be 38/38.

`validate-docs.py` checks every markdown file for non-ASCII characters,
broken internal links, and leaked secret values (passwords, auth keys,
tailnet IPs). Must report "all clean".

Keep files ASCII-only - non-ASCII comment art once broke Windows YAML reads.

## Verified gotchas (do not relearn)

- Empty `workflow_dispatch` inputs get replaced by the input `default`.
  Guards must exclude both `''` and the placeholder string, and
  `private_repo` defaults must be `""`. (A full Windows run once failed
  cloning `YOUR_USERNAME/YOUR_PRIVATE_REPO` because of this.)
- Mid-run logs are unreadable via CLI/API: `gh run view --log` refuses
  in-progress runs and the jobs/logs API 404s until completion. Use the web
  UI live log, or verify from the tailnet side (`tailscale status` here;
  peer hostnames embed run IDs: `mac-builder-<id>`, `build-verify-<id>`).
- Cancelled runs have NO retrievable logs via API. Read the live log before
  cancelling, or you lose the evidence permanently.
- macOS `kickstart -setvncpw` does NOT store the legacy VNC password (flag
  and stdin-pipe forms both tried). The server offers classic VNCAuth
  (type 2) but rejects every password. Apple user auth DOES work, but only
  if the system password was set via `sysadminctl` in the same run.
  Handshake offers `[30,33,36,2,35]`.
- Windows Tailscale MSI install takes minutes. Not a hang - the step is
  bounded except download/install/`up`.
- `ubuntu-latest` runners expose `/dev/kvm` (verified) - hardware-accelerated
  Android emulators work there.
- Do NOT use `android-actions/setup-android@v3` on current runner images: it
  runs `sdkmanager tools`, which no longer exists, and fails the job. The
  Android SDK is preinstalled; accept licenses and let Gradle download what
  it needs.
- `reactivecircus/android-emulator-runner` executes its `script` line by
  line with `/usr/bin/sh` (dash), not bash. Multi-line `if` blocks and
  variable assignments do not persist between lines, and `set -o pipefail`
  dies with "Illegal option -o pipefail". Generate a script file in a prior
  step and call `bash "$RUNNER_TEMP/emu-test.sh"` as a one-line script, or
  keep every line standalone and bash-free.

## SSH (agents operate the VMs directly from this PC)

Session VMs join Tailscale and run SSH on port 22: Windows = OpenSSH Server
(PowerShell default shell), macOS = Remote Login. Linux via headless runs or
your own Azure VM. Key auth: local key `~/.ssh/cloud-builder`, pubkey in
`SSH_PUBKEY`, installed at boot.

- Windows gotcha (verified live): members of Administrators IGNORE the
  per-user `authorized_keys` - the key must ALSO go in
  `C:\ProgramData\ssh\administrators_authorized_keys` (SYSTEM-owned,
  inheritance stripped), or key auth fails closed.
- Direct form: `ssh -i ~/.ssh/cloud-builder -o BatchMode=yes Builder@<ip>`
  (Windows) or `runner@<ip>` (macOS). Never launch GUI `mstsc` from scripts.

## CLI (`cli/cloudvm.ps1`)

```
cloudvm status                       # runs + online session VMs
cloudvm up --os windows|mac [--hours N]
cloudvm ssh [--os ..] [-c "cmd"]     # -c runs one command; no -c = interactive
cloudvm push <local> <remote>        # scp file TO the VM
cloudvm pull <remote> <local>        # scp file FROM the VM
cloudvm down [--os ..]               # cancel sessions only (never headless builds)
cloudvm build --repo owner/name [--branch B] [--runner R]
```

Two traps baked into the design: no `param()` block (a declared one makes
PowerShell reject unknown `--flags` before the script runs), and remote
commands use `-c "cmd"` because PowerShell swallows a bare `--` itself.
`down` matches by workflow name: `*Mac*` vs `*Cloud VM*`.
