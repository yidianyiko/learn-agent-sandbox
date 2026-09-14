/*
 * tinyvmm.c — a virtual machine monitor, in 79 lines of code.
 *
 * It creates a VM, gives it one page of memory and one CPU, loads twelve
 * bytes of machine code, and runs it. The guest adds two numbers the host
 * handed it, prints the answer through a serial port that does not exist,
 * and halts.
 *
 * Every ioctl below is the same one Firecracker issues. This is not a
 * simplified model of virtualisation; it is virtualisation, with the
 * device emulation left out.
 *
 * Build: make      Run: ./tinyvmm
 */

#include <fcntl.h>        /* open           */
#include <linux/kvm.h>    /* KVM_* ioctls and structs */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>       /* memcpy         */
#include <sys/ioctl.h>    /* ioctl          */
#include <sys/mman.h>     /* mmap           */
#include <unistd.h>

/* Bail out loudly instead of limping on with a bad file descriptor. */
#define MUST(x, msg) do { if ((long)(x) < 0) { perror(msg); exit(1); } } while (0)

int main(void)
{
    /*
     * The guest program, hand-assembled. It runs in 16-bit real mode,
     * which is the state an x86 CPU wakes up in.
     *
     *   02 c3        add  al, bl      ; al = al + bl   <- values from the host
     *   88 c1        mov  cl, al      ; keep the numeric answer in cl
     *   04 30        add  al, '0'     ; turn 5 into the character '5'
     *   ba f8 03     mov  dx, 0x3f8   ; 0x3f8 is COM1, the first serial port
     *   ee           out  dx, al      ; send al to that port  -> VM exit
     *   b0 0a        mov  al, '\n'
     *   ee           out  dx, al      ; and again             -> VM exit
     *   f4           hlt              ; stop                  -> VM exit
     */
    const unsigned char guest_code[] = {
        0x02, 0xc3, 0x88, 0xc1, 0x04, 0x30, 0xba, 0xf8, 0x03, 0xee, 0xb0, 0x0a, 0xee, 0xf4,
    };

    /* ------------------------------------------------------------------
     * 1. Open the door.
     *
     * /dev/kvm is a character device. Opening it gives a file descriptor
     * that we steer with ioctl() — the Unix way of saying "do a thing that
     * read() and write() cannot express".
     * ------------------------------------------------------------------ */
    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    MUST(kvm, "open /dev/kvm (are you in the kvm group?)");
    printf("kvm      api version %d\n", ioctl(kvm, KVM_GET_API_VERSION, 0));

    /* ------------------------------------------------------------------
     * 2. Ask for a machine.
     *
     * This returns another file descriptor. The pattern repeats all the
     * way down: a VM fd owns vCPU fds, and each fd accepts its own ioctls.
     * ------------------------------------------------------------------ */
    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    MUST(vm, "KVM_CREATE_VM");

    /* ------------------------------------------------------------------
     * 3. Donate memory.
     *
     * A guest's "physical memory" is just a region of the VMM's own
     * virtual memory. We ask the kernel for one page, copy the program
     * into it, and tell KVM that this page appears at guest physical
     * address 0x1000.
     *
     * This is why a microVM starts so cheaply: handing it RAM is an mmap,
     * not an allocation of real hardware.
     * ------------------------------------------------------------------ */
    const size_t MEM_SIZE = 0x1000;               /* one 4 KiB page */
    void *mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    /* mmap reports failure with MAP_FAILED, not a negative int, so it does
     * not fit MUST(). Spelled out rather than bent to fit the macro. */
    if (mem == MAP_FAILED) { perror("mmap guest memory"); exit(1); }
    memcpy(mem, guest_code, sizeof guest_code);

    struct kvm_userspace_memory_region region = {
        .slot            = 0,
        .guest_phys_addr = 0x1000,
        .memory_size     = MEM_SIZE,
        .userspace_addr  = (unsigned long)mem,
    };
    MUST(ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region), "KVM_SET_USER_MEMORY_REGION");
    printf("memory   %zu bytes at guest 0x%llx\n",
           MEM_SIZE, (unsigned long long)region.guest_phys_addr);

    /* ------------------------------------------------------------------
     * 4. Ask for a CPU, and find the mailbox.
     *
     * KVM communicates the reason for each exit through a struct shared
     * between kernel and userspace. We mmap the vCPU fd to get at it, so
     * no copying happens on the hot path.
     * ------------------------------------------------------------------ */
    int vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    MUST(vcpu, "KVM_CREATE_VCPU");

    int run_size = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
    MUST(run_size, "KVM_GET_VCPU_MMAP_SIZE");
    struct kvm_run *run = mmap(NULL, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    if (run == MAP_FAILED) { perror("mmap kvm_run"); exit(1); }
    printf("vcpu     shared struct is %d bytes\n", run_size);

    /* ------------------------------------------------------------------
     * 5. Pose the CPU.
     *
     * A real CPU powers on in 16-bit real mode with cs:ip pointing at the
     * reset vector. We are the firmware here, so we set that state by
     * hand: code segment based at our page, instruction pointer at zero.
     *
     * Then we put the operands in registers. The guest never "reads input"
     * — the host simply writes its registers before it starts.
     * ------------------------------------------------------------------ */
    struct kvm_sregs sregs;
    MUST(ioctl(vcpu, KVM_GET_SREGS, &sregs), "KVM_GET_SREGS");
    sregs.cs.base     = 0x1000;   /* where our code sits */
    sregs.cs.selector = 0;
    MUST(ioctl(vcpu, KVM_SET_SREGS, &sregs), "KVM_SET_SREGS");

    struct kvm_regs regs = {
        .rip    = 0,      /* offset within cs */
        .rax    = 2,      /* al = 2  }  the guest will add these */
        .rbx    = 3,      /* bl = 3  }                            */
        .rflags = 0x2,    /* bit 1 is reserved and must be set    */
    };
    MUST(ioctl(vcpu, KVM_SET_REGS, &regs), "KVM_SET_REGS");
    printf("registers host wrote rax=%llu rbx=%llu\n\n",
           (unsigned long long)regs.rax, (unsigned long long)regs.rbx);

    /* ------------------------------------------------------------------
     * 6. Run it.
     *
     * KVM_RUN does not return until the guest does something the kernel
     * will not handle alone. Until then the PHYSICAL cpu is executing the
     * guest's instructions directly.
     *
     * This loop is the entire concept of device emulation. The guest
     * believes it is talking to a serial port. There is no serial port.
     * There is a switch statement.
     * ------------------------------------------------------------------ */
    printf("guest says: ");
    fflush(stdout);

    int exits = 0;
    for (;;) {
        MUST(ioctl(vcpu, KVM_RUN, 0), "KVM_RUN");
        exits++;

        switch (run->exit_reason) {
        case KVM_EXIT_IO:
            /* The data the guest wrote lives inside the shared struct, at
             * an offset KVM tells us.
             *
             * SIMPLIFICATION: we ignore run->io.count. A `rep outsb` moves
             * several bytes per exit and a real VMM loops over them. Our
             * guest only issues single-byte `out`, so count is always 1 —
             * this works, which is not the same as being correct. It is one
             * concrete instance of the gap between these three lines and
             * Firecracker's 592-line serial.rs. */
            if (run->io.direction == KVM_EXIT_IO_OUT && run->io.port == 0x3f8) {
                fwrite((char *)run + run->io.data_offset, 1, run->io.size, stdout);
                fflush(stdout);
            }
            break;

        case KVM_EXIT_HLT:
            /* Read the registers back out — the same control surface,
             * in the other direction. */
            MUST(ioctl(vcpu, KVM_GET_REGS, &regs), "KVM_GET_REGS");
            printf("\nguest halted after %d vm exits\n", exits);
            printf("registers host read  rcx=%llu   <- the arithmetic the guest did\n",
                   (unsigned long long)(regs.rcx & 0xff));
            return 0;

        default:
            fprintf(stderr, "\nunhandled exit_reason %u\n", run->exit_reason);
            return 1;
        }
    }
}
