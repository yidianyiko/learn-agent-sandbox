# learn-agent-sandbox

[![ci](https://github.com/yidianyiko/learn-agent-sandbox/actions/workflows/ci.yml/badge.svg)](https://github.com/yidianyiko/learn-agent-sandbox/actions/workflows/ci.yml)

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
  s00           s01 ─ s02 ─ s03        s04 ─ s05 ─ s06 ─ s07        s08
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
| **s00** | [Your container is not a sandbox](s00_shared_kernel/) | Direct evidence that your container shares the host kernel | shell | **no** | ✅ |
| **s01** | [A kernel of its very own](s01_first_microvm/) | A real Firecracker microVM booted by hand — and where its boot time actually goes | curl | yes | ✅ |
| **s02** | [Write the hypervisor yourself](s02_write_a_vmm/) | A working VMM in 79 lines, and a measured answer to what the other 120,000 do | **C** | yes | ✅ |
| **s03** | [**Don't boot. Restore.**](s03_snapshot_restore/) | Snapshot/restore written by hand, then the two numbers: 2659 ms vs 16 ms | **C** + curl | yes | ✅ |
| **s04** | [Control plane, data plane, never mixed](s04_orchestrator/) | A registry that survives being shot, and rediscovers what it was running | **Go** | yes | ✅ |
| **s05** | [Fork the machine, not the process](s05_fork_parallel/) | Six 256 MiB VMs in 76 MB, because one `mmap` flag shares what they have not changed | **C** + shell | yes | ✅ |
| **s06** | Someone has to be inside | A tiny static binary in the guest you can `exec` into | Rust | yes | 🚧 |
| **s07** | Now let it reach the internet | tap devices, NAT, port forwarding | Go | yes | 🚧 |
| **s08** | Now hand it to an agent | A Python SDK, and a coding agent living on your own sandbox | Python | yes | 🚧 |

**s00 requires only Docker** — everyone can do chapter one.

Check where you stand:

```bash
git clone https://github.com/yidianyiko/learn-agent-sandbox
cd learn-agent-sandbox
./scripts/check-env.sh
```

It tells you how far up the ladder your machine can go, and what to install for the rest.

---

## What is deliberately left out

Some things are missing here not because they are hard, but because they are **volume,
not insight** — they would cost ten times the effort and teach nothing new:

- multi-tenancy and authorization
- billing, quotas, rate limiting
- multi-node scheduling
- a web UI
- production hardening, auditing, monitoring
- a template build system

**Every chapter's code stays under 300 lines.** Code you can read in one sitting is the
only code that teaches — code you cannot finish reading can only be trusted, never
understood.

What you get instead is a sandbox that actually runs, and enough judgement to read,
evaluate, or build a production one. Each chapter closes by pointing at where that same
piece lives in a real production codebase, so the toy and the real thing stay connected.

---

## Prior art worth your time

- [`e2b-dev/runtime`](https://github.com/e2b-dev/runtime) — the production system, in Go
- [`firecracker-microvm/firecracker`](https://github.com/firecracker-microvm/firecracker) — the VMM, and its [NSDI '20 paper](https://www.usenix.org/conference/nsdi20/presentation/agache)
- [`shareAI-lab/learn-claude-code`](https://github.com/shareAI-lab/learn-claude-code) — the layer above this one: how the agent itself is built

---

## License

MIT
