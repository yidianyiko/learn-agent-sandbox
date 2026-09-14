# s06: Someone has to be inside

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/) → [s01](../s01_first_microvm/) → [s02](../s02_write_a_vmm/) → [s03](../s03_snapshot_restore/) → [s04](../s04_orchestrator/) → [s05](../s05_fork_parallel/) → **s06** → s07 → s08

> **Needs:** `/dev/kvm`, cargo, the fetched assets. No root.
> **Time:** about 40 minutes.

> *"Someone has to be inside."*

---

## The Problem

Six chapters in, you can start a machine, freeze it, revive it, fork it, and keep a
registry of the ones that are running. You still cannot ask one to do anything.

The console is not an answer. It is a byte stream shared with the kernel's own log, with
no framing, no exit codes, and no way to tell where one command's output ends. Fine for a
person squinting at it; useless for a program.

Two things are missing, and neither is obvious:

```
a channel     how does the host reach a program inside the guest,
              on a machine with no network?

a passenger   how does a program get inside a machine whose disk is
              read-only and which has never been on a network?
```

---

## Part 1 · The passenger: an initramfs is a cpio archive

An initramfs is not a filesystem image. It is an **archive the kernel unpacks into a
tmpfs** before any filesystem driver or block device is involved, after which it runs
`/init` from it. That is precisely why it can carry your program into a machine that has
nothing: it works before the machine has anything.

The format is `newc` cpio, from 1977, and `mkinitramfs.rs` writes it in about forty lines:

```
[110-byte header][name][data]  [header][name][data]  ...  [TRAILER!!!]
```

Every header field is **ASCII hex** — which is why a hexdump of one reads `070701` as
characters rather than bytes. There is no endianness question: the same archive parses
identically on x86 and ARM. That was the point in 1977 and it still pays.

The kernel chose this over the alternatives for one reason: it must be unpacked by code
living inside the kernel, before anything else exists, so the parser has to be tiny and
streaming. `zip` keeps its index at the end of the file and would need to seek. `tar` has
several mutually incompatible dialects. `cpio newc` is a flat sequence of fixed-size
headers, and a few hundred lines of C can read it.

Our archive has two files:

```
init          our agent, which the kernel will run as PID 1
bin/busybox   a static shell, so the agent has something to run commands with
```

### PID 1 may not exit

An early version of this chapter's binary printed a line and returned from `main`. The
result:

```
[    0.531518] Run /init as init process
hello from a static binary
[    0.533278] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

**Exit code zero.** The kernel does not care that init succeeded; if PID 1 goes away, the
system has no init and panics. Hence `park()` at the bottom of `main.rs`: when the agent
cannot serve, it sits still rather than exiting, because exiting would destroy the machine
and the evidence with it.

### BusyBox picks its command from `argv[0]`

The first working build could run shell builtins and nothing else:

```
$ echo $((6*7))     ->  42
$ uname -a          ->  sh: uname: not found
```

BusyBox is four hundred commands in one binary, and it decides which one you meant by
looking at the name it was invoked under — the same trick that makes `/usr/bin/sg` and
`newgrp` the same file. With only `/bin/busybox` present, a shell searching for `uname`
finds nothing.

`busybox --install -s` fixes it by symlinking every applet. But it installs each at its
canonical path, so `ls` lands in `/bin` while `head` wants `/usr/bin` — and without that
directory, half the symlinks fail silently. The agent creates `/usr/bin`, `/usr/sbin` and
`/sbin` before asking.

---

## Part 2 · The channel: vsock

```c
#[repr(C)]
struct SockAddrVm {
    svm_family: u16,
    svm_reserved1: u16,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [u8; 4],
}
```

Sixteen bytes, and that is the whole of vsock addressing. A **context id** and a **port**.
No interface, no IP address, no routing table, no DNS, no ARP. The guest has no network in
any sense and does not need one; the hypervisor moves the bytes.

That matters more than it sounds. A sandbox that must be on a network to be controlled has
to have its network secured. A sandbox reached over vsock can have no network at all and
still take orders.

### The handshake Firecracker adds

Firecracker does not hand the host an `AF_VSOCK` socket. It proxies the device through a
Unix socket on the host, with a two-line protocol of its own:

```
host:  connect to uds_path
host:  send  "CONNECT 1234\n"
host:  read  "OK <host-side-port>\n"     <- or the connection simply closes
```

Past that line the socket is wired straight through to whatever `accept()`ed inside the
guest.

Notice what this does to the two sides of the code. The guest agent needs raw syscalls —
`socket`, `bind`, `listen`, `accept` against `AF_VSOCK`, which Rust's std does not have.
The host client needs none of that, because a Unix socket is ordinary and `UnixStream` is
in std. **One side is a systems program; the other is an afternoon.**

---

## Part 3 · The agent

```bash
make && ./demo.sh
```

```
1 · Build the agent
   agent          1169824 bytes   runs as PID 1 inside the guest
   vexec          1173760 bytes   runs here

2 · Pack it into an initramfs  (a cpio archive, nothing more)
   init             1169824 bytes
   bin/busybox      1131168 bytes
   initramfs.cpio   2301472 bytes total

3 · Boot it, with a vsock device
   PUT /vsock           -> 204   (guest_cid 3, proxied through v.sock)
   guest says: agent: up, listening on vsock port 1234

4 · Run commands in it
   $ uname -a
     Linux (none) 6.1.186 #1 SMP PREEMPT_DYNAMIC x86_64 GNU/Linux
     [exit 0]
   $ free -m | head -2
                   total        used        free      shared  buff/cache   available
     Mem:            230          14         212           3           4         209
     [exit 0]
   $ ls /usr/bin | wc -l
     177
     [exit 0]
```

The agent is about 180 lines of Rust with **no dependencies**. Everything it needs from
the kernel is declared by hand:

```rust
extern "C" {
    fn socket(domain: i32, ty: i32, protocol: i32) -> i32;
    fn bind(fd: i32, addr: *const SockAddrVm, len: u32) -> i32;
    fn fork() -> i32;
    fn execv(path: *const i8, argv: *const *const i8) -> i32;
    ...
}
```

std has already linked libc, so these merely name what is there. Declaring them by hand
keeps the crate free of dependencies **and puts every kernel call the program makes in one
visible list** — which is the more valuable half.

Running a command is `fork`, then `dup2` the socket onto the child's stdout and stderr, and
`execv` BusyBox. The caller sees output as it is produced, because the caller's socket *is*
the child's stdout.

---

## Try It

```bash
../scripts/fetch-assets.sh
make && ./demo.sh

# or drive it by hand
./target/release/vexec /tmp/.../v.sock 1234 'cat /proc/meminfo'
```

Worth doing next:

- Delete the `install_busybox()` call and watch which commands survive. The ones that do
  are shell builtins; everything else was a symlink.
- Make `main` return instead of calling `park()` on the error path, then boot with no vsock
  device. The kernel's opinion of that is immediate.
- Add a second command to the protocol — say, one that writes a file — and notice that you
  are now designing an API, which is what `envd` is.

---

## What You Just Learned

1. **An initramfs is a cpio archive**, and cpio is a flat sequence of ASCII-hex headers.
   Forty lines of Rust write one. That is the whole of how a program gets into a machine
   with no network and a read-only disk.

2. **PID 1 may not exit**, not even with status zero. The kernel panics, because a system
   without init is not a system.

3. **vsock is addressing without a network** — a context id and a port, sixteen bytes. A
   sandbox reachable this way needs no interface at all, which removes a whole category of
   things to secure.

4. **Being inside is harder than being outside.** The guest side is raw syscalls because
   nobody's standard library covers `AF_VSOCK`; the host side is `UnixStream` and no
   `unsafe` at all. The asymmetry is worth remembering when deciding what runs where.

---

## Going Deeper

- **E2B's `envd` is Go, not Rust.** We chose Rust here for a small static binary and
  because [s02](../s02_write_a_vmm/) put Rust at this layer deliberately; the production
  answer at `packages/envd` went the other way. Neither is wrong — read theirs and see
  what it buys.
- **`vsock_loopback`.** Modern kernels expose CID 1 for host-local vsock, which lets you
  test an AF_VSOCK program without a VM at all.
- **Firecracker's `docs/vsock.md`** documents the guest-initiated direction too: the host
  listens on `uds_path_PORT` and the guest connects to CID 2. That is how you would push
  events out rather than pull answers in.
- **What a real agent grows into.** Filesystem operations, streaming stdin, process
  lifecycle, port forwarding, file watching. Each one is another verb on the protocol you
  just started.

---

**Next:** s07 — *Now let it reach the internet* *(not yet written)*
The machine can take orders. It still cannot `pip install` anything.
