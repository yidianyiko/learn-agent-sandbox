/*
 * tinysnap.c — snapshot and restore a virtual machine, by hand.
 *
 * s02 built a VM. This adds the two operations that make a sandbox
 * useful, and they turn out to be shorter than you would expect:
 *
 *     snapshot = write(guest memory) + KVM_GET_REGS + KVM_GET_SREGS
 *     restore  = read (guest memory) + KVM_SET_REGS + KVM_SET_SREGS
 *
 * There is no magic step. Guest memory is a region this process owns
 * (s02), so saving it is a write(); the CPU's state is a few hundred
 * bytes the kernel will hand over on request.
 *
 * The guest here counts: it prints a digit, increments a register, and
 * loops. Run the program once and it prints 01234, then saves. Run it
 * again with `restore` — a DIFFERENT process — and the counting picks
 * up where it stopped.
 *
 * Build: make        Run: ./tinysnap  then  ./tinysnap restore
 */

#include <fcntl.h>
#include <linux/kvm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define MEM_SIZE   0x1000          /* one page is plenty for a counter */
#define GUEST_PHYS 0x1000
#define MEM_FILE   "snapshot.mem"  /* the guest's RAM, byte for byte   */
#define CPU_FILE   "snapshot.cpu"  /* what the processor was doing     */

#define MUST(x, msg) do { if ((long)(x) < 0) { perror(msg); exit(1); } } while (0)

/* Everything about the processor that has to come back. Firecracker
 * saves considerably more than this — FPU, MSRs, the local APIC, the
 * clock — but the shape is the same: ask KVM, write the bytes down. */
struct cpu_state {
    struct kvm_regs  regs;         /* rip, rax..rbx, rflags        */
    struct kvm_sregs sregs;        /* segments, control registers  */
};

/*
 *   88 d8        mov  al, bl      ; take the counter
 *   04 30        add  al, '0'     ; make it printable
 *   ba f8 03     mov  dx, 0x3f8   ; the serial port
 *   ee           out  dx, al      ; print it        -> VM exit
 *   fe c3        inc  bl          ; count up
 *   eb f4        jmp  -12         ; forever
 */
static const unsigned char guest_code[] = {
    0x88, 0xd8, 0x04, 0x30, 0xba, 0xf8, 0x03, 0xee, 0xfe, 0xc3, 0xeb, 0xf4,
};

static void read_file(const char *path, void *dst, size_t n, const char *what)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "no %s at %s — run ./tinysnap first\n", what, path); exit(1); }
    if (fread(dst, 1, n, f) != n) { fprintf(stderr, "%s is truncated\n", path); exit(1); }
    fclose(f);
}

static void write_file(const char *path, const void *src, size_t n)
{
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); exit(1); }
    if (fwrite(src, 1, n, f) != n) { perror(path); exit(1); }
    fclose(f);
}

int main(int argc, char **argv)
{
    int restoring = (argc > 1 && strcmp(argv[1], "restore") == 0);

    /* --- an ordinary VM, exactly as in s02 --------------------------- */
    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    MUST(kvm, "open /dev/kvm");
    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    MUST(vm, "KVM_CREATE_VM");

    void *mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) { perror("mmap guest memory"); exit(1); }

    /* --- RESTORE, part 1: the memory -------------------------------- *
     * Fill the page from the file instead of from the program. As far
     * as the guest is concerned nothing happened; it wakes up with the
     * same bytes it fell asleep with. */
    if (restoring) read_file(MEM_FILE, mem, MEM_SIZE, "memory snapshot");
    else           memcpy(mem, guest_code, sizeof guest_code);

    struct kvm_userspace_memory_region region = {
        .slot = 0, .guest_phys_addr = GUEST_PHYS,
        .memory_size = MEM_SIZE, .userspace_addr = (unsigned long)mem,
    };
    MUST(ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region), "KVM_SET_USER_MEMORY_REGION");

    int vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    MUST(vcpu, "KVM_CREATE_VCPU");
    int run_size = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
    struct kvm_run *run = mmap(NULL, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    if (run == MAP_FAILED) { perror("mmap kvm_run"); exit(1); }

    struct cpu_state st;

    if (restoring) {
        /* --- RESTORE, part 2: the processor -------------------------
         * Two ioctls. The vCPU was created a moment ago and knows
         * nothing; these hand it someone else's mind. */
        read_file(CPU_FILE, &st, sizeof st, "cpu snapshot");
        MUST(ioctl(vcpu, KVM_SET_SREGS, &st.sregs), "KVM_SET_SREGS");
        MUST(ioctl(vcpu, KVM_SET_REGS,  &st.regs),  "KVM_SET_REGS");
        printf("restored  rip=%llu  rbx=%llu  (%zu bytes of cpu state)\n",
               (unsigned long long)st.regs.rip, (unsigned long long)st.regs.rbx,
               sizeof st);
    } else {
        /* First boot: we are the firmware, same as s02. */
        MUST(ioctl(vcpu, KVM_GET_SREGS, &st.sregs), "KVM_GET_SREGS");
        st.sregs.cs.base = GUEST_PHYS;
        st.sregs.cs.selector = 0;
        MUST(ioctl(vcpu, KVM_SET_SREGS, &st.sregs), "KVM_SET_SREGS");
        struct kvm_regs fresh = { .rip = 0, .rbx = 0, .rflags = 0x2 };
        MUST(ioctl(vcpu, KVM_SET_REGS, &fresh), "KVM_SET_REGS");
    }

    /* --- run for five digits, then stop ------------------------------ */
    printf("%s ", restoring ? "after  restore:" : "before snapshot:");
    fflush(stdout);

    for (int printed = 0; printed < 5; ) {
        MUST(ioctl(vcpu, KVM_RUN, 0), "KVM_RUN");
        if (run->exit_reason != KVM_EXIT_IO) {
            fprintf(stderr, "\nunhandled exit_reason %u\n", run->exit_reason);
            return 1;
        }
        fwrite((char *)run + run->io.data_offset, 1, run->io.size, stdout);
        fflush(stdout);
        printed++;
    }
    printf("\n");

    /* --- SNAPSHOT ---------------------------------------------------- *
     * Ask the kernel what the processor is doing, then write that and
     * the page of RAM to two files. That is the whole operation. */
    if (!restoring) {
        MUST(ioctl(vcpu, KVM_GET_REGS,  &st.regs),  "KVM_GET_REGS");
        MUST(ioctl(vcpu, KVM_GET_SREGS, &st.sregs), "KVM_GET_SREGS");
        write_file(CPU_FILE, &st, sizeof st);
        write_file(MEM_FILE, mem, MEM_SIZE);
        printf("snapshot  rip=%llu  rbx=%llu\n"
               "          %-16s %6zu bytes   the processor\n"
               "          %-16s %6d bytes   the memory\n\n"
               "Now run:  ./tinysnap restore\n",
               (unsigned long long)st.regs.rip, (unsigned long long)st.regs.rbx,
               CPU_FILE, sizeof st, MEM_FILE, MEM_SIZE);
    }
    return 0;
}
