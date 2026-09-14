# s03: Don't boot. Restore.

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/) → [s01](../s01_first_microvm/) → [s02](../s02_write_a_vmm/) → **s03** → [s04](../s04_orchestrator/) → ... → s08

> **Needs:** `/dev/kvm`, a C compiler, `make`, and the fetched assets.
> **Time:** about 30 minutes.

> *"Don't boot. Restore."*

---

## The Problem

[s01](../s01_first_microvm/) measured a boot and found the time was not where you would
guess: the kernel finished at 0.93 s and the shell appeared at 2.6 s, so most of it was
systemd. We noted you could shave that down and could not shave it to zero.

Here is why not. Every boot, a kernel does the same work it did last time:

```
probe the virtio bus        find a disk that has not moved
mount the root filesystem   the same filesystem as before
start systemd               bring up the same 30 units
reach a shell               2.6 seconds later
```

**None of that is a discovery. It is a re-derivation of facts that have not changed.**

So stop deriving them. Derive them once, write down the answer, and hand the answer to
the next machine that asks.

---

## The Solution

A snapshot, which turns out to be two things and no more:

```
the guest's memory     — which s02 showed is a region your process owns
the processor's state  — a few hundred bytes the kernel will hand over
```

Save both, and a virtual machine becomes a file. Load both into a new process and it
carries on mid-sentence.

This chapter does it twice: once by hand, in 99 lines of C, so you can see there is no
hidden step — and then through Firecracker, on a real Ubuntu, for the numbers.

---

## Part 1 · By hand

`tinysnap.c` extends [s02](../s02_write_a_vmm/)'s VMM with two operations that are exact
mirrors of each other:

```c
snapshot =  write(guest memory)  +  KVM_GET_REGS  +  KVM_GET_SREGS
restore  =  read (guest memory)  +  KVM_SET_REGS  +  KVM_SET_SREGS
```

The guest counts. It prints a digit, increments a register, and loops forever:

```
88 d8      mov  al, bl        take the counter
04 30      add  al, '0'       make it printable
ba f8 03   mov  dx, 0x3f8     the serial port
ee         out  dx, al        print it        -> VM exit
fe c3      inc  bl            count up
eb f4      jmp  -12           forever
```

```bash
$ make
$ ./tinysnap
before snapshot: 01234
snapshot  rip=7  rbx=4
          snapshot.cpu        456 bytes   the processor
          snapshot.mem       4096 bytes   the memory

Now run:  ./tinysnap restore

$ ./tinysnap restore
restored  rip=7  rbx=4  (456 bytes of cpu state)
after  restore: 45678
```

**A different process picked up the counting.** Nothing was shared between the two runs
except two files.

### The line that carries the whole idea

```c
if (restoring) read_file(MEM_FILE, mem, MEM_SIZE, "memory snapshot");
else           memcpy(mem, guest_code, sizeof guest_code);
```

Booting and restoring differ only in **where the bytes come from** — an array in the
program, or a file on disk. The guest cannot tell, because from inside there is nothing
to tell apart: it is the same page of memory either way.

That is the entire reason restoring is faster. Booting makes a kernel derive its world.
Restoring hands it the world it derived last time.

### Why it prints 4 twice

Look again:

```
before snapshot: 01234
after  restore:  45678
                 ^
```

The snapshot recorded `rip=7`, and offset 7 in the guest program is the `out` instruction
itself — not the one after it. **The machine was captured in the middle of an
instruction.** The `out` had trapped out to the VMM but, as far as the guest is
concerned, had not finished.

So the restored CPU resumes at the `out`, re-issues it, and 4 appears again.

This is not a rough edge in our toy. It is what a snapshot *is*: not "which line the
program reached" but "everything the processor was in the middle of". Real VMMs spend
serious effort on exactly this — in-flight I/O, half-filled device queues, interrupts
that were about to be delivered.

---

## Part 2 · The same two operations, at scale

```bash
./snapshot.sh
```

```
1 · Cold boot
   Ubuntu reached a shell in 2659 ms

2 · Leave a mark, then snapshot
   PATCH /vm {"state":"Paused"}      -> HTTP 204
   PUT /snapshot/create              -> HTTP 204   (456 ms)
   snapshot.mem              268435456 bytes   the guest RAM
   snapshot.state                12993 bytes   everything else

3 · Restore  (a fresh firecracker — /snapshot/load is pre-boot only)
   PUT /snapshot/load                -> HTTP 204   (16 ms)

4 · Ask it what it remembers
   the guest answered: I-WAS-HERE-BEFORE-THE-SNAPSHOT
   a file written before the snapshot, read after it, in another process

The two numbers
   cold boot to a shell   2659 ms
   restore from snapshot  16 ms
   166x faster
```

### Three things the API insists on

**The VM must be paused first.** `PATCH /vm {"state":"Paused"}` before
`PUT /snapshot/create`. You cannot photograph a machine while it is moving — you would
capture memory from one instant and registers from another.

**Restore needs a brand new process.** The spec says `/snapshot/load` is *"Only accepted
on a fresh Firecracker process"*. You do not push a snapshot into a running VMM; you
start a VMM and make the snapshot its very first instruction. Everything else — the
kernel path, the drive, the machine config — comes back from the file.

**The mark proves it is the same machine.** A file written inside the guest before the
snapshot is readable after it, from a different process. That is the difference between
restoring and rebooting something that resembles what you had.

### The asymmetry is the story

```
snapshot.mem     268,435,456 bytes    exactly the 256 MiB we configured
snapshot.state        12,993 bytes    registers, devices, clock, interrupt state
```

**A machine's state is 99.995% memory.** The 13 KB is what it was doing; the 256 MiB is
everything it knew.

Our toy has the same shape at six-thousandth the scale — 4,096 bytes of memory against
456 bytes of processor. Same two files, same ratio of interest.

It also explains the 456 ms it took to create: that is 256 MiB going to disk at roughly
600 MB/s. Creating a snapshot costs what writing memory costs. **Restoring does not**,
which is the next section.

---

## Part 3 · Why 16 ms

Restoring 256 MiB in 16 ms would need 16 GB/s. No disk does that. So it is not reading
the file.

`mmap` is lazy. Mapping a 256 MiB file establishes the mapping and reads **nothing**;
pages arrive on demand, when the guest first touches them. A guest that wakes up, prints
a line and pauses again may touch a few hundred pages out of sixty-five thousand.

**You do not pay for memory you do not use** — and a restored machine, in the first
milliseconds, uses almost none.

Firecracker goes further than plain `mmap`: the API accepts a `mem_backend` of type
`Uffd`, handing page faults to a userspace process over `userfaultfd`. That process can
fetch pages from anywhere — another machine, object storage — which is how a sandbox
platform keeps thousands of snapshots somewhere cheap and still resumes one in
milliseconds.

### A snapshot is a template, not a backup

Restoring does not consume the files. The same pair can be loaded again, and again, each
into its own process, each becoming an independent machine that diverges from the moment
it resumes. Restoring the same snapshot five times gives five VMs that share a starting
state and nothing else — and the files are untouched afterwards.

A backup answers *"can I get back to where I was?"*. A snapshot here answers *"how many
copies of this exact moment would you like?"*

**That question is s05.**

---

## Try It

```bash
make            # builds tinysnap
./tinysnap      # prints 01234, writes two files
./tinysnap restore

./snapshot.sh   # the same thing to a real Ubuntu, with timings
```

Worth doing next:

- Run `./tinysnap restore` **twice**. Both start from 4 — restoring does not advance the
  snapshot, so every restore begins at the same instant.
- Delete `snapshot.mem` and keep `snapshot.cpu`, then restore. The registers say to
  resume at `rip=7`, but the page is blank. Watch what a machine does when its memory
  and its mind disagree.
- In `snapshot.sh`, comment out the `PATCH /vm {"state":"Paused"}` line and see what
  `/snapshot/create` says about it.

---

## What You Just Learned

1. **A snapshot is memory plus registers.** Two files, no third thing. The mechanism fits
   in 99 lines because guest memory is a region you already own and the processor state
   is an ioctl away.

2. **Restore is not a fast boot — it is not a boot.** Nothing is discovered, initialised
   or started. The kernel inside never learns that time passed.

3. **Creating costs memory bandwidth; restoring costs almost nothing.** 456 ms to write
   256 MiB, 16 ms to map it back, because `mmap` reads nothing until the guest asks.

4. **The state you care about is a rounding error.** 13 KB of "what it was doing" against
   256 MiB of "what it knew" — which is why every optimisation in this space, from diff
   snapshots to userfaultfd, is about the memory and not the registers.

---

## Going Deeper

- **Diff snapshots.** `snapshot_type: "Diff"` plus dirty page tracking writes only pages
  changed since the last snapshot. The API for it is in
  `assets/release-v1.17.0-x86_64/firecracker_spec-v1.17.0.yaml`, alongside everything
  else this chapter called.
- **`userfaultfd`.** `mem_backend: {backend_type: "Uffd"}` moves page-fault handling into
  a process of your own. This is the mechanism behind "resume from object storage".
- **Restoring on a different CPU.** A snapshot carries CPUID and MSR values the guest has
  already seen. Land it on a host with different features and the guest may execute an
  instruction that no longer exists. Firecracker's `cpu_config/` — 6,283 lines — and its
  CPU templates (`T2`, `T2S`, `C3` in the release tarball) exist for this.
- **`snapshot-editor`**, also in the tarball, inspects and rewrites snapshot files
  offline.

---

**Next:** [s04 — Control plane, data plane, never mixed](../s04_orchestrator/)
One VM is a demo. The moment you want a second one, something has to keep track.
