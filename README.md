# learn-agent-sandbox

**Build the sandbox your AI agent runs in — from `docker run` to a microVM that forks in milliseconds.**

[English](README.md) · [中文](README.zh.md)

> ⚠️ **Status: early.** The design is settled and chapters are being written.
> See the [chapter table](#chapters) for what is available today.

---

## The code your agent runs has never been reviewed by anyone

For twenty years, every isolation technology we built rested on one assumption:
**the code being executed was written by a human, reviewed by a human, and deployed
on purpose.** Containers, namespaces, cgroups, seccomp — all of it was designed for
a world where you trusted the code and distrusted the input.

Agents break that assumption.

An agent writes code at runtime and executes it immediately. No review, no deploy
step, no human in the loop. And if the agent is reachable by prompt injection, the
*intent* behind that code may not even be yours.

The trust model inverts: **the code itself is now untrusted.**

That single inversion is why the sandbox stopped being an ops detail and became a
load-bearing piece of architecture. This repository is about building one — from the
container you already know, up to a microVM that boots from a snapshot, forks, and
runs a real agent inside.

---

## What you will build

```
  s00              s01 ─ s02          s03 ─ s04 ─ s05 ─ s06        s07
  ┌────────┐      ┌────────────┐     ┌──────────────────────┐    ┌────────┐
  │ Docker │  ──▶ │ Firecracker│ ──▶ │  your orchestrator   │──▶ │ agent  │
  │  the   │      │  microVM   │     │  fork · exec · net   │    │  runs  │
  │  wall  │      │  snapshot  │     │                      │    │  in it │
  └────────┘      └────────────┘     └──────────────────────┘    └────────┘
   shell           shell + curl        Go · Rust · shell          Python

   "why this        "don't boot.        "control plane,          "now hand it
    isn't enough"     restore."          data plane"               to an agent"
```

Each chapter stands on its own. Stop wherever you have what you came for.

---

## Chapters

| # | Chapter | You walk away with | Lang | Needs KVM | Status |
|---|---------|--------------------|------|:---------:|:------:|
| **s00** | Your container is not a sandbox | Direct evidence that your container shares the host kernel | shell | **no** | 🚧 |
| **s01** | A virtual machine in 125 ms | A real Firecracker microVM, booted by hand, timed | curl | yes | 🚧 |
| **s02** | **Don't boot. Restore.** | The two numbers: cold boot vs. snapshot restore | curl | yes | 🚧 |
| **s03** | Control plane, data plane, never mixed | An HTTP service that starts and stops sandboxes | Go | yes | 🚧 |
| **s04** | Fork the machine, not the process | N sandboxes forked from one snapshot, running in parallel | Go | yes | 🚧 |
| **s05** | Someone has to be inside | A tiny static binary in the guest you can `exec` into | Rust | yes | 🚧 |
| **s06** | Now let it reach the internet | tap devices, NAT, port forwarding | Go | yes | 🚧 |
| **s07** | Now hand it to an agent | A Python SDK, and a coding agent living on your own sandbox | Python | yes | 🚧 |

**s02 is the one to read** if you only read one. Snapshot restore is why a sandbox can
start in milliseconds instead of seconds, and understanding it makes every agent-sandbox
product on the market suddenly legible.

---

## Why the languages change

Each layer uses the language that layer actually uses in production:

| Layer | Here | In the wild |
|-------|------|-------------|
| Orchestration / control plane | **Go** | E2B `packages/orchestrator`, containerd, Kubernetes, gVisor |
| In-guest agent | **Rust** | E2B's `envd` is Go — we pick Rust on purpose, and s05 explains the trade-off |
| SDK | **Python** | E2B's SDKs, and essentially all of them |
| The VMM itself (not built here) | — | Firecracker, Cloud Hypervisor, crosvm — all Rust |

Walking the whole stack is the only way to learn *why* the industry splits it this way.

---

## Requirements

Firecracker needs hardware virtualization. This is the honest matrix:

| Environment | Works | Note |
|-------------|:-----:|------|
| Linux, bare metal or VM with nested virt | ✅ | the reference setup |
| WSL2 on Windows 11 | ✅ | nested virtualization must be enabled |
| macOS (Intel or Apple Silicon) | ❌ | no `/dev/kvm`; use a Linux cloud host |
| GitHub Codespaces / most CI | ❌ | nested virtualization generally unavailable |

**s00 requires only Docker** — everyone can do chapter one.

Check where you stand:

```bash
git clone https://github.com/yidianyiko/learn-agent-sandbox
cd learn-agent-sandbox
./scripts/check-env.sh
```

It tells you how far up the ladder your machine can go, and what to install for the rest.

---

## What this is not

This is a **teaching repository**. It is deliberately missing everything that would
make it a product:

- multi-tenancy and authorization
- billing, quotas, rate limiting
- multi-node scheduling
- a web UI
- production hardening, auditing, monitoring
- a template build system
- performance tuned beyond "you can see why it's fast"

Each chapter's code stays under 300 lines, because code you can read in one sitting is
the only code that teaches.

**When you outgrow this repo, go use [E2B](https://e2b.dev) — or fork
[`e2b-dev/runtime`](https://github.com/e2b-dev/runtime), which is Apache-2.0 and is the
production system this repo is a scale model of.** Every chapter ends by pointing at the
file in that codebase where the real version lives.

---

## Prior art worth your time

- [`e2b-dev/runtime`](https://github.com/e2b-dev/runtime) — the production system, in Go
- [`firecracker-microvm/firecracker`](https://github.com/firecracker-microvm/firecracker) — the VMM, and its [NSDI '20 paper](https://www.usenix.org/conference/nsdi20/presentation/agache)
- [`shareAI-lab/learn-claude-code`](https://github.com/shareAI-lab/learn-claude-code) — the layer above this one: how the agent itself is built

---

## License

MIT
