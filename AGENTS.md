# AGENTS.md — my-builder (public cloud-CI builder)

Public repo holding ONLY GitHub Actions workflows. No source code lives here, ever.
Private repos are cloned at runtime via token, built on cloud VMs, artifacts
uploaded, source wiped. Local working copy: `C:\Users\prati\public-repo-builder`.

## Account rules (critical — violations have caused 403s before)

- `gh` active account MUST be `codebox1230`. Never use `CodeSmithPratik`
  or `special28` for this repo. Verify: `gh api user -q .login`
- After `gh auth switch --user codebox1230`, run `gh auth setup-git`,
  or `git push` silently authenticates as the stale cached account and fails.
- Commit identity: `user.name=codebox1230`,
  `user.email=codebox1230@users.noreply.github.com`.

## Workflows (`.github/workflows/`)

- `build-private.yml` — headless build, no desktop. Runner picker:
  `ubuntu-latest` / `windows-2022` / `macos-latest` / `cirun-*`.
  Manual `workflow_dispatch` or `repository_dispatch`. Requires
  `PRIVATE_REPO_TOKEN` — `actions/checkout` hard-errors on an empty token.
- `rdp-cloud-vm.yml` — Windows RDP over Tailscale/Cloudflare. Gate: `authorize`
  job (actor must be owner or in `ALLOWED_ACTORS`) + `protected-cloud`
  environment. RDP user `Builder`, NLA + TLS enforced, cleanup always runs.
- `mac-screen.yml` — macOS Screen Sharing over Tailscale. Same gates plus
  `concurrency: mac-screen-session` (one session at a time; new dispatches
  queue). Browser-link step exists but defaults off.

## Secrets (names only — values are write-only, unrecoverable by design)

- `ALLOWED_ACTORS` = `codebox1230`
- `PRIVATE_REPO_TOKEN` = TEMPORARY broad OAuth token. Replace with a
  fine-grained PAT (Contents: Read-only, scoped to the private repos).
- `TAILSCALE_AUTHKEY` = reusable + ephemeral key. Ephemeral matters: dead
  VMs auto-leave the tailnet, otherwise corpses pile up as offline nodes.
- `VNC_PASSWORD` = 8 chars max (classic VNC truncates beyond 8).
- `RDP_PASSWORD` = Windows `Builder` account password.
- `protected-cloud` environment exists with NO reviewers (test mode).
  Add required reviewers before treating any session as production.

## Verified gotchas (earned the hard way — do not relearn)

- Empty `workflow_dispatch` inputs get replaced by the input `default`.
  Guards must exclude both `''` and the placeholder string, and
  `private_repo` defaults must be `""`. (A full Windows run once failed
  cloning `YOUR_USERNAME/YOUR_PRIVATE_REPO` because of this.)
- Mid-run logs are unreadable via CLI/API: `gh run view --log` refuses
  in-progress runs and the jobs/logs API 404s until completion. Use the
  web UI live log, or verify from the tailnet side (`tailscale status`
  on this PC; peer hostnames embed run IDs: `mac-builder-<id>`).
- Cancelled runs have no retrievable logs via API. Diagnose from live
  logs before cancelling, or not at all.
- macOS `kickstart -setvncpw` does NOT store the legacy VNC password here
  (flag form and stdin-pipe form both tried across multiple runs).
  The server offers classic VNCAuth (type 2) but rejects every password.
  Apple user auth DOES work, but only if the system password was set via
  `sysadminctl` in the same run. Server handshake offers `[30,33,36,2,35]`.
- Windows Tailscale MSI install is slow (minutes). Don't mistake it for
  a hang; the step is bounded except download/install/`up`.
- Keep files ASCII-only. Non-ASCII comment art once broke Windows YAML reads.

## SSH access (agents operate VMs from here)

- Session VMs join Tailscale and run SSH: Windows = OpenSSH Server
  (PowerShell default shell) on port 22, macOS = Remote Login.
- Key auth: local key `~/.ssh/cloud-builder`, pubkey in `SSH_PUBKEY` secret,
  installed to `authorized_keys` at boot.
- Windows gotcha (verified live): members of Administrators IGNORE the
  per-user `authorized_keys` — the key must ALSO go in
  `C:\ProgramData\ssh\administrators_authorized_keys` (SYSTEM-owned,
  inheritance stripped), or key auth fails closed.
- From here: `ssh -i ~/.ssh/cloud-builder -o BatchMode=yes Builder@<ip>`
  (Windows) or `runner@<ip>` (macOS). Peer IPs via `tailscale status`;
  hostnames embed run IDs. Never launch GUI `mstsc` sessions from scripts.

## CLI (`cli/cloudvm.ps1`)

Single-file PowerShell CLI over `gh` + Tailscale + OpenSSH. No param()
block on purpose (`--flags` must flow through as plain strings; also
PowerShell swallows a bare `--`, so remote commands use `-c "..."`).
Commands: `status` | `up --os windows|mac [--hours N]` |
`ssh [--os ..] [-c "cmd"]` (no `-c` = interactive) |
`push <local> <remote>` / `pull <remote> <local>` |
`down [--os ..]` (matches by workflow name: `*Mac*` vs `*Cloud VM*`,
never touches headless builds) | `build --repo owner/name ...` (waits,
downloads artifacts to `.cloud-build-artifacts/<run-id>/`).

## Before pushing workflow changes

1. YAML-parse every file as UTF-8; PowerShell blocks via the .NET parser,
   bash blocks via `bash -n` (strip `${{ }}` expressions first).
2. Commit one idea per commit, push to `main` — new dispatches use the
   new file immediately. No PR process on this repo.
