# Documentation index

| Doc | Purpose |
|---|---|
| [architecture.md](architecture.md) | Components, runner topologies, trust boundaries, lifecycle |
| [data-flow.md](data-flow.md) | What happens to source, secrets, and artifacts, in order |
| [diagrams.md](diagrams.md) | ASCII and Mermaid views of every flow |
| [security.md](security.md) | Threat model, access layers, secret handling, known gaps |
| [workflows.md](workflows.md) | Per-workflow reference: inputs, outputs, gates, steps |
| [cli.md](cli.md) | `cloudvm.ps1` command reference and recipes |
| [remote-access.md](remote-access.md) | SSH, RDP, VNC, browser access, troubleshooting |
| [runbook.md](runbook.md) | Operational procedures and symptom lookup |
| [decisions.md](decisions.md) | Why the system works this way, with the evidence |
| [android-device-testing.md](android-device-testing.md) | APK testing across many devices, $0 |
| [multi-agent.md](multi-agent.md) | Two-agent handoff protocol over files and git |
| [cost.md](cost.md) | What is free, what costs, hard limits |

Start with [architecture.md](architecture.md) for the shape of the system,
then [data-flow.md](data-flow.md) for what happens to your code.

Agent-facing rules live in the repo root [AGENTS.md](../AGENTS.md) - that file
is what a coding session reads first.

## Conventions

- Every factual claim here was verified against a live run or a live API
  response. Where something is an estimate or a plan, it says so.
- No secret values appear in any of these files. Secret *names* and their
  required properties are documented; the values are write-only in GitHub.
- Diagrams are plain ASCII so they survive a terminal, plus Mermaid blocks
  for rendering.
- Gotchas in [runbook.md](runbook.md) and [decisions.md](decisions.md) are
  real - each one cost a failed run.
