# Runbook

Operational procedures and symptom-to-cause lookup.

## Daily commands

```powershell
cloudvm status                      # what is alive
gh run list --repo codebox1230/my-builder --limit 10
tailscale status                    # tailnet view
```

## Starting a session

```powershell
cloudvm up --os windows --hours 2    # or --os mac
```

Takes 3-5 minutes: GitHub provisions the VM, installs the toolchain,
installs Tailscale, joins the tailnet, enables remote access.

If it times out, the run is still going - check it:

```bash
gh run view <run-id> --repo codebox1230/my-builder
```

## Ending a session

```powershell
cloudvm down            # all sessions
cloudvm down --os mac   # one OS
```

**Read the live log before cancelling.** Cancelled runs have no retrievable
logs via the API - you lose the evidence permanently. Check the run in the
Actions UI first.

## Symptom lookup

| Symptom | Root cause | Fix |
|---|---|---|
| `Input required and not supplied: token` | empty `PRIVATE_REPO_TOKEN` | `gh secret set PRIVATE_REPO_TOKEN --repo codebox1230/my-builder` |
| Clone fails with `Repository not found` | token does not include that repo | add it to the PAT's repository list |
| Clone tries `YOUR_USERNAME/YOUR_PRIVATE_REPO` | dispatch default substituted for your empty input | pass a real repo, or leave `private_repo` unset |
| Workflow does not appear in the Actions tab | YAML invalid | `python tools/validate-workflows.py` |
| `gh push` fails with 403 | git using the wrong cached account | `gh auth switch --user codebox1230` then `gh auth setup-git` |
| `Permission denied (publickey)` on SSH | Windows admin key file missing | see [remote-access.md](remote-access.md) |
| `No session VM online` from the CLI | VM never joined the tailnet | `gh run view` -> read the Tailscale step |
| Tailscale step appears hung | MSI install takes minutes | wait; the step is bounded except download/install/`up` |
| VNC `Authentication failure` | password wrong | it is exactly 8 characters |
| VNC `Security negotiation failed` | client forced Apple auth | use TigerVNC, not RealVNC |
| Browser link page is blank | missing mouse move | click-drag on the canvas to force a redraw |
| `importKey` error in noVNC | page served over plain HTTP | browser needs HTTPS for `crypto.subtle` |

## Reading logs

**During a run** - the CLI cannot. Use the web UI:

```
https://github.com/codebox1230/my-builder/actions
  -> click the run -> click a step -> expand
```

**After a run**:

```bash
gh run view <run-id> --repo codebox1230/my-builder --log
```

**Never available**: logs for cancelled runs (API 404s), and mid-run logs
through the API (the blob is not published until completion).

## Triage a failed build

```bash
gh run view <run-id> --repo codebox1230/my-builder --log-failed
```

Then ask: did it fail in checkout (token), build (your code), artifact upload
(disk space / 14 GB runner limit), or cleanup (rare)?

## Disk pressure on runners

Standard runners have 14 GB. The base image already uses several GB. If a
build fails with disk exhaustion:

- prune Docker: `docker system prune -af`
- clean Gradle: `rm -rf ~/.gradle/caches`
- clean npm: `npm cache clean --force`
- check what the artifact step will actually upload - a 10 GB artifact set
  will fail on both disk and artifact size limits

## Rotating credentials

| Credential | How to rotate |
|---|---|
| `PRIVATE_REPO_TOKEN` | generate a new fine-grained PAT, `gh secret set PRIVATE_REPO_TOKEN --repo ...` |
| `TAILSCALE_AUTHKEY` | Tailscale admin > Settings > Keys > generate (reusable + ephemeral), `gh secret set TAILSCALE_AUTHKEY --repo ...` |
| `SSH_PUBKEY` | `ssh-keygen -t ed25519 -f ~/.ssh/cloud-builder -N '""'`, `gh secret set SSH_PUBKEY --repo ...` |
| `RDP_PASSWORD` | `gh secret set RDP_PASSWORD --repo ...` (next session picks it up) |
| `VNC_PASSWORD` | `gh secret set VNC_PASSWORD --repo ...` - **max 8 characters** |

All of these are write-only. You cannot read the current value back.

## Recovering a dead local clone

The local working copy IS the git repo:

```powershell
git -C C:\Users\prati\public-repo-builder status
git -C C:\Users\prati\public-repo-builder fetch origin
git -C C:\Users\prati\public-repo-builder reset --hard origin/main
```

This discards local edits - back up anything uncommitted first.

## Housekeeping

- Dead tailnet nodes accumulate if the auth key is not ephemeral. Delete
  offline ones at admin.tailscale.com > Machines.
- `.cloud-build-artifacts/` grows with every `cloudvm build`. Clean it
  periodically.
- `private-repo-trigger/` and `infra/` are local-only by design. If you
  clone fresh, they are gone - restore from wherever you keep them.
