# s00：你的容器不是沙箱

[English](README.md) · [中文](README.zh.md)

**s00** → [s01](../s01_first_microvm/README.zh.md) → s02 → ... → s07

> **需要：** 只要 Docker。不需要 KVM，不需要 root。
> **耗时：** 约 10 分钟。

> *「你的容器不是沙箱。」*

---

## The Problem

你在做一个 agent。它写了一段 Python，你得把它跑起来。

你顺手拿了 Docker——因为所有人都这么干。镜像用完即弃、文件系统是隔离的、内存还能限死。
这**看上去**确实像个盒子。

在把 agent 生成的代码丢进这个盒子之前，有个很朴素的问题值得先问清楚：

**那段代码和你的机器之间，到底隔着什么？**

这一章不靠讲道理回答它，靠测。

---

## The Solution

四个只读实验。每个都是一条 `docker run`，让容器回答一个关于它自己的问题，然后和宿主的
答案对照。不挂载任何东西，不修改任何东西。

```
  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
  │    容器     │  │    容器     │  │    宿主     │
  │   Alpine    │  │   Debian    │  │   Ubuntu    │
  │ musl/busybox│  │    glibc    │  │    glibc    │
  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
         │                │                │
         └────────────────┼────────────────┘
                          ▼
                 ┌──────────────────┐
                 │   同一个内核     │   ← 我们即将证明的东西
                 └──────────────────┘
```

---

## How It Works

### 1 · 三个发行版，一个内核

Alpine 用的是 musl libc + BusyBox，Debian 用的是 glibc + GNU coreutils，两者的 userland
几乎没有任何共享代码。分别问它们跑在什么内核上：

```
Alpine Linux 3.20          6.18.33.2-microsoft-standard-WSL2
Debian 12                  6.18.33.2-microsoft-standard-WSL2
宿主 (Ubuntu 24.04)        6.18.33.2-microsoft-standard-WSL2
```

一模一样——连 `microsoft-standard-WSL2` 这个后缀都一样，而 Alpine 显然从没发布过这种内核。
**那个字符串属于宿主。**

原因是一个很少被明说的事实：

> **一个 Linux 发行版 = userland 文件 + 一个内核。而容器镜像里根本不含内核。**
> Docker 换掉的是文件，不是执行引擎。

*（你机器上的内核字符串会和上面不同——重点是你那三行会互相一致。）*

### 2 · 容器看不见自己的限制

给容器一个 128 MB 的硬上限，然后问它有多少内存：

```
我们施加的限制 (cgroup)        128 MB
cgroup 文件里写的              128 MB     <- 限制是真的在执行
`free` 报告的                60269 MB     <- 应用程序看到的
宿主的真实内存               60268 MB
nproc 报告的 CPU 数              20       （宿主就是 20）
```

`free` 读的是 `/proc/meminfo`，而这个文件**没有被 namespace 化**。cgroup 会**强制执行**
限制——超了就杀你——但它**不虚拟化视图**。

这不是冷知识。JVM、Node、Go 的运行时历史上就是按宿主内存去定堆大小和线程池，结果远超
cgroup 限制，被 OOMKilled，日志里什么都没有，只有一个退出码 137。
`-XX:+UseContainerSupport` 这个参数的存在意义就是绕过 `/proc`，直接去读 cgroup 文件。

### 3 · 你读到的是宿主内核的内部状态

```
容器内报告的 uptime        321188.81 秒   <- 它几毫秒前才启动
宿主的 uptime              321189.05 秒
容器内能看到的内核模块数          208
宿主已加载的内核模块数            208
```

一个刚出生的容器自称已经运行了好几天，还能把宿主加载的每一个内核模块列出来。
它看的不是自己的内核。

**它没有"自己的内核"。**

### 4 · 配错一个参数，这堵墙有多薄

```
普通容器的设备节点数          15
--privileged 的设备节点数    181
宿主的设备节点数             191
被暴露出来的宿主块设备       sda sdb sdc sdd
```

一个参数，宿主的裸盘就在容器内可寻址了。我们只是把它们列了出来——但一个能寻址块设备的
进程，就能读那块盘上的文件系统，不管容器自己挂载了什么。

---

## Try It

```bash
cd s00_shared_kernel
./demo.sh
```

会拉两个钉死版本的镜像（`alpine:3.20`、`debian:12-slim`），跑四个容器，不写任何东西。
镜像有缓存的话一分钟内跑完。

> **注意那两个钉死的 tag。** 不写 tag 的 `alpine` 会解析成 `alpine:latest`，而它是会变的。
> 一个输出对不上正文的教程比没有教程更糟——所以这个仓库里每个镜像都带显式 tag。

---

## What You Just Learned

1. **容器镜像里没有内核。** namespace 改变了进程能**看到**什么，cgroup 改变了它能
   **用**多少，**但两者都没改变它的系统调用去往哪里**。

2. **安全边界在系统调用接口上**——三百多个入口，通往你宿主和所有容器共用的那一个内核。
   内核的提权漏洞按定义就是容器逃逸，而这种漏洞每年都会出几个。

3. **对你自己写的、审过的代码，这个取舍完全合理。** 但当代码是几秒钟前生成的、没有任何人
   看过一眼时，它就不再合理了。**隔离没有变弱，变的是你往里面塞的东西。**

---

## Going Deeper

- **中间地带。** [gVisor](https://gvisor.dev) 用用户态内核拦截系统调用；
  [Kata Containers](https://katacontainers.io) 保留容器接口但在底下塞了一台虚拟机。
  这两个东西存在的理由，就是上面测出来的这个缺口。
- **`/proc` 为什么说谎。** [lxcfs](https://github.com/lxc/lxcfs) 是常见的绕法：
  用 FUSE 给容器提供一份 cgroup 感知的 `/proc/meminfo`。
- **一道真正的边界要付出什么代价。** Firecracker 的论文
  [*Lightweight Virtualization for Serverless Applications*](https://www.usenix.org/conference/nsdi20/presentation/agache)
  （NSDI '20）——同一个问题，用「给每个工作负载一个自己的内核」来解。

---

**下一章：** [s01 — 一个属于它自己的内核](../s01_first_microvm/README.zh.md)。
一台拥有自己内核的机器，由你亲手启动。

出发前：[`/dev/kvm` 任务简报](../notes/kvm-device.zh.md)——从这一章起每一章都依赖这个设备。
