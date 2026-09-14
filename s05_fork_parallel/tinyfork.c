/*
 * tinyfork.c — many machines from one snapshot, sharing its memory.
 *
 * s03 wrote a machine to two files and read it back. Read it back four
 * times at once and you have four machines, which raises the question
 * this chapter is about: does the fourth one cost as much as the first?
 *
 * It does not, and the reason is one flag:
 *
 *     MAP_PRIVATE   pages are shared with the file until you write to
 *                   one, at which point you silently get your own copy
 *
 * So four machines read the same physical memory, diverge only where
 * they differ, and none of them can touch the snapshot they came from.
 *
 * Run ../s03_snapshot_restore/tinysnap first to produce the snapshot.
 *
 * Build: make        Run: ./tinyfork
 */

#include <fcntl.h>
#include <linux/kvm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define MEM_SIZE   0x1000
#define GUEST_PHYS 0x1000
#define FORKS      4
#define SNAP_DIR   "../s03_snapshot_restore/"

struct cpu_state {
    struct kvm_regs  regs;
    struct kvm_sregs sregs;
};

/* One child: its own VM, built on a private view of the shared file. */
static void run_one(int n, int memfd)
{
    /* The whole chapter is this call.
     *
     * MAP_PRIVATE, not MAP_SHARED: reads come straight from the page
     * cache that every sibling is also reading, so nothing is copied
     * until this machine writes — and when it does, the copy is its own
     * and the file never learns about it. */
    void *mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE, memfd, 0);
    if (mem == MAP_FAILED) { perror("mmap"); _exit(1); }

    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) { perror("open /dev/kvm"); _exit(1); }
    int vm = ioctl(kvm, KVM_CREATE_VM, 0);

    struct kvm_userspace_memory_region region = {
        .slot = 0, .guest_phys_addr = GUEST_PHYS,
        .memory_size = MEM_SIZE, .userspace_addr = (unsigned long)mem,
    };
    ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region);

    int vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    int run_size = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
    struct kvm_run *run = mmap(NULL, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    if (run == MAP_FAILED) { perror("mmap kvm_run"); _exit(1); }

    struct cpu_state st;
    FILE *f = fopen(SNAP_DIR "snapshot.cpu", "rb");
    if (!f || fread(&st, sizeof st, 1, f) != 1) {
        fprintf(stderr, "cannot read snapshot.cpu — run ../s03_snapshot_restore/tinysnap\n");
        _exit(1);
    }
    fclose(f);

    /* Same machine, different future: each child resumes the snapshot
     * with its own counter, so their outputs diverge immediately. */
    st.regs.rbx = n;
    ioctl(vcpu, KVM_SET_SREGS, &st.sregs);
    ioctl(vcpu, KVM_SET_REGS,  &st.regs);

    char digits[16] = {0};
    for (int i = 0; i < 5; ) {
        ioctl(vcpu, KVM_RUN, 0);
        if (run->exit_reason != KVM_EXIT_IO) break;
        digits[i++] = *((char *)run + run->io.data_offset);
    }

    /* Scribble on our own copy, to show it stays ours. */
    ((unsigned char *)mem)[100] = 0xA0 + n;

    /* Four children are writing to one terminal. Build the line first
     * and emit it with a single write, or they interleave into noise. */
    char line[128];
    int len = snprintf(line, sizeof line,
                       "   fork %d   resumes at %d   prints %s   wrote 0x%02X to its own page\n",
                       n, n, digits, 0xA0 + n);
    if (write(STDOUT_FILENO, line, (size_t)len) < 0) _exit(1);
    _exit(0);
}

int main(void)
{
    int memfd = open(SNAP_DIR "snapshot.mem", O_RDONLY);
    if (memfd < 0) {
        fprintf(stderr, "no snapshot.mem — run ../s03_snapshot_restore/tinysnap first\n");
        return 1;
    }

    unsigned char before[8], after[8];
    if (pread(memfd, before, sizeof before, 100) != (ssize_t)sizeof before) return 1;

    printf("one snapshot, %d machines\n\n", FORKS);

    /* fork() copies this process's stdio buffer along with everything
     * else. Without this flush the line above is still sitting in it,
     * and every child prints a second copy on the way out. */
    fflush(stdout);

    for (int n = 1; n <= FORKS; n++)
        if (fork() == 0) run_one(n, memfd);
    for (int n = 0; n < FORKS; n++) wait(NULL);

    if (pread(memfd, after, sizeof after, 100) != (ssize_t)sizeof after) return 1;
    printf("\nsnapshot.mem, byte 100:  before 0x%02X   after 0x%02X   %s\n",
           before[0], after[0],
           memcmp(before, after, sizeof before) == 0 ? "unchanged" : "MODIFIED");
    printf("   every machine wrote there. None of them reached the file.\n");
    return 0;
}
