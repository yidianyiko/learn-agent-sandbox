# s01: A kernel of its very own

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/) → **s01** → s02 → ... → s07

> **Needs:** `/dev/kvm`, x86_64 Linux. No root. See [`../scripts/check-env.sh`](../scripts/check-env.sh).
> **Time:** about 20 minutes.
> **Background:** the [`/dev/kvm` briefing](../notes/kvm-device.md), if you haven't read it.

> *"A kernel of its very own."*

---

## The Problem

[s00](../s00_shared_kernel/) ended on a flat statement:

> A container born a moment ago reports days of uptime, and can enumerate every kernel
> module loaded on the host. It is not looking at its own kernel.
>
> **There is no "its own kernel."**

So give it one.

That sentence is easy to write and turns out to be an interesting amount of work. A
machine needs a kernel to boot, memory to boot into, a disk to find a root filesystem on,
and something to emulate the hardware all of that expects. This chapter assembles exactly
that, by hand, and then asks what it cost.

---

## The Solution

Firecracker. About 3.5 MB, statically linked, no dependencies — and unusually, **you do
not configure it with command-line flags.** You start it, and it sits there doing nothing,
listening on a unix socket. You then make four HTTP calls:

```
   PUT /boot-source     here is a kernel, and what to tell it
   PUT /drives/rootfs    here is a disk
   PUT /machine-config   this much CPU and RAM
   PUT /actions          go
```

The fourth one reaches `KVM_RUN` and a physical core starts executing guest instructions.

### Why an API and not flags

This looks like ceremony until you consider the lifetime of a sandbox. A VM is not
configured once and forgotten — you will want to attach a drive, take a snapshot, pause
it, resume it, fork it. All of that needs a channel that stays open after boot, so
Firecracker makes that channel the *only* interface and has no second way to do things.

It pays off twice more later: the API is formally specified (the release tarball ships
`firecracker_spec-v1.17.0.yaml`, an OpenAPI document), and in [s03](../) your orchestrator
will drive exactly these endpoints over exactly this socket.

---

## How It Works

### The four calls

```bash
# 1. the kernel, and its command line
curl --unix-socket "$SOCK" -X PUT http://localhost/boot-source \
  -H 'Content-Type: application/json' -d '{
    "kernel_image_path": "../assets/vmlinux-6.1.186",
    "boot_args": "console=ttyS0 reboot=k panic=1"
  }'

# 2. the root filesystem — read-only, exactly as shipped
curl --unix-socket "$SOCK" -X PUT http://localhost/drives/rootfs \
  -H 'Content-Type: application/json' -d '{
    "drive_id": "rootfs",
    "path_on_host": "../assets/ubuntu-24.04.squashfs",
    "is_root_device": true,
    "is_read_only": true
  }'

# 3. how much machine
curl --unix-socket "$SOCK" -X PUT http://localhost/machine-config \
  -H 'Content-Type: application/json' -d '{"vcpu_count": 1, "mem_size_mib": 256}'

# 4. go
curl --unix-socket "$SOCK" -X PUT http://localhost/actions \
  -H 'Content-Type: application/json' -d '{"action_type": "InstanceStart"}'
```

Each returns `204 No Content`. That is the whole boot sequence.

### Two things we got wrong first, so you don't have to

**You do not write `root=` yourself.** Our first attempt passed
`console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda ro`, copying the shape of a normal
kernel command line. The guest then reported this:

```
console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda ro pci=off root=/dev/vda ro virtio_mmio.device=4K@0xc0001000:5
                                                        └──────────── duplicated ────────────┘
```

Firecracker appends `pci=off root=/dev/vda ro` and a `virtio_mmio.device=` entry per
drive on its own. Writing them yourself is harmless but confusing later, when you are
staring at `/proc/cmdline` wondering who said it twice. Pass only what is genuinely
yours: a console, and what to do on panic.

**You do not need sudo.** The official getting-started guide unpacks the squashfs,
generates an SSH key, `sudo chown`s the tree and `sudo mkfs.ext4`s a fresh image. That is
because it wants to SSH into the guest. We only want a console, and every kernel in the
Firecracker CI bucket is built `CONFIG_SQUASHFS=y` — we checked the shipped `.config` —
so the rootfs mounts read-only exactly as downloaded. The whole privileged detour
disappears.

---

## Try It

```bash
../scripts/fetch-assets.sh   # ~150 MB, pinned and checksummed
./boot.sh
```

You land at a root prompt inside the machine. Ask it the same questions s00 asked a
container:

```
root@ubuntu-fc-uvm:~# uname -r
6.1.186

root@ubuntu-fc-uvm:~# nproc
1

root@ubuntu-fc-uvm:~# free -m | awk 'NR==2{print $2}'
230
```

Type `reboot` to shut it down and come back.

### The comparison this chapter exists for

|  | container (s00) | microVM (s01) |
|---|---|---|
| distro vs. host | **different** (Alpine, Debian) | **same** (Ubuntu 24.04) |
| `uname -r` vs. host | **identical** | **different** — `6.1.186` vs `6.18.33.2-microsoft-standard-WSL2` |
| `nproc` | 20 — the host's | 1 — its own |
| memory reported | 60269 MB — the host's | 230 MB — its own |

s00 was different userlands over one kernel. s01 is the same userland over its own kernel.
And note the last two rows: the container could not see its own limits because there was
nothing to see — the limit was a cgroup bolted to the side. Here the limit *is* the
machine.

---

## Where the time actually goes

```bash
./measure.sh
```

```
Ubuntu 24.04 on squashfs   (what boot.sh runs)
  virtio-blk probed          0.358 s
  root filesystem mounted    0.910 s   <- squashfs decompression lives here
  kernel hands off to init   0.927 s
  wall clock to a shell      2602 ms

BusyBox initramfs, 2 MB     (roughly the floor)
  kernel hands off to init   0.533 s
  wall clock to a shell       688 ms
```

Read the gap: **the kernel is done at 0.93 s, and the shell appears at 2.6 s.** Nearly
two thirds of your boot is systemd bringing up a full Ubuntu. Swap that for a 2 MB
BusyBox initramfs and the same hypervisor, the same kernel, delivers a shell in 688 ms.

**The VM is cheap. The operating system on top of it is not.**

### About that 125 ms

Firecracker's [NSDI '20 paper](https://www.usenix.org/conference/nsdi20/presentation/agache)
reports roughly 125 ms. You will not see that here, and the reasons are more useful than
the number:

- that measurement used a **trimmed kernel**; ours is the full-featured CI build
- it booted a **minimal init**, not systemd
- it ran on **bare metal**; if you are on WSL2 or any nested setup, every VM exit is
  charged twice

An earlier draft of this chapter was titled *"A virtual machine in 125 ms."* We measured
2602 ms and changed the title, because a tutorial that prints a number you cannot
reproduce has spent its credibility on nothing.


### The same result on a second machine

This chapter's CI boots the same VM on a GitHub Actions runner — Azure hardware, AMD
EPYC, a different kernel — every push. Side by side:

|  | WSL2 laptop (Intel) | GitHub runner (Azure, AMD) |
|---|---|---|
| Ubuntu, wall clock to shell | 2602 ms | 2284 ms |
| Ubuntu, kernel hands off to init | 0.927 s | 0.852 s |
| initramfs, wall clock to shell | 688 ms | 569 ms |

Different vendor, different silicon, 12–18 % apart — and both nowhere near 125 ms. That
is the point worth taking: the gap is not your machine being slow. It is a full kernel
and a full userland doing real work, on every boot, forever.

> ⚠️ **Do not trust in-guest timers under nested virtualisation.** The BusyBox initramfs
> cheerfully announces `Boot took 540.30 seconds`. Its clock reference is wrong. Measure
> from the host.

You can shave this down — trim the kernel, drop systemd, use a faster filesystem. You
cannot shave it to zero, because a kernel has to discover its hardware every single time.

**[s02](../) stops trying, and restores from a snapshot instead.**

---

## What You Just Learned

1. **A VM is four HTTP calls.** Kernel, disk, size, go. The API exists rather than flags
   because a sandbox's interesting operations — snapshot, pause, fork — all happen
   *after* boot.

2. **The isolation is real in a way cgroups never were.** The guest sees one CPU and
   230 MB because that is genuinely all the machine has, not because something is
   filtering its view of `/proc`.

3. **Boot cost is mostly userland.** 0.93 s of kernel, 1.7 s of systemd. Every
   optimisation you might reach for lives above the hypervisor, not in it.

4. **Pin your dependencies, and say so.** Firecracker's own guide resolves "latest" at
   run time — correct for their CI, fatal for a tutorial. Ours resolved it once and froze
   the answer with checksums in
   [`../scripts/fetch-assets.sh`](../scripts/fetch-assets.sh). Bumping it is a deliberate
   act that includes re-running every chapter and updating the printed numbers.

---

## Going Deeper

- **The API, formally.** `firecracker_spec-v1.17.0.yaml` in the release tarball is the
  OpenAPI document for everything you just called, and everything you have not yet.
- **What else shipped in that tarball.** `jailer` — the wrapper that puts the *VMM* in a
  chroot with its own namespaces and cgroups, because after the guest is isolated the
  VMM is what is left. Also `seccomp-filter-v1.17.0.json`, the syscall allowlist
  Firecracker confines itself to. Both are the practical form of the argument in the
  [`/dev/kvm` briefing](../notes/kvm-device.md).
- **The paper.** [Firecracker: Lightweight Virtualization for Serverless
  Applications](https://www.usenix.org/conference/nsdi20/presentation/agache), NSDI '20.
  Read it after this chapter, not before — it is much better when you have already
  watched one boot.

---

**Next:** s02 — *Don't boot. Restore.* *(not yet written)*
