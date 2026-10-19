# Security

## Threat model

| Adversary | Wants | Mitigation |
|---|---|---|
| Random internet scanner | RDP/SSH on the VM | No public IP, no inbound ports; tailnet only |
| Fork PR author | Run code on the runner | `workflow_dispatch` only - no `pull_request` trigger; secrets not exposed to forks |
| Leaked token | Clone private source | Fine-grained PAT, Contents:Read-only, repo-scoped, expirable |
| Tailnet neighbour | Reach the VM | Tailscale ACLs + key auth; ephemeral nodes leave when the VM dies |
| Other repo on the account | Read this repo's secrets | Secrets are repo-scoped, not account-scoped |
| Artifact snooper | Read build outputs | Artifact access follows repo visibility rules |

## Access control layers

Applied to the two interactive workflows (`rdp-cloud-vm.yml`, `mac-screen.yml`):

```
1. workflow_dispatch only        forks and PRs cannot trigger
2. authorize job                 actor must be owner or in ALLOWED_ACTORS
3. protected-cloud environment   requires reviewer approval
4. concurrency lock              one Mac session at a time
5. key + password auth           SSH ed25519; RDP NLA + TLS
6. tailnet-only reachability     no public IP, no inbound internet
7. unconditional cleanup         source removed even if the job crashes
```

### Layer 2: actor check

```yaml
ACTOR="${{ github.actor }}"
OWNER="${{ github.repository_owner }}"
ALLOWED="${{ secrets.ALLOWED_ACTORS }}"
# owner always passes; others only if listed
```

GitHub sets `github.actor` to whoever initiated the run, and it cannot be
forged by workflow content. A fork PR has a different actor and, more
importantly, cannot trigger `workflow_dispatch` at all.

### Layer 3: environment gate

`protected-cloud` exists but **currently has no required reviewers**. Until
you add yourself as a reviewer, this layer is inert. Add reviewers at
*Settings > Environments > protected-cloud > Required reviewers*.

## Secret handling

- Values are encrypted client-side with **libsodium sealed boxes**
  (`crypto_box_seal`) using the repo's public key. Only GitHub's runtime
  holds the private key.
- `GET /repos/{owner}/{repo}/actions/secrets` returns only `name`,
  `created_at`, `updated_at`. There is no value field to read.
- Secrets are injected as job-scoped environment variables and masked
  (`***`) in all logs.
- **A lost secret cannot be recovered.** Only remedy: generate a new
  credential at the provider and overwrite the secret.

### Secret inventory and least privilege

| Secret | Scope | Should be | Currently |
|---|---|---|---|
| `PRIVATE_REPO_TOKEN` | private repo, Contents:Read | fine-grained PAT, repo-scoped | **temporary broad OAuth token - replace** |
| `TAILSCALE_AUTHKEY` | tailnet | reusable + ephemeral, short expiry | reusable + ephemeral |
| `SSH_PUBKEY` | public key | not a secret | correct |
| `VNC_PASSWORD` | session | 8 chars (protocol limit) | correct |
| `RDP_PASSWORD` | session | strong, unique | correct |
| `ALLOWED_ACTORS` | list of usernames | not a secret | correct |

The broad OAuth token currently in `PRIVATE_REPO_TOKEN` has `repo` +
`workflow` scopes across the whole account. It is encrypted and private, but
it is over-privileged. Replace it:

1. github.com > Settings > Developer settings > Personal access tokens >
   Fine-grained > Generate
2. Repository access: Only select repositories -> pick the private repos
3. Permissions: Contents -> Read-only
4. Expiry: 90 days or less
5. `gh secret set PRIVATE_REPO_TOKEN --repo codebox1230/my-builder`

## Network posture

Every tunnel is **outbound-only**. The VM dials out; nothing dials in.

```
VM --outbound HTTPS:443--> GitHub API (polls for jobs)
VM --outbound UDP:41641--> Tailscale control + peers (WireGuard)
VM --outbound HTTPS:443--> Tailscale coordination
```

Consequences:
- No Azure NSG rule exposing 22 or 3389 to the internet.
- No public IP needed for a session VM.
- `tailscale status` from your device is the ground truth for reachability.

## RDP hardening (Windows)

| Setting | Value | Why |
|---|---|---|
| `fDenyTSConnections` | 0 | RDP enabled |
| `UserAuthentication` | 1 | NLA - credentials required *before* the session starts |
| `SecurityLayer` | 2 | TLS handshake, not plaintext |
| `MinEncryptionLevel` | 3 | 128-bit |

The original workflow this was based on disabled NLA and used plaintext
handshake. Both were flipped.

## SSH hardening

- ed25519 key auth only for agents; the key never leaves `~/.ssh`.
- Windows: OpenSSH Server with PowerShell as the default shell.
- **Windows admin quirk:** members of the Administrators group have their
  per-user `authorized_keys` **ignored** by sshd. The key must also be in
  `C:\ProgramData\ssh\administrators_authorized_keys`, owned by SYSTEM with
  inheritance stripped, or key auth fails closed with no useful error.
- Password auth also works as a fallback for humans.

## Known gaps

| Gap | Impact | Fix |
|---|---|---|
| `protected-cloud` has no reviewers | anyone with write access can start a session VM | add yourself as required reviewer |
| `PRIVATE_REPO_TOKEN` is over-scoped | a leak exposes the whole account | fine-grained PAT (above) |
| Public repo reveals workflow internals | attackers learn the pattern | by design; nothing secret is committed |
| Session VMs are not isolated from each other | one session could probe another | separate tailnets or ACLs per session |
| VNC password is 8 chars | protocol limit, brute-forceable | keep sessions short; prefer SSH |

## Reporting

Do not open a public issue for a suspected vulnerability in this repo. Use
GitHub's private vulnerability reporting for the repo.
