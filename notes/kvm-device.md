# Briefing · `/dev/kvm`

[English](kvm-device.md) · [中文](kvm-device.zh.md)

> Equipment notes, read before you set out. Every chapter from s01 onward uses this.
> You can skip it and still proceed — but you will know what you are holding if you don't.

---

## The equipment

```
/dev/kvm      character device    10:232    crw-rw----  root:kvm
```

It stores nothing. It is a **door**.

`open()` it and you get a file descriptor; drive that descriptor with `ioctl()` and you
are commanding the KVM subsystem inside the kernel. This is the classic Linux shape for
handing a kernel capability to a userspace program.

Two kernel modules sit behind it:

```
kvm          ~980 KB    architecture-independent core
kvm_intel    ~360 KB    Intel VT-x implementation (kvm_amd on AMD hardware)
```

---

## What it lets you do

Four steps, each closer to the metal than the last:

```c
fd  = open("/dev/kvm", O_RDWR);
vm  = ioctl(fd,  KVM_CREATE_VM, 0);            // 1. ask for a machine
      ioctl(vm,  KVM_SET_USER_MEMORY_REGION,   // 2. donate a slice of your own
                 &region);                     //    address space as its "RAM"
cpu = ioctl(vm,  KVM_CREATE_VCPU, 0);          // 3. ask for a virtual CPU
      ioctl(cpu, KVM_RUN, 0);                  // 4. <- the whole point
```

**Step 4** switches the physical CPU into hardware virtualization mode (VMX non-root, in
Intel's vocabulary) and **executes the guest's machine code directly**.

Not emulation. Not instruction translation. The real CPU runs those instructions, fenced
by hardware into a separate execution context — its own page tables, its own register
state, its own view of privilege levels.

**That is the physical reason a microVM can boot in milliseconds and run at near-native
speed.** In s01 you will measure the number yourself.

So membership in the `kvm` group means, concretely:

> **You are permitted to ask the kernel to put a CPU into virtualization mode and execute
> code you supply.**

---

## Why it takes a key

The device is `0660 root:kvm`. A group is the middle answer, because neither extreme works:

| Option | Why not |
|--------|---------|
| **root only** | Every VMM — QEMU, Firecracker, the Android emulator — would have to run as root. **That is worse**: a VMM is a large, complex program that parses untrusted guest input, exactly the kind of program that should hold no privilege. |
| **world-accessible `0666`** | KVM's ioctl surface is not small. This would open a wide stretch of kernel code to every user on the box. |

A udev rule does the assignment, and it is on your machine right now:

```
/lib/udev/rules.d/50-udev-default.rules:114
KERNEL=="kvm", GROUP="kvm", MODE="0660", OPTIONS+="static_node=kvm"
```

### The design philosophy behind the split

The division is not arbitrary. It is KVM's central design decision:

```
in the kernel (privileged)   only what genuinely requires hardware privilege:
                             switching CPU modes, managing second-level page tables
                             ↓ small, stable, the most heavily audited code there is

in userspace (unprivileged)  the VMM does all the dirty work: device emulation,
                             disk formats, networking, snapshots
                             ↑ large, complex, certainly buggy — and powerless
```

Firecracker pushes this furthest: it additionally confines *itself* with a tiny seccomp
allowlist. Once the guest is isolated, the VMM is the remaining attack surface, so it gets
caged too.

---

## What the key actually costs you

**It is a real grant of privilege.** KVM's ioctl interface is complex, and it has had CVEs
— guest escapes, local privilege escalation. Joining the group means reaching that kernel
code directly.

**It is not equivalent to root.** For comparison, if you are already in the `docker` group:

```bash
docker run --rm -v /:/host alpine cat /host/etc/shadow
```

That reads your entire host filesystem as root. **The `docker` group is root-equivalent by
design**, and Docker's own documentation says so.

```
docker group  =  root-equivalent (can mount the host's root filesystem)
kvm group     =  a wider kernel attack surface, but no path to root
```

**`kvm` is strictly weaker than `docker`.** If you can already run containers, joining
`kvm` changes your security posture very little.

---

## What else it unlocks

The same udev rules file puts two more devices in the `kvm` group:

```
/dev/kvm            root:kvm     hardware virtualization      s01 – s04
/dev/vhost-vsock    root:kvm     host <-> guest channel       s05
/dev/vhost-net      root:kvm     accelerated virtio networking s06
```

**One `usermod` grants the device permissions for three chapters at once.** You will not
need to come back for a second one.

---

## An irony worth sitting with

`/dev/kvm` is itself the very thing [s00](../s00_shared_kernel/) warns about: **an
interface into a shared kernel.**

The tool we use to escape the shared-kernel problem is reached *through* the shared kernel.

The difference is surface area and scrutiny:

```
full Linux syscall ABI   ~350 entry points, touched by every program, enormous
KVM's ioctl interface    far narrower, and the most heavily audited subsystem in the
                         kernel — because the entire public cloud rests on it
```

> **A sandbox never eliminates attack surface. It trades a large one for a smaller,
> better-watched one.**

This theme recurs throughout the tutorial.

---

## Drawing the equipment

```bash
sudo usermod -aG kvm $USER
```

**Do not omit `-a`.** This is an unrecoverable mistake:

| Written as | Result |
|------------|--------|
| `usermod -aG kvm you` | **append** — kvm is added to your existing groups ✅ |
| `usermod -G kvm you`  | **replace** — your supplementary groups become *only* kvm ❌ |

The second form strips `sudo`, `docker`, and everything else instantly — and because
`sudo` is among the casualties, **you no longer have the privilege to undo it.**

### Why it does not take effect yet

```bash
getent group kvm     # kvm:x:993:you   <- written to disk
id -nG               # no kvm          <- but this shell cannot see it
```

**Group membership is baked into a process's credentials at login.** The kernel reads
`/etc/group` when you log in, writes the group list into the process credential, and every
child forked afterwards inherits that snapshot. Editing the file does not reach back into
processes already running.

| Situation | What to do |
|-----------|------------|
| Make it permanent | **Close the terminal and open a new one** — new login session, fresh read of `/etc/group` |
| Verify without re-login | `sg kvm -c 'your command'` — it re-reads the group file |
| Stubborn on WSL2 | `wsl --shutdown` from Windows, then reopen |

> ⚠️ If you have **ast-grep** installed, its binary is also named `sg` and will shadow this
> one on your `PATH`. Use the absolute path: `/usr/bin/sg`.
> (Incidentally, `/usr/bin/sg` is a symlink to `newgrp` — one program that decides what to
> do by inspecting `argv[0]`, an old Unix trick.)

### Confirm you have it

```bash
./scripts/check-env.sh
```

The `Hardware virtualization` section should turn ✅ and every chapter from s01 onward
should report ready.

---

**Back to:** [s00 — Your container is not a sandbox](../s00_shared_kernel/)
**Onward to:** s01 — A virtual machine in 125 ms *(not yet written)*
