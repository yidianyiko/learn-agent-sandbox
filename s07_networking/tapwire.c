/*
 * tapwire.c — a network interface is a file descriptor.
 *
 * A tap device is an ethernet interface whose cable is an open file. The
 * kernel treats it like any other NIC: give it an address, route to it,
 * ping it. But instead of copper, the far end is whatever process holds
 * the descriptor — here, this program, printing every frame that arrives.
 *
 * That is the whole trick behind virtual machine networking. Firecracker
 * holds one of these, hands the other end to the guest as a virtio-net
 * device, and neither side knows it is not a wire.
 *
 * Creating the interface needs CAP_NET_ADMIN, which is why demo.sh uses
 * sudo for that one step. Nothing else in this repository does.
 *
 * Build: make        Run: ./tapwire <ifname>
 */

#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define FRAMES 8

int main(int argc, char **argv)
{
    /* printf is fully buffered when stdout is a pipe, and this program is
     * usually killed rather than allowed to finish. Unbuffered, or the
     * output dies with it. */
    setvbuf(stdout, NULL, _IONBF, 0);

    const char *name = argc > 1 ? argv[1] : "tap0";

    int fd = open("/dev/net/tun", O_RDWR);
    if (fd < 0) { perror("open /dev/net/tun"); return 1; }

    /* IFF_TAP  — deal in ethernet frames, not bare IP packets (IFF_TUN)
     * IFF_NO_PI — no extra 4-byte header in front of each frame       */
    struct ifreq ifr = {0};
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        perror("TUNSETIFF");
        fprintf(stderr, "the interface must exist and be owned by you:\n"
                        "  sudo ip tuntap add dev %s mode tap user $USER\n", name);
        return 1;
    }

    printf("holding the wire for %s  (fd %d)\n", ifr.ifr_name, fd);
    printf("every frame the kernel sends out that interface now arrives here\n\n");

    unsigned char buf[2048];
    for (int n = 0; n < FRAMES; n++) {
        ssize_t len = read(fd, buf, sizeof buf);
        if (len < 14) continue;

        /* Ethernet header: 6 bytes destination, 6 source, 2 ethertype. */
        unsigned short type = (unsigned short)((buf[12] << 8) | buf[13]);
        const char *what = type == 0x0806 ? "ARP"
                         : type == 0x0800 ? "IPv4"
                         : type == 0x86DD ? "IPv6" : "?";

        printf("  %4zd bytes  %02x:%02x:%02x:%02x:%02x:%02x -> %02x:%02x:%02x:%02x:%02x:%02x  %-4s",
               len,
               buf[6], buf[7], buf[8], buf[9], buf[10], buf[11],
               buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], what);

        if (type == 0x0800 && len >= 34)
            printf("  %d.%d.%d.%d -> %d.%d.%d.%d  proto %d",
                   buf[26], buf[27], buf[28], buf[29],
                   buf[30], buf[31], buf[32], buf[33], buf[23]);
        if (type == 0x0806 && len >= 42)
            printf("  who has %d.%d.%d.%d?", buf[38], buf[39], buf[40], buf[41]);
        printf("\n");
    }
    printf("\nnothing answered, because nothing is plugged in yet.\n");
    return 0;
}
