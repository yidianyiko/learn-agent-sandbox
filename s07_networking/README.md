# s07: Now let it reach the internet

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/) → ... → [s05](../s05_fork_parallel/) → [s06](../s06_in_vm_agent/) → **s07** → [s08](../s08_sdk_and_agent/)

> **Needs:** `/dev/kvm`, cargo, a C compiler, the fetched assets — and **sudo**, for the
> first and only time in this repository.
> **Time:** about 30 minutes.

> *"Now let it reach the internet."*

---

## The Problem

[s06](../s06_in_vm_agent/) put somebody inside the machine and gave you a way to talk to
them, over a channel that needs no network at all. That was the point: a sandbox you can
command without exposing it.

But an agent that can run commands and cannot `pip install` anything is not much of an
agent. At some point the machine has to reach out.

---

## Part 1 · A network interface is a file descriptor

```bash
make && ./demo.sh
```

```
1 · A tap device is a wire whose far end is a file descriptor

   created fcnet0, gave it 172.16.77.1

   holding the wire for fcnet0  (fd 3)
   every frame the kernel sends out that interface now arrives here

     42 bytes  06:ac:b3:6c:8e:27 -> ff:ff:ff:ff:ff:ff  ARP   who has 172.16.77.2?
     42 bytes  06:ac:b3:6c:8e:27 -> ff:ff:ff:ff:ff:ff  ARP   who has 172.16.77.2?
     42 bytes  06:ac:b3:6c:8e:27 -> ff:ff:ff:ff:ff:ff  ARP   who has 172.16.77.2?

   nothing answered, because nothing is plugged in yet.
```

A **tap device** is an ethernet interface the kernel treats as entirely real — you give it
an address, you route to it, you ping it — except that instead of copper, the far end is an
open file. Whoever holds that descriptor is the rest of the network.

Creating one is three lines:

```c
int fd = open("/dev/net/tun", O_RDWR);
struct ifreq ifr = { .ifr_flags = IFF_TAP | IFF_NO_PI };
strncpy(ifr.ifr_name, "fcnet0", IFNAMSIZ - 1);
ioctl(fd, TUNSETIFF, &ifr);
```

- **`IFF_TAP`** — deal in ethernet frames. (`IFF_TUN` would give you bare IP packets, one
  layer up.)
- **`IFF_NO_PI`** — no extra header in front of each frame; give us what went on the wire.

After that, `read(fd)` returns every frame the kernel sends out `fcnet0`, and `write(fd)`
injects frames as if they had arrived on it.

The frames above are the host asking, three times, who owns 172.16.77.2 — and getting no
answer, because act 1 is a cable with nothing on the other end.

**This is the whole of virtual machine networking.** Firecracker holds one of these
descriptors, hands the other side to the guest as a virtio-net device, and neither end can
tell it is not a wire.

---

## Part 2 · Plug a machine in

The VM is configured with the tap as its network interface:

```
PUT /network-interfaces/eth0
{"iface_id": "eth0", "host_dev_name": "fcnet0", "guest_mac": "06:00:AC:10:4D:02"}
```

and the guest's address is set by the kernel itself, from a boot argument:

```
ip=172.16.77.2::172.16.77.1:255.255.255.0::eth0:off
   └ client    └ gateway   └ netmask      └ device └ no autoconf
```

No DHCP, no configuration in userspace. `CONFIG_IP_PNP` brings `eth0` up during boot,
before there is any userspace to do it — which matters when the only thing in your
initramfs is a 180-line agent.

```
   PUT /network-interfaces/eth0 -> 204   (host_dev_name fcnet0)
   agent: up, listening on vsock port 1234

   $ ping -c2 172.16.77.1   (the host, across the tap)
     64 bytes from 172.16.77.1: seq=0 ttl=64 time=0.436 ms
     64 bytes from 172.16.77.1: seq=1 ttl=64 time=0.343 ms
     [exit 0]
```

Same wire as act 1. This time something answered.

Note where the command came from: `vexec` over **vsock**, exactly as in
[s06](../s06_in_vm_agent/). The control path and the data path are different channels —
we are administering the machine over a link that does not depend on the network we are
busy configuring. Lose the network and you can still ask what happened.

---

## Part 3 · NAT, which is just your home router

```
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 172.16.77.0/24 -o eth1 -j MASQUERADE
iptables -A FORWARD -i fcnet0 -j ACCEPT
iptables -A FORWARD -o fcnet0 -j ACCEPT
```

```
   $ echo nameserver 1.1.1.1 > /etc/resolv.conf; wget -qO- http://example.com
     <!doctype html><html lang="en"><head><title>Example Domain</title>...
     [exit 0]
```

That is it. The guest is a host on a /24 with exactly one neighbour, the host forwards for
it, and `MASQUERADE` rewrites the source address on the way out — **the same rule the box
in your hallway applies to your laptop.** Nothing about virtual machines is involved; this
part is ordinary Linux routing, and every trick you know from it applies here.

> ⚠️ **A failed ping is not a failed network.** On WSL2 and many clouds, ICMP does not
> survive the outer NAT while TCP passes happily. The demo runs the HTTP fetch first for
> exactly that reason. Test reachability with the protocol you actually care about.

---

## Which side needed root

This is the first chapter that needs `sudo`, and it is worth being precise about what for:

| Operation | Privilege |
|---|---|
| create the tap device | **root** — `CAP_NET_ADMIN` |
| give it an address, bring it up | **root** |
| one NAT rule and two forward rules | **root** |
| open the tap once it exists and is owned by you | *none* |
| everything the microVM does | *none* |

`/dev/net/tun` is mode `0666` — anyone may open it. What needs the capability is
**creating an interface**, because that changes the host's network, which is a host-wide
thing to change.

So the privilege lives entirely on the side that was always trusted. The machine running
code nobody reviewed still runs as you, with no capabilities, and that is the arrangement
worth preserving: **the sandbox does not become more privileged by being connected.**

---

## Try It

```bash
make && ./demo.sh
```

Worth doing next:

- Run `./tapwire fcnet0` in one terminal while the VM is up in another. You are now a
  passive tap on the guest's traffic, reading its frames as they go past. That is one
  reason egress control belongs on the host.
- Delete the MASQUERADE rule while the guest is running and retry the fetch. The route is
  still there; the packets go out and cannot come back.
- Give a second VM `172.16.77.3` on the same tap and have them ping each other. They are
  on a LAN that exists only as a file descriptor.

---

## What You Just Learned

1. **A tap device is a wire whose far end is a file descriptor.** `open`, `ioctl`, and the
   kernel believes it has a NIC. This is what every VM, container network and VPN is built
   on.

2. **The kernel can configure the guest's address before userspace exists.** `ip=` on the
   command line, handled by `CONFIG_IP_PNP`, which is how a machine with a 180-line
   initramfs comes up on a network.

3. **Everything above the tap is ordinary routing.** Forwarding, MASQUERADE, FORWARD
   rules — identical to what a home router does, because it is the same thing.

4. **Connecting a sandbox should not privilege it.** Root was needed to build the plumbing,
   on the host, once. The machine itself gained a network without gaining a single
   capability.

---

## Going Deeper

- **Rate limiting.** `/network-interfaces` accepts `rx_rate_limiter` and
  `tx_rate_limiter`. On a host full of tenants, an unmetered guest is a denial of service
  waiting to happen.
- **Egress control.** Everything the guest sends crosses a tap you own. Filtering there —
  by destination, by protocol, by rate — is how a sandbox platform stops agent-generated
  code from reaching what it should not.
- **`packages/client-proxy`** in [`e2b-dev/runtime`](https://github.com/e2b-dev/runtime) is
  the production form of the other direction: routing traffic from outside *into* the right
  sandbox.
- **Networking without root.** `passt` and `slirp4netns` implement a userspace TCP/IP stack
  so an unprivileged process can provide connectivity without touching the host's network.
  Slower, and much harder to get wrong.

---

**Next:** [s08 — Now hand it to an agent](../s08_sdk_and_agent/)
Every piece exists. The last chapter is a Python SDK and a coding agent that lives on it.
