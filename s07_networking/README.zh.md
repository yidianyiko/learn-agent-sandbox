# s07：让它连上互联网

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/README.zh.md) → ... → [s05](../s05_fork_parallel/README.zh.md) → [s06](../s06_in_vm_agent/README.zh.md) → **s07** → [s08](../s08_sdk_and_agent/README.zh.md)

> **需要：** `/dev/kvm`、cargo、C 编译器、已下载的资产——以及 **sudo**，
> 这是整个仓库里第一次也是唯一一次。
> **耗时：** 约 30 分钟。

> *「让它连上互联网。」*

---

## The Problem

[s06](../s06_in_vm_agent/README.zh.md) 把一个人放进了机器里，并给了你一条通往他的通道——
**一条完全不需要网络的通道**。那正是重点：一个你能指挥、却不必暴露出去的沙箱。

但一个能执行命令、却装不了 `pip install` 的 agent，算不上什么 agent。
**机器总得在某一刻伸手出去。**

---

## Part 1 · 一个网络接口，就是一个文件描述符

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

**tap 设备**是一个内核完全当真的以太网接口——你给它配地址、往它路由、ping 它都行——
**只不过它的另一端不是铜线，而是一个打开的文件**。谁持有那个描述符，谁就是"网络的其余部分"。

创建它只要三行：

```c
int fd = open("/dev/net/tun", O_RDWR);
struct ifreq ifr = { .ifr_flags = IFF_TAP | IFF_NO_PI };
strncpy(ifr.ifr_name, "fcnet0", IFNAMSIZ - 1);
ioctl(fd, TUNSETIFF, &ifr);
```

- **`IFF_TAP`** —— 收发**以太网帧**。（`IFF_TUN` 给的是裸 IP 包，高一层。）
- **`IFF_NO_PI`** —— 每帧前面不加额外头部；线上是什么就给什么。

此后，`read(fd)` 返回内核从 `fcnet0` 发出的每一个帧，`write(fd)` 注入的帧则像是从那个
接口收到的。

上面那三个帧，是宿主在问"谁拥有 172.16.77.2"——**问了三遍没人答，
因为第一幕是一根什么都没接的网线**。

> **这就是虚拟机网络的全部。** Firecracker 持有这样一个描述符，把另一端作为 virtio-net
> 设备交给 guest，**两头都分辨不出这不是一根真网线**。

---

## Part 2 · 把机器插上去

虚拟机把这个 tap 配成自己的网络接口：

```
PUT /network-interfaces/eth0
{"iface_id": "eth0", "host_dev_name": "fcnet0", "guest_mac": "06:00:AC:10:4D:02"}
```

而 guest 的地址由**内核自己**根据一个启动参数配好：

```
ip=172.16.77.2::172.16.77.1:255.255.255.0::eth0:off
   └ 本机      └ 网关       └ 掩码          └ 设备 └ 不自动配置
```

**没有 DHCP，用户态也不用做任何事。** `CONFIG_IP_PNP` 会在启动期间就把 `eth0` 拉起来，
**早于任何用户态程序存在**——当你的 initramfs 里只有一个 180 行的 agent 时，这一点很关键。

```
   PUT /network-interfaces/eth0 -> 204   (host_dev_name fcnet0)
   agent: up, listening on vsock port 1234

   $ ping -c2 172.16.77.1   (the host, across the tap)
     64 bytes from 172.16.77.1: seq=0 ttl=64 time=0.436 ms
     [exit 0]
```

**和第一幕是同一根线。这次有人应答了。**

注意这条命令是**从哪里发出去的**：`vexec` 走 **vsock**，和 [s06](../s06_in_vm_agent/README.zh.md)
一模一样。**控制通路和数据通路是两条独立的通道**——我们在用一条不依赖"正在配置的那个网络"
的链路管理这台机器。**网断了，你照样能问它发生了什么。**

---

## Part 3 · NAT，就是你家里那个路由器

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

**就这些。** guest 是一个 /24 网段上只有一个邻居的主机，宿主替它转发，
`MASQUERADE` 在出去时改写源地址——**和你家玄关那个盒子对你笔记本做的事完全一样**。

这一段和虚拟机毫无关系，**它就是普通的 Linux 路由**，你在那上面会的每一招都适用。

> ⚠️ **ping 不通不等于没网。** 在 WSL2 和很多云环境里，**ICMP 过不了外层 NAT，
> 而 TCP 畅通无阻**。演示把 HTTP 那一项放在前面正是因为这个。
> **用你真正在乎的协议去测连通性。**

---

## 哪一侧需要 root

这是第一个需要 `sudo` 的章节，**值得把"到底为什么需要"说精确**：

| 操作 | 权限 |
|---|---|
| 创建 tap 设备 | **root** —— 需要 `CAP_NET_ADMIN` |
| 给它配地址、拉起来 | **root** |
| 一条 NAT 规则和两条 forward 规则 | **root** |
| 打开一个已存在且属于你的 tap | *不需要* |
| microVM 做的一切 | *不需要* |

`/dev/net/tun` 的权限是 `0666`——**人人可开**。需要特权的是**创建一个接口**，
因为那会改变宿主的网络，而那是一件全局的事。

**于是特权完全落在本来就被信任的那一侧。** 跑着没人审过的代码的那台机器，
**仍然以你的身份运行、没有任何 capability**——这才是值得守住的格局：

> **沙箱不会因为被接上网而变得更有特权。**

---

## Try It

```bash
make && ./demo.sh
```

接下来值得动手的：

- 虚拟机跑着的时候，在另一个终端跑 `./tapwire fcnet0`。**你现在是 guest 流量上的一个
  被动抓包点**，它的每个帧都从你眼前过。**这就是出站管控该放在宿主侧的原因之一。**
- guest 运行中删掉 MASQUERADE 规则，再试一次抓取。**路由还在，包出得去回不来。**
- 在同一个 tap 上再给第二台 VM 配 `172.16.77.3`，让它们互相 ping。
  **它们处在一个只以文件描述符形式存在的局域网上。**

---

## What You Just Learned

1. **tap 设备是一根另一端为文件描述符的网线。** `open` 加一个 `ioctl`，内核就相信自己有网卡。
   **每一个虚拟机、容器网络和 VPN 都建在这上面。**

2. **内核能在用户态存在之前就配好 guest 的地址。** 命令行上的 `ip=`，由 `CONFIG_IP_PNP` 处理
   ——这就是一台只有 180 行 initramfs 的机器如何带着网络起来的。

3. **tap 之上的一切都是普通路由。** 转发、MASQUERADE、FORWARD 规则——**和家用路由器做的
   一模一样，因为本来就是同一件事**。

4. **给沙箱联网，不应该让它获得特权。** root 只用在宿主侧搭管道，一次。
   **机器本身获得了网络，却没有获得任何一个 capability。**

---

## Going Deeper

- **限速。** `/network-interfaces` 接受 `rx_rate_limiter` 和 `tx_rate_limiter`。
  在一台住满租户的宿主上，**一个不限速的 guest 就是一场等着发生的拒绝服务**。
- **出站管控。** guest 发出的一切都要穿过一个**你持有的** tap。
  在那里按目的地、按协议、按速率过滤，**就是沙箱平台阻止 agent 生成的代码乱跑的地方**。
- **[`e2b-dev/runtime`](https://github.com/e2b-dev/runtime) 的 `packages/client-proxy`**
  是反方向的生产形态：把外部流量**路由进**正确的沙箱。
- **不用 root 的网络。** `passt` 和 `slirp4netns` 实现了用户态 TCP/IP 栈，
  **让无特权进程也能提供连通性**，代价是更慢、也更难做对。

---

**下一章：** [s08 — 现在把它交给 agent](../s08_sdk_and_agent/README.zh.md)
每一块零件都齐了。**最后一章是一个 Python SDK，和一个住在它上面的 coding agent。**
