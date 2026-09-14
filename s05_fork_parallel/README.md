# s05: Fork the machine, not the process

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/) → [s01](../s01_first_microvm/) → [s02](../s02_write_a_vmm/) → [s03](../s03_snapshot_restore/) → [s04](../s04_orchestrator/) → **s05** → [s06](../s06_in_vm_agent/) → s07 → s08

> **Needs:** `/dev/kvm`, a C compiler, `make`, the fetched assets, and an
> s03 snapshot (`cd ../s03_snapshot_restore && make && ./tinysnap`).
> **Time:** about 30 minutes.

> *"Fork the machine, not the process."*

---

## The Problem

[s03](../s03_snapshot_restore/) ended on a claim it did not test: that restoring does not
consume a snapshot, so the same pair of files can be loaded again and again.

That turns out to be the interesting half. If a snapshot is a **fork point** rather than a
backup, the question stops being *"how fast can I restore one?"* and becomes:

**what does the sixth one cost?**

If each restore is a fresh 256 MiB, then ten sandboxes is 2.5 GB and the idea dies on a
laptop. If they can share what they have not changed, ten sandboxes cost barely more than
one, and a whole way of using them opens up.

---

## Part 1 · One flag

```bash
make && ./tinyfork
```

```
one snapshot, 4 machines

   fork 2   resumes at 2   prints 43456   wrote 0xA2 to its own page
   fork 3   resumes at 3   prints 44567   wrote 0xA3 to its own page
   fork 4   resumes at 4   prints 45678   wrote 0xA4 to its own page
   fork 1   resumes at 1   prints 42345   wrote 0xA1 to its own page

snapshot.mem, byte 100:  before 0x00   after 0x00   unchanged
   every machine wrote there. None of them reached the file.
```

Four machines, each resuming [s03](../s03_snapshot_restore/)'s snapshot with its own
counter, each writing to the same address in guest memory — and the file they all came
from is byte-for-byte what it was.

The entire mechanism is the flag on one call:

```c
void *mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE, memfd, 0);
```

`MAP_PRIVATE` against a file means: **reads come from the page cache everyone else is
reading; the first write to a page silently gives you a private copy of it.** The kernel
has had copy-on-write for decades — this is the same machinery that makes `fork()` cheap
— and here it is being pointed at a virtual machine's RAM.

So four machines share every page they have not touched, and the snapshot they were cut
from cannot be modified by any of them. Nobody had to implement sharing, or reference
counting, or diffing. It is one word.

> Each output begins with `4` because of [s03](../s03_snapshot_restore/)'s `rip=7`: the
> snapshot caught an `out` instruction mid-flight, so every machine re-issues it before
> running its own counter. They inherit an unfinished action along with everything else.

### Two things `fork()` will do to you

The program hits both, and the comments say so:

```c
fflush(stdout);              /* before forking */
```

`fork()` copies the parent's stdio buffer. Anything printed but not yet flushed is
duplicated into every child and printed again when each one exits. Four children, one
banner, five copies.

```c
write(STDOUT_FILENO, line, len);   /* not printf */
```

Four processes writing to one terminal interleave. Building the whole line first and
emitting it with a single `write` keeps each one intact.

---

## Part 2 · The same thing, to a real machine

```bash
./fork.sh
```

One Ubuntu is booted, snapshotted, and then restored six times:

```
1 · Boot one Ubuntu and snapshot it
   snapshot: 256 MiB of memory, 12987 bytes of state

2 · Restore it 6 times

   #    restore      sum of RSS     system memory used
   1    21 ms        19 MB          8 MB
   2    21 ms        40 MB          49 MB
   3    20 ms        62 MB          57 MB
   4    29 ms        83 MB          66 MB
   5    19 ms        104 MB         69 MB
   6    19 ms        135 MB         76 MB

   if nothing were shared: 6 x 256 MiB = 1536 MB

3 · Give each one a different future
   fork 1 sees: BASE-IMAGE fork-1
   fork 2 sees: BASE-IMAGE fork-2
   ...
   fork 6 sees: BASE-IMAGE fork-6
```

Read the two right-hand columns. Six machines, each of which believes it has 256 MiB, cost
**76 MB of system memory between them** instead of 1536 MB.

And read the left one: **the sixth restore is as fast as the first.** Nothing is copied
per machine, so nothing gets slower as machines accumulate.

### Shared past, separate futures

`BASE-IMAGE` was written into the guest once, before the snapshot, before any of these
machines existed. All six remember it, because all six *are* that machine.

`fork-N` was written after they resumed. Each sees only its own, because from the instant
of the restore they are strangers.

That is a stronger statement than "the VMs are isolated". They are isolated *and* they
share everything they have in common, for free, with no coordination.

---

## Part 3 · Why an agent wants this

Every chapter so far has been building toward a sandbox an agent can use. This is the one
that changes what the agent can *do*.

A snapshot taken after the environment is ready — dependencies installed, repository
cloned, test suite warm — is a fork point. From it you can start ten machines in the time
it takes to start one, and have each try a different thing:

```
              ┌─ fork 1 ── try the null check ──── tests fail
              │
  snapshot ───┼─ fork 2 ── try the early return ── tests pass
   (env ready)│
              ├─ fork 3 ── try the type change ─── tests fail
              │
              └─ fork 4 ── revert and retry ────── tests pass
```

Without forking, that is four sequential boots and four sequential setups. With it, the
setup happened once, before any of them, and the four attempts are the only thing that
costs anything.

This is also the shape of reinforcement learning on real environments — roll out N
trajectories from one checkpoint — which is why the same primitive shows up in agent
platforms and in training infrastructure.

---

## Try It

```bash
cd ../s03_snapshot_restore && make && ./tinysnap && cd -
make && ./tinyfork
./fork.sh
FORKS=12 ./fork.sh
```

Worth doing next:

- Change `MAP_PRIVATE` to `MAP_SHARED` in `tinyfork.c`. The machines now write **through**
  to the file, so the snapshot changes under them and the last line reports `MODIFIED`.
  You have just turned a fork point into shared mutable state between four VMs.
- Run `FORKS=12 ./fork.sh` and watch the per-restore time refuse to grow.
- While `fork.sh` is running, `cat /proc/<pid>/smaps_rollup` for one of the firecracker
  processes and compare `Private_Dirty` with `Rss`. The gap is what sharing bought you.

---

## What You Just Learned

1. **Forking a machine is `MAP_PRIVATE`.** Not a feature someone implemented — a flag on
   `mmap` that hands you the kernel's copy-on-write machinery, pointed at guest RAM.

2. **The Nth machine costs only its differences.** Six 256 MiB VMs fit in 76 MB because
   they have barely diverged. Restore time stays flat for the same reason: nothing is
   copied up front.

3. **A snapshot is a fork point, not a backup.** Restoring never consumes it, and no
   restored machine can write back to it. That is what makes it safe to hand the same
   file to everyone.

4. **This is the primitive that changes what agents can do.** Prepare an environment once,
   then explore many futures from it in parallel, paying only for where they differ.

---

## Going Deeper

- **`userfaultfd` again.** s03 mentioned `mem_backend: {backend_type: "Uffd"}`. Combined
  with forking, it is how a platform keeps one base image in object storage and serves
  page faults for thousands of sandboxes from it.
- **KSM (Kernel Samepage Merging).** `/sys/kernel/mm/ksm/` finds identical pages across
  processes that did *not* come from a shared file, and merges them. It is the fallback
  for sharing you did not plan for; forking is the sharing you did.
- **`smaps_rollup`.** `Private_Dirty` against `Rss` in `/proc/<pid>/smaps_rollup` is the
  measurement this chapter is about, per process, without the arithmetic.
- **Diff snapshots.** Firecracker's `snapshot_type: "Diff"` writes only pages changed
  since a base — the same idea applied to the files instead of to memory.

---

**Next:** [s06 — Someone has to be inside](../s06_in_vm_agent/)
You can start machines, freeze them and fork them. You still cannot ask one to run a
command.
