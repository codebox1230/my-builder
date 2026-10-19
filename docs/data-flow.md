# Data flow

What happens to your source, your secrets, and your artifacts - in order.

## 1. Trigger

Two entry points. Neither can be reached by a fork.

| Trigger | Who | Minutes used |
|---|---|---|
| `workflow_dispatch` | you, in the Actions UI or via `gh` | public repo = unlimited |
| `repository_dispatch` | a push to a private repo, via `private-repo-trigger/` | private repo ~10 s |

```
git push (private repo)
      |
      v
trigger-build.yml  --runs on ubuntu-latest for ~10s-->  POST /dispatches
      |
      v
public repo receives repository_dispatch  -->  build-private.yml job queued
```

The private repo spends ~10 seconds of its own allowance. Everything after
that is free and unlimited.

## 2. Authorization (before any compute)

```
authorize job (ubuntu-latest, ~5s)
  |
  |- github.actor == repo owner ?        --yes--> authorized
  |- github.actor in ALLOWED_ACTORS ?    --yes--> authorized
  +- otherwise                            -------> DENIED, job fails, no VM
```

Then the `protected-cloud` environment gate. With reviewers configured, the
run pauses until you approve it. (Currently it has no reviewers - test mode.)

## 3. Secret injection

This is the only moment your credentials exist outside your machine.

```
  your laptop                     GitHub
  -----------                     ------
  gh secret set PRIVATE_REPO_TOKEN
       |
       |  fetch repo public key
       |  crypto_box_seal(value)      <-- encryption happens on YOUR side
       v
  ciphertext ---------------------> sealed box in GitHub's secret store
```

- The API can never return a secret value back. `GET /actions/secrets`
  returns names and timestamps only - no `value` field exists.
- At job start, the runner decrypts into job memory and exposes it as an
  environment variable. The workflow references it as
  `${{ secrets.NAME }}`.
- If any step prints it, GitHub's log redaction replaces it with `***`.
- The value is gone when the job ends. There is no "read it back" - only
  overwrite with a new value.

## 4. Clone

```
VM                                         github.com
--                                          ----------
git clone --depth 1 \
  https://x-access-token:${TOKEN}@          --> authenticate (token)
  github.com/owner/private.git               --> contents:read granted
                                              --> returns tree
                                          <-- source tree
```

`actions/checkout@v4` does the same thing with `repository:` + `token:` inputs.
It hard-fails with `Input required and not supplied: token` if the token is
empty - a useful guard, but it means a missing secret looks like a checkout
error rather than an auth error.

Shallow clone (`--depth 1`) keeps it fast. The VM never sees the full history
unless you ask for it.

## 5. Build

```
private-code/
   |
   |- auto-detect: .sln / .csproj / package.json / Cargo.toml /
   |              go.mod / pyproject.toml / CMakeLists.txt /
   |              Makefile / *.xcodeproj / *.xcworkspace / Package.swift
   |
   +- or your explicit build_command
```

Toolchains already present on GitHub-hosted runners: Node 20, Python 3.12,
OpenJDK 17, Go, .NET SDK, Xcode. No toolchain install step needed unless you
need a specific version.

## 6. Artifacts

```
VM                                    GitHub artifact storage
--                                    ----------------------
upload-artifact@v4  --------------->  build-output-<run_number>
  retention-days: 30                    retained 90 days default,
                                        deleteable, repo-scoped
```

For public repos, artifact and package storage is free and does not count
against the private-repo quota.

## 7. Cleanup (unconditional)

```
if: always()
   |- rm -rf $WORKSPACE/private-code     source gone from disk
   |- tailscale logout                   node leaves the tailnet
   |- tailscale funnel --off 6080        public link closed
   +- GitHub deallocates the VM          disk destroyed with it
```

Because the VM is destroyed rather than reused, "cleanup" is belt-and-braces.
The real guarantee is that no source survives on a machine you do not own.

## Data classification

| Item | Where it lives | Lifetime |
|---|---|---|
| your source | private repo -> VM disk | deleted at job end |
| `PRIVATE_REPO_TOKEN` | GitHub secret store -> job memory | job duration |
| `SSH_PUBKEY` | GitHub secret store -> VM file | job duration |
| Tailscale auth key | GitHub secret store -> job memory | job duration |
| build artifacts | GitHub artifact storage | 30 days (configurable) |
| Tailscale node | tailnet | until VM dies (ephemeral key auto-removes) |
| RDP/VNC session | tailnet only | until job ends |

## What never leaves the private repo

- No source is committed to the public repo, ever.
- No source is pushed to any third-party service.
- Artifacts are build outputs, not source - unless your build step copies
  source into the artifact path. Review what you upload.
