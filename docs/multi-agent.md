# Multi-agent handoff

Running two agents: one that edits code locally, one that runs builds in the
cloud. They cannot message each other, so they coordinate through the
filesystem and git.

## The core constraint

**The cloud VM only sees what is committed and pushed.** A local file that
was never pushed is invisible to the build. Every handoff must respect this.

```
uncommitted local edit --X--> cloud VM
        |
        +- must be committed + pushed first
```

## Roles

| Agent | Runs where | Does | Must not |
|---|---|---|---|
| **A - author** | your machine | edit code, commit, push, request builds, read results | compile, build, or test locally |
| **B - runner** | your machine (or another agent's) | dispatch cloud builds, collect artifacts, write results | edit the source |

Agent B does not need to be a different process. It can be a second session
of the same tool, a different tool entirely, or a scheduled job.

## The protocol

A file-based inbox inside the project:

```
my-project/
|-- .cloud-build/
|   |-- request.json      A writes, B reads
|   +-- result.json       B writes, A reads
+-- .cloud-build-artifacts/
    +-- <run-id>/         B downloads here
```

### request.json (written by A)

```json
{
  "repo": "owner/my-project",
  "branch": "ci/build-20261005-1430",
  "sha": "abc1234def",
  "runner": "ubuntu-latest",
  "build_command": "",
  "artifact_path": "",
  "status": "pending",
  "requested_by": "coding-agent",
  "requested_at": "2026-10-05T14:30:00Z"
}
```

### result.json (written by B)

```json
{
  "status": "done",
  "run_id": 38058478219,
  "conclusion": "success",
  "artifacts_dir": ".cloud-build-artifacts/38058478219",
  "finished_at": "2026-10-05T14:33:12Z"
}
```

`status` is the handshake: `pending` means B should act, `done` means A can
proceed, `failed` means A should read the conclusion and fix the code.

## Standing orders

### For agent A

```
1. Edit code. Never build, never test locally.
2. Commit to a ci/build-<timestamp> branch. Push.
3. Write .cloud-build/request.json with status=pending.
4. Stop and wait.
5. When result.json says done: read the artifacts, continue.
6. When it says failed: read the conclusion, fix, repeat from 2.
```

### For agent B

```
1. Watch .cloud-build/request.json for status=pending.
2. Dispatch:  gh workflow run build-private.yml --repo codebox1230/my-builder
                 -f repo=<request.repo> -f branch=<request.branch>
                 -f runner=<request.runner>
3. Wait for the run to complete.
4. Download artifacts into .cloud-build-artifacts/<run-id>/.
5. Write result.json with status=done (or failed) + conclusion.
6. Report to the human.
```

## The critical instruction: A must never build locally

Put it in agent A's `AGENTS.md`, in its own project folder:

```markdown
## Build policy (mandatory)

- NEVER compile, build, or run test suites on this local machine.
  No `cargo build`, `npm run build`, `xcodebuild`, `go build`, `dotnet build`.
- All builds run in the cloud. To build:
    gh workflow run build-private.yml --repo codebox1230/my-builder \
      -f repo=<owner>/<this-repo> -f branch=<branch> -f runner=<runner>
- Then poll for completion and download artifacts:
    gh run download <run-id> --repo codebox1230/my-builder
- Local commands allowed: reading, editing, linting single files, git only.
```

Instructions can be ignored. If the agent supports command hooks, enforce it
at the tool layer by intercepting build commands and redirecting them to the
cloud. Two belt-and-braces layers: policy plus hook.

Do **not** implement this by sensing battery level or CPU load. Those are
racy and inconsistent. The policy is "never build here", not "build here when
the battery is low".

## Requirements checklist

| Requirement | Needed for | Notes |
|---|---|---|
| Project is a git repo with a GitHub remote | both | `git remote -v` shows `github.com:owner/repo` |
| Branch pushed before requesting | both | cloud sees pushed state only |
| `PRIVATE_REPO_TOKEN` covers that repo | B | fine-grained PAT listing each private repo |
| `ALLOWED_ACTORS` includes agent B's identity | B | if B triggers via `gh` |
| `.cloud-build/` writable by both | both | |
| `PUBLIC_REPO_DISPATCH_TOKEN` in the private repo | optional | only for automatic push-triggering |

**Public or private repo?** Private is fine - that is the entire point. The
token authenticates the clone, so the payload repo can be private while the
workflow repo stays public. The public repo needs only the workflow files.

## Two ways to hand off a change

| Method | When | Trade-off |
|---|---|---|
| **commit-then-build** (recommended) | anything worth keeping | clean history, reproducible, the cloud builds exactly what is in git |
| **patch handoff** | throwaway experiments | write `git diff > changes.patch`, cloud clones base and applies it. No extra commits, but fragile if the base moved |

## Why not just let agent A build locally?

- CPU spikes and battery drain on your machine - the thing this whole
  project exists to avoid.
- The runner may not have the toolchain, or a different version than the
  cloud has.
- Results are not reproducible: local state (caches, env, uncommitted
  patches) leaks into the build.
- A cloud build is also a clean-room check: it proves the code works from a
  fresh clone with no local surprises.

## Adding agent B to this repo

`cloudvm.ps1` already provides most of agent B's mechanics:

```powershell
cloudvm build --repo owner/my-project --branch ci/build-20261005-1430 --runner ubuntu-latest
```

That waits for the run and downloads artifacts. Wrap it with the
request/result JSON files and agent B is done.
