# s01：一个属于它自己的内核

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/README.zh.md) → **s01** → s02 → ... → s07

> **需要：** `/dev/kvm`、x86_64 Linux。不需要 root。见 [`../scripts/check-env.sh`](../scripts/check-env.sh)。
> **耗时：** 约 20 分钟。
> **背景：** 没读过的话先看 [`/dev/kvm` 任务简报](../notes/kvm-device.zh.md)。

> *「一个属于它自己的内核。」*

---

## The Problem

[s00](../s00_shared_kernel/README.zh.md) 是这样收尾的：

> 一个刚出生的容器自称已经运行了好几天，还能把宿主加载的每一个内核模块列出来。
> 它看的不是自己的内核。
>
> **它没有"自己的内核"。**

那就给它一个。

这句话写起来轻松，做起来是个有意思的工作量。一台机器要启动，需要一个内核、一块内存、
一块能找到根文件系统的磁盘，以及某种东西去模拟上述一切所期待的硬件。这一章就是**手动
把这些拼起来**，然后问一句：代价是多少。

---

## The Solution

Firecracker。约 3.5 MB，静态链接，零依赖——而且不太寻常的是：**它不用命令行参数配置。**

你把它启动起来，它就坐在那儿什么也不干，只监听一个 unix socket。然后你发四个 HTTP 请求：

```
   PUT /boot-source     这是内核，这是要告诉它的话
   PUT /drives/rootfs    这是磁盘
   PUT /machine-config   给这么多 CPU 和内存
   PUT /actions          开始
```

第四个请求会一路走到 `KVM_RUN`，一个物理核心开始执行 guest 的指令。

### 为什么是 API 而不是参数

这看起来像多余的仪式，直到你考虑沙箱的**生命周期**。虚拟机不是配一次就完事的——你之后
会想挂载新磁盘、打快照、暂停、恢复、分叉。这些都需要一个**启动之后仍然开着的通道**。
Firecracker 索性把这个通道当成唯一接口，不提供第二种做事方式。

这个选择后面还会兑现两次：API 有正式规范（发布包里的 `firecracker_spec-v1.17.0.yaml`
是一份 OpenAPI 文档），而 [s03](../) 里你写的编排器，驱动的就是这些端点、这个 socket。

---

## How It Works

### 四个请求

```bash
# 1. 内核，以及它的命令行
curl --unix-socket "$SOCK" -X PUT http://localhost/boot-source \
  -H 'Content-Type: application/json' -d '{
    "kernel_image_path": "../assets/vmlinux-6.1.186",
    "boot_args": "console=ttyS0 reboot=k panic=1"
  }'

# 2. 根文件系统 —— 只读，原样使用
curl --unix-socket "$SOCK" -X PUT http://localhost/drives/rootfs \
  -H 'Content-Type: application/json' -d '{
    "drive_id": "rootfs",
    "path_on_host": "../assets/ubuntu-24.04.squashfs",
    "is_root_device": true,
    "is_read_only": true
  }'

# 3. 给多大一台机器
curl --unix-socket "$SOCK" -X PUT http://localhost/machine-config \
  -H 'Content-Type: application/json' -d '{"vcpu_count": 1, "mem_size_mib": 256}'

# 4. 开始
curl --unix-socket "$SOCK" -X PUT http://localhost/actions \
  -H 'Content-Type: application/json' -d '{"action_type": "InstanceStart"}'
```

每个都返回 `204 No Content`。整个启动流程就这些。

### 我们先踩了两个坑，你可以直接绕过

**不要自己写 `root=`。** 第一次尝试时我们传的是
`console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda ro`，照着普通内核命令行的样子写。
结果 guest 里看到的是：

```
console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda ro pci=off root=/dev/vda ro virtio_mmio.device=4K@0xc0001000:5
                                                        └─────────── 重复了一份 ───────────┘
```

Firecracker 会自动追加 `pci=off root=/dev/vda ro`，并为每块磁盘补一条
`virtio_mmio.device=`。自己写不会出错，但日后你盯着 `/proc/cmdline` 纳闷"谁说了两遍"
的时候会很困惑。**只传真正属于你的那部分**：一个 console，以及 panic 时怎么办。

**不需要 sudo。** 官方 getting-started 会解开 squashfs、生成 SSH 密钥、`sudo chown`
整棵目录树、再 `sudo mkfs.ext4` 造一个新镜像——因为它想 SSH 进 guest。我们只要一个
console，而 Firecracker CI 桶里每个内核都是 `CONFIG_SQUASHFS=y` 编译的（我们查了随附的
`.config` 文件），所以 rootfs 下载下来就能只读挂载。**整段需要特权的绕路直接消失。**

---

## Try It

```bash
../scripts/fetch-assets.sh   # 约 150 MB，版本和校验值都已钉死
./boot.sh
```

你会落在机器内部的 root 提示符上。用 s00 问容器的那些问题问它：

```
root@ubuntu-fc-uvm:~# uname -r
6.1.186

root@ubuntu-fc-uvm:~# nproc
1

root@ubuntu-fc-uvm:~# free -m | awk 'NR==2{print $2}'
230
```

输入 `reboot` 关机返回。

### 这一章存在的意义，就是下面这张表

| | 容器（s00） | microVM（s01） |
|---|---|---|
| 发行版 vs 宿主 | **不同**（Alpine、Debian） | **相同**（都是 Ubuntu 24.04） |
| `uname -r` vs 宿主 | **完全相同** | **不同** —— `6.1.186` vs `6.18.33.2-microsoft-standard-WSL2` |
| `nproc` | 20 —— 宿主的 | 1 —— 它自己的 |
| 报告的内存 | 60269 MB —— 宿主的 | 230 MB —— 它自己的 |

**s00 是"不同的 userland，共用一个内核"；s01 是"相同的 userland，各有各的内核"。**

注意最后两行：容器看不见自己的限制，是因为**根本没有东西可看**——那个限制是从旁边
拴上去的一个 cgroup。而在这里，**限制就是这台机器本身**。

---

## 时间到底花在哪

```bash
./measure.sh
```

```
Ubuntu 24.04 on squashfs   （boot.sh 跑的就是这个）
  virtio-blk 探测完成         0.358 s
  root 文件系统挂载完成       0.910 s   <- squashfs 解压的开销在这里
  内核交棒给 init            0.927 s
  墙钟：到 shell             2602 ms

BusyBox initramfs, 2 MB     （大致是地板）
  内核交棒给 init            0.533 s
  墙钟：到 shell              688 ms
```

读这个差距：**内核 0.93 秒就干完了，shell 到 2.6 秒才出现。** 将近三分之二的启动时间
是 systemd 在拉起一整套 Ubuntu。换成 2 MB 的 BusyBox initramfs，同一个 hypervisor、
同一个内核，688 毫秒就给你一个 shell。

**虚拟机是便宜的。压在它上面的那套操作系统不是。**

### 关于那个 125 毫秒

Firecracker 的 [NSDI '20 论文](https://www.usenix.org/conference/nsdi20/presentation/agache)
报告的数字大约是 125 毫秒。**你在这里看不到它**，而原因比数字本身更有用：

- 那个测量用的是**裁剪过的内核**，我们用的是全功能 CI 构建
- 它启动的是**最小 init**，不是 systemd
- 它跑在**裸机**上；如果你在 WSL2 或任何嵌套环境里，每一次 VM exit 都要付两遍钱

这一章的早期草稿标题是 *「125 毫秒里的一台虚拟机」*。我们实测 2602 毫秒，**于是改了
标题**——一个印着你复现不出来的数字的教程，等于白白花掉了自己的可信度。


### 换一台机器，结论一样

这一章的 CI 每次 push 都会在 GitHub Actions runner 上启动同一台 VM —— Azure 硬件、
AMD EPYC、不同的内核。并排看：

| | WSL2 笔记本（Intel） | GitHub runner（Azure，AMD） |
|---|---|---|
| Ubuntu 墙钟到 shell | 2602 ms | 2284 ms |
| Ubuntu 内核交棒 init | 0.927 s | 0.852 s |
| initramfs 墙钟到 shell | 688 ms | 569 ms |

不同厂商、不同芯片、相差 12–18%，而且**都远远够不到 125 毫秒**。这才是值得带走的一点：
**这个差距不是你的机器慢**，而是一个完整的内核加一整套用户态在真的干活——每一次启动，
永远如此。

> ⚠️ **嵌套虚拟化下不要相信 guest 内部的计时器。** 那个 BusyBox initramfs 会兴高采烈地
> 宣布 `Boot took 540.30 seconds`。它的时钟基准是错的。**要从宿主侧测。**

这个时间可以往下压——裁内核、去掉 systemd、换更快的文件系统。但**压不到零**，因为内核
每一次都得重新发现一遍自己的硬件。

**[s02](../) 不再尝试压缩它，而是直接从快照恢复。**

---

## What You Just Learned

1. **一台虚拟机 = 四个 HTTP 请求。** 内核、磁盘、尺寸、开始。之所以是 API 而不是命令行
   参数，是因为沙箱真正有意思的操作——快照、暂停、分叉——全都发生在**启动之后**。

2. **这里的隔离是 cgroup 从来给不了的那种真实。** guest 看到 1 个 CPU、230 MB，是因为
   这台机器**真的只有这么多**，而不是因为有谁在过滤它看到的 `/proc`。

3. **启动开销主要在用户态。** 内核 0.93 秒，systemd 1.7 秒。你能想到的所有优化手段，
   都在 hypervisor 之上，而不在它里面。

4. **钉死你的依赖，并且把理由写出来。** Firecracker 自己的指南在运行时解析"最新版"——
   对他们的 CI 是对的，对教程是致命的。我们只解析了一次，然后把答案连同校验值冻结在
   [`../scripts/fetch-assets.sh`](../scripts/fetch-assets.sh) 里。升级它是一个**需要
   重跑所有章节、更新正文里每个数字**的刻意动作。

---

## Going Deeper

- **API 的正式定义。** 发布包里的 `firecracker_spec-v1.17.0.yaml` 是一份 OpenAPI
  文档，涵盖你刚调的所有接口，以及你还没调过的那些。
- **那个 tarball 里还有什么。** `jailer` —— 把 **VMM 自己**关进 chroot + 独立
  namespace + cgroup 的封装，因为 guest 被隔离之后，剩下的攻击面就是 VMM。还有
  `seccomp-filter-v1.17.0.json`，Firecracker 自我约束的系统调用白名单。这两个东西是
  [`/dev/kvm` 简报](../notes/kvm-device.zh.md)里那个论点的实物形态。
- **论文。** [Firecracker: Lightweight Virtualization for Serverless
  Applications](https://www.usenix.org/conference/nsdi20/presentation/agache)，NSDI '20。
  **读它的时机是这一章之后，不是之前**——亲手看过一次启动之后，它会好读得多。

---

**下一章：** s02 — *别启动，恢复。* *（尚未写完）*
