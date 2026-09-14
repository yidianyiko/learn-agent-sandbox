# s00: Your container is not a sandbox

[English](README.md) · [中文](README.zh.md)

**s00** → [s01](../s01_first_microvm/) → [s02](../s02_write_a_vmm/) → ... → s08

> **Needs:** Docker only. No KVM, no root.
> **Time:** about 10 minutes.

> *"Your container is not a sandbox."*

---

## The Problem

You are building an agent. It writes a Python script and you need to run it.

You reach for Docker, because that is what everyone reaches for. The image is
throwaway, the filesystem is isolated, you can cap the memory. It certainly *feels*
like a box.

Before you put agent-generated code in that box, it is worth asking a plain question:

**what, exactly, is between that code and your machine?**

This chapter answers it by measuring, not by arguing.

---

## The Solution

Four read-only experiments. Each one is a single `docker run` that asks the container
a question about itself and compares the answer to the host. Nothing is mounted,
nothing is modified.

```
  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
  │  container  │  │  container  │  │    host     │
  │   Alpine    │  │   Debian    │  │   Ubuntu    │
  │  musl/busybox│ │    glibc    │  │    glibc    │
  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
         │                │                │
         └────────────────┼────────────────┘
                          ▼
                 ┌──────────────────┐
                 │   ONE kernel     │   ← the thing we are about to prove
                 └──────────────────┘
```

---

## How It Works

### 1 · Three distributions, one kernel

Alpine ships musl libc and BusyBox. Debian ships glibc and GNU coreutils. They share
essentially no userland code. Ask each one what kernel it is running on:

```
Alpine Linux 3.20          6.18.33.2-microsoft-standard-WSL2
Debian 12                  6.18.33.2-microsoft-standard-WSL2
host (Ubuntu 24.04)        6.18.33.2-microsoft-standard-WSL2
```

Identical — down to the `microsoft-standard-WSL2` suffix, which Alpine has obviously
never shipped. That string belongs to the host.

The reason is a fact that is rarely stated outright:

> **A Linux distribution is userland files plus a kernel. A container image contains
> no kernel at all.** Docker swaps the files. It does not swap the engine.

*(Your kernel string will differ from the one above — the point is that all three of
yours will match each other.)*

### 2 · The container cannot see its own limits

Start a container with a hard 128 MB cap and ask it how much memory it has:

```
limit we imposed (cgroup)          128 MB
what the cgroup file says          128 MB     <- enforced
what `free` reports              60269 MB     <- what the application sees
actual host memory               60268 MB
CPUs via nproc                        20      (host has 20)
```

`free` reads `/proc/meminfo`, and that file is **not namespaced**. cgroups *enforce*
the limit — go over it and you are killed — but they do not *virtualise the view*.

This is not trivia. It is why the JVM, Node and Go runtimes historically sized their
heaps and thread pools from host RAM, allocated far past the cgroup limit, and got
OOMKilled with nothing in the log but exit code 137. `-XX:+UseContainerSupport` exists
to read the cgroup files directly, precisely because `/proc` lies.

### 3 · You are reading the host kernel's internals

```
uptime reported inside container   321188.81 s   <- it started milliseconds ago
uptime of the host                 321189.05 s
kernel modules seen in container          208
kernel modules loaded on host             208
```

A container born a moment ago reports days of uptime, and can enumerate every kernel
module loaded on the host. It is not looking at its own kernel.

There is no "its own kernel."

### 4 · How thin the wall is when you misconfigure it

```
device nodes, normal container      15
device nodes, --privileged         181
device nodes on the host           191
host block devices now exposed     sda sdb sdc sdd
```

One flag, and the host's raw disks are addressable from inside the container. We only
listed them — but a process that can address a block device can read the filesystem on
it, whatever the container's own mounts say.

---

## Try It

```bash
cd s00_shared_kernel
./demo.sh
```

Two pinned images get pulled (`alpine:3.20`, `debian:12-slim`), four containers run,
nothing is written. Takes under a minute on a warm cache.

> **Note the pinned tags.** An unpinned `alpine` resolves to `alpine:latest`, which
> moves under you. A tutorial whose output stops matching its prose is worse than no
> tutorial — so every image in this repo carries an explicit tag.

---

## What You Just Learned

1. **A container image has no kernel.** Namespaces changed what the process can *see*;
   cgroups changed how much it can *use*. Neither changed where its system calls *go*.

2. **The security boundary is the syscall interface** — 300-plus entry points into the
   one kernel your host and every container share. A kernel privilege-escalation bug is
   a container escape by definition, and those ship a few times a year.

3. **That is a perfectly good trade — for code you wrote and reviewed.** It stops being
   a good trade when the code was generated seconds ago and reviewed by nobody. The
   isolation did not get weaker; what you are running through it changed.

---

## Going Deeper

- **The middle ground.** [gVisor](https://gvisor.dev) intercepts syscalls in a userspace
  kernel; [Kata Containers](https://katacontainers.io) keeps the container interface but
  puts a VM underneath. Both exist because of exactly the gap measured above.
- **Why `/proc` lies.** [lxcfs](https://github.com/lxc/lxcfs) is the usual workaround:
  a FUSE filesystem that serves cgroup-aware `/proc/meminfo` to containers.
- **What a real boundary costs.** The Firecracker paper,
  [*Lightweight Virtualization for Serverless Applications*](https://www.usenix.org/conference/nsdi20/presentation/agache)
  (NSDI '20) — the same problem, solved by giving each workload its own kernel.

---

**Next:** [s01 — A kernel of its very own](../s01_first_microvm/).
A machine with a kernel of its very own, started by hand.

Before you go: the briefing on [`/dev/kvm`](../notes/kvm-device.md), the device every
chapter from here on depends on.
