# s02: Write the hypervisor yourself

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/) → [s01](../s01_first_microvm/) → **s02** → [s03](../s03_snapshot_restore/) → ... → s08

> **Needs:** `/dev/kvm`, a C compiler (`gcc` or `clang`), `make`. No root.
> **Time:** about 30 minutes. You do not need to know C — see below.

> *"There is no device. There is a switch statement."*

---

## The Problem

In [s01](../s01_first_microvm/) you made four HTTP calls and a machine appeared. That is
a fair description of what a user does. It is not an explanation.

The [`/dev/kvm` briefing](../notes/kvm-device.md) claimed that `KVM_RUN` puts a physical
CPU into guest mode and executes instructions you supply. You were *told* that. You have
not done it.

So this chapter has no Firecracker in it. We write the hypervisor.

---

## The Solution

`tinyvmm.c` — **79 lines of code**, no libraries beyond libc. It creates a VM, gives it
one page of memory and one CPU, loads twelve bytes of machine code, runs them, and prints
what the guest produced.

```
$ make && ./tinyvmm
kvm      api version 12
memory   4096 bytes at guest 0x1000
vcpu     shared struct is 12288 bytes
registers host wrote rax=2 rbx=3

guest says: 5

guest halted after 3 vm exits
registers host read  rcx=5   <- the arithmetic the guest did
```

That `5` was computed by your physical CPU, executing the guest's instructions, in a mode
where it could not see your memory. The host put `2` and `3` into registers before
starting; the guest added them; the host read the answer back out afterwards.

---

## Five things you need to know to read this C

You do not need to *write* C for this chapter. You need to read 79 lines of it, and
almost all of them are one of five shapes.

**1 · A file descriptor is a small integer that names an open thing.**

```c
int kvm = open("/dev/kvm", O_RDWR);
```

`kvm` is now (say) `3`. Every later call passes that number to say *which* open thing you
mean. Think of it as a handle, not a value.

**2 · `ioctl` is "do a thing this handle supports."**

```c
ioctl(kvm, KVM_CREATE_VM, 0);
```

`read()` and `write()` cover moving bytes. Everything else a device can do — "create a
VM", "set these registers", "run" — goes through `ioctl(handle, WHICH_OPERATION,
argument)`. The whole KVM API is this one function called with different constants.

**3 · A `struct` is a named group of fields; `.field = value` fills one in.**

```c
struct kvm_regs regs = {
    .rip = 0,
    .rax = 2,
};
```

Fields you do not mention are zero. These structs are defined in `<linux/kvm.h>` and are
the exact memory layout the kernel expects — which is why this interface is a C interface
even when the caller is Rust.

**4 · `mmap` asks the kernel for memory, or for a window onto something.**

```c
void *mem = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
```

Used twice here, for two different reasons. Once to get a blank page that becomes the
guest's RAM. Once to get a *window onto a kernel structure* — so that after `KVM_RUN`
returns we can read why it stopped without copying anything.

**5 · A pointer plus an offset is just an address.**

```c
(char *)run + run->io.data_offset
```

This is the one line that looks cryptic. `run` points at the shared structure; KVM tells
us the byte the guest wrote lives `data_offset` bytes further along. So: start at `run`,
walk forward that many bytes, read from there.

That is the entire vocabulary. Everything else is `printf`.

---

## How It Works

Six steps, in order, matching the comments in the file.

### 1 · Open the door

```c
int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
ioctl(kvm, KVM_GET_API_VERSION, 0);     // -> 12
```

Version 12 has been the answer since 2007. It is checked because the ABI *promises* to be
stable at that number, and a different one would mean you are somewhere very strange.

### 2 · Ask for a machine

```c
int vm = ioctl(kvm, KVM_CREATE_VM, 0);
```

This returns **another file descriptor**. The pattern nests all the way down: the `/dev/kvm`
handle makes VM handles, a VM handle makes vCPU handles, and each level accepts its own
ioctls. Close the VM handle and the machine is gone.

### 3 · Donate memory

```c
void *mem = mmap(NULL, 0x1000, ...);          // one 4 KiB page
memcpy(mem, guest_code, sizeof guest_code);

struct kvm_userspace_memory_region region = {
    .guest_phys_addr = 0x1000,                 // where it appears to the guest
    .memory_size     = 0x1000,
    .userspace_addr  = (unsigned long)mem,     // where it really is
};
ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region);
```

**A guest's physical memory is a region of the VMM's virtual memory.** That sentence is
worth rereading. There is no special allocation, no reserved hardware. You hand the kernel
an address range you already own and say "the guest sees this at 0x1000".

This is why giving a microVM 256 MB costs nothing until it is touched, and it is the
mechanism that makes snapshots and copy-on-write forking possible later.

### 4 · Ask for a CPU, and find the mailbox

```c
int vcpu     = ioctl(vm, KVM_CREATE_VCPU, 0);
int run_size = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);      // 12288 on this machine
struct kvm_run *run = mmap(NULL, run_size, ..., vcpu, 0);
```

`struct kvm_run` is shared between the kernel and you. When the guest stops, the kernel
fills this in and returns; you read it directly. No copying, no message passing — the exit
path is a memory read, because it runs millions of times.

### 5 · Pose the CPU

```c
struct kvm_sregs sregs;
ioctl(vcpu, KVM_GET_SREGS, &sregs);
sregs.cs.base     = 0x1000;    // code segment points at our page
sregs.cs.selector = 0;
ioctl(vcpu, KVM_SET_SREGS, &sregs);

struct kvm_regs regs = { .rip = 0, .rax = 2, .rbx = 3, .rflags = 0x2 };
ioctl(vcpu, KVM_SET_REGS, &regs);
```

An x86 CPU wakes up in **16-bit real mode**, the same state it has been waking up in since
1978, looking at a fixed address for its first instruction. On real hardware the firmware
sets up what comes next. **Here, you are the firmware.**

Note what happens with `rax` and `rbx`: the guest has no input, no arguments, no file to
read. The host simply writes its registers before it starts. That is the entire calling
convention between a VMM and its guest.

### 6 · Run it

```c
for (;;) {
    ioctl(vcpu, KVM_RUN, 0);              // physical CPU executes guest instructions
    switch (run->exit_reason) {
    case KVM_EXIT_IO:
        if (run->io.direction == KVM_EXIT_IO_OUT && run->io.port == 0x3f8)
            fwrite((char *)run + run->io.data_offset, 1, run->io.size, stdout);
        break;
    case KVM_EXIT_HLT:
        return 0;
    }
}
```

`KVM_RUN` does not return while things are going well. The physical core is running guest
code at full speed, and the kernel is not involved. It returns only when the guest does
something that needs someone outside — here, an `out` instruction to port `0x3f8`.

**The guest believes it is talking to a serial port. There is no serial port. There is a
`case` label.**

Three exits happened in this program: two `out` instructions and one `hlt`. Every device a
virtual machine has ever had is this shape.

---

## Try It

```bash
cd s02_write_a_vmm
make
./tinyvmm
```

Things worth doing next, in ascending order of interest:

- Change `.rax` and `.rbx` and watch the printed digit change. You just passed arguments
  into a virtual machine.
- Change the port in `guest_code` from `0x3f8` to something else and watch the `if` stop
  matching. You have now unplugged a device.
- Delete the `KVM_EXIT_HLT` case. The guest halts, your switch falls through to `default`,
  and you learn what a VMM does when it meets a guest it does not understand.

---

## So what are the other 120,626 lines doing?

Firecracker v1.17.0 is **120,626 lines of Rust**, excluding tests. You just wrote 79 lines
that virtualise a CPU. It is worth being precise about where the difference goes, because
the honest answer is not "they were inefficient."

Measured from the v1.17.0 source tree:

| | lines | what it is |
|---|---:|---|
| `vmm/src/devices/` | **40,306** | **device emulation — 33% of everything** |
| `vmm/src/arch/` | 12,015 | boot protocol, memory layout, per-architecture setup |
| `vmm/src/dumbo/` | 6,514 | a small TCP/IP stack, for the metadata service |
| `vmm/src/vstate/` | **6,333** | **vCPU, VM and memory state — the part you just wrote** |
| `vmm/src/cpu_config/` | 6,283 | CPU feature masking, so a snapshot restores on a different host |
| `vmm/src/device_manager/` | 4,293 | wiring devices to buses and interrupts |
| `vmm/src/mmds/` | 2,776 | the instance metadata service |
| `vmm/src/io_uring/` | 2,773 | asynchronous disk I/O |
| `vmm/src/rate_limiter/` | 1,400 | per-device throughput limits, because tenants share hardware |
| `jailer/` | 3,170 | putting the VMM itself in a chroot with its own namespaces |
| `seccompiler/` | 634 | compiling the syscall allowlist the VMM confines itself to |

And inside `devices/`:

| | lines |
|---|---:|
| `virtio/vsock/` | 6,937 |
| `virtio/block/` | 6,625 |
| `virtio/net/` | 5,174 |
| `virtio/transport/` | 4,544 |
| `virtio/balloon/` | 3,020 |
| `legacy/serial.rs` | **592** |

That last row is the one to sit with. **Your three-line `case KVM_EXIT_IO` is
`serial.rs`, and `serial.rs` is 592 lines.**

The difference is not cleverness. It is that a real 16550 UART has a transmit buffer, a
receive buffer, interrupt enable registers, a line status register, a modem control
register, flow control, and a guest that will read all of them and behave differently
based on what it finds. Your version handles the one path Linux happens to take when it
prints a character. Theirs handles what the hardware actually promises, because a guest
kernel is entitled to rely on any of it.

Multiply that by every device a machine needs. Then add:

- **The Linux boot protocol** — `arch/` exists because you cannot just set `rip` and go
  when the payload is a kernel. There is a setup header to fill in, an e820 memory map to
  synthesise, a zero page to construct, and CPUID leaves to present.
- **Snapshot and restore** — much of `vstate/` and all of `cpu_config/` is about capturing
  a machine's state and putting it back, possibly on a different CPU model. That is s03.
- **Being safe while hostile code runs inside** — `jailer/`, `seccompiler/`, and the
  rate limiters exist because Firecracker's threat model is that the guest is an attacker
  and the VMM is the last thing between it and the host.

**None of that is virtualisation.** Virtualisation was finished at line 60 of your file.
Everything above is device emulation, hardware compatibility, and not getting owned.

> Your 79 lines : `vstate/` 6,333 : the whole VMM 120,626.
> The ratio is roughly 1 : 80 : 1,500 — and the 1,500 is what it costs to turn a working
> idea into something you would let strangers run code in.

This is also the honest reason this repository does not try to rewrite Firecracker. Not
because it is hard, though it is. Because those 120,000 lines are *volume* — necessary,
skilled, unglamorous volume — and you have already learned the idea.

---

## What You Just Learned

1. **Virtualisation is small.** Open a device, ask for a VM, donate memory, ask for a CPU,
   set registers, loop on `KVM_RUN`. Six steps, 79 lines, no library.

2. **Device emulation is a switch statement.** Every virtual serial port, disk and network
   card is a `case` in someone's exit loop. The hardware does not exist; the *contract*
   does, and the VMM keeps it.

3. **Guest memory is your memory.** `KVM_SET_USER_MEMORY_REGION` hands the guest a slice
   of the VMM's own address space. Remember this in s03 — it is why a snapshot is a file
   and a fork is cheap.

4. **The hard part is not the idea.** 33% of Firecracker is pretending to be hardware
   accurately enough that a real kernel is fooled, and a meaningful slice of the rest is
   staying safe while doing it. That is where the work is, and it is why using their
   implementation is the right call.

---

## Going Deeper

- **`Documentation/virt/kvm/api.rst`** in the Linux source is the authoritative reference
  for every ioctl used here, and the several hundred not used here.
- **[`kvm-ioctls`](https://github.com/rust-vmm/kvm-ioctls)** is the Rust crate wrapping
  exactly these calls — and it is the crate Firecracker uses. Reading it after writing
  `tinyvmm.c` is unusually easy, because you know what every function is for.
- **[`rust-vmm`](https://github.com/rust-vmm)** is the wider set of crates Firecracker,
  Cloud Hypervisor and crosvm share. The device emulation you just skipped is most of it.
- **`src/vmm/src/devices/legacy/serial.rs`** in the Firecracker tree, 592 lines. Read it
  next to your three-line `case`. It is the clearest possible picture of the gap between
  a demonstration and a product.

---

**Next:** [s03 — Don't boot. Restore.](../s03_snapshot_restore/)
Your guest's memory is a region you own. So what happens if you write it to a file?
