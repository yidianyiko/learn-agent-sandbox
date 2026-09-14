# s06：里面得有个人

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/README.zh.md) → [s01](../s01_first_microvm/README.zh.md) → [s02](../s02_write_a_vmm/README.zh.md) → [s03](../s03_snapshot_restore/README.zh.md) → [s04](../s04_orchestrator/README.zh.md) → [s05](../s05_fork_parallel/README.zh.md) → **s06** → s07 → s08

> **需要：** `/dev/kvm`、cargo、已下载的资产。不需要 root。
> **耗时：** 约 40 分钟。

> *「里面得有个人。」*

---

## The Problem

六章下来，你能启动机器、冻住它、唤醒它、分叉它、还能维护一份运行中机器的登记表。
**但你还是没法让其中任何一台做任何事。**

串口控制台不算答案。**它是一条和内核日志共用的字节流**——没有分帧、没有退出码、
没法判断一条命令的输出在哪里结束。人眯着眼看还行，**程序完全没法用**。

缺两样东西，而且两样都不显然：

```
通道    在一台没有网络的机器上，宿主怎么够到 guest 里的程序？

乘客    在一台磁盘只读、从没联过网的机器里，程序怎么进去？
```

---

## Part 1 · 乘客：initramfs 就是一个 cpio 归档

**initramfs 不是文件系统镜像。** 它是一个**归档**，内核在任何文件系统驱动或块设备参与
之前，**把它解开到一个 tmpfs 里**，然后执行其中的 `/init`。

这正是它能把你的程序送进一台一无所有的机器的原因：**它在机器拥有任何东西之前就能工作。**

格式是 1977 年的 `newc` cpio，`mkinitramfs.rs` 用大约四十行就写出来了：

```
[110 字节头][文件名][数据]  [头][文件名][数据]  ...  [TRAILER!!!]
```

**每个头字段都是 ASCII 十六进制**——所以 hexdump 里 `070701` 是**字符**而不是字节。
**没有字节序问题**：同一个归档在 x86 和 ARM 上解析结果完全一致。1977 年这么设计是为了
可移植，今天仍在还本。

内核选它而不选别的，理由只有一个：**解包代码必须住在内核里、在一切之前运行**，
所以解析器必须极小且能流式处理。`zip` 的索引在文件末尾，需要 seek；`tar` 有好几种
互不兼容的方言；**`cpio newc` 是一串定长头，几百行 C 就能读**。

我们的归档里只有两个文件：

```
init          我们的 agent，内核会把它当 PID 1 运行
bin/busybox   一个静态 shell，好让 agent 有东西可以用来执行命令
```

### PID 1 不能退出

这一章早期的二进制打印一行就从 `main` 返回了，结果是：

```
[    0.531518] Run /init as init process
hello from a static binary
[    0.533278] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

**退出码是零。** 内核不在乎 init 是不是成功了——**PID 1 一消失，系统就没有 init 了，
于是 panic**。所以 `main.rs` 底部有个 `park()`：agent 在无法服务时**原地坐着而不是退出**，
因为退出会毁掉整台机器，连同现场证据。

### BusyBox 靠 `argv[0]` 决定运行哪个命令

第一个能跑的版本只能执行 shell 内建命令：

```
$ echo $((6*7))     ->  42
$ uname -a          ->  sh: uname: not found
```

**BusyBox 是四百个命令打包成的一个二进制**，它靠"被以什么名字调用"来决定你要哪一个——
**和 `/usr/bin/sg` 其实是 `newgrp` 是同一个把戏**。只有 `/bin/busybox` 一个文件时，
shell 去找 `uname` 什么也找不到。

`busybox --install -s` 会给每个 applet 建符号链接。但**它按各自的规范路径安装**：
`ls` 装到 `/bin`，`head` 要去 `/usr/bin`——而那个目录不存在时，**一半的链接会静默失败**。
所以 agent 在调用它之前先建好 `/usr/bin`、`/usr/sbin`、`/sbin`。

---

## Part 2 · 通道：vsock

```rust
#[repr(C)]
struct SockAddrVm {
    svm_family: u16,
    svm_reserved1: u16,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [u8; 4],
}
```

**十六个字节，这就是 vsock 寻址的全部。** 一个**上下文 ID（CID）**和一个**端口**。
没有网卡、没有 IP 地址、没有路由表、没有 DNS、没有 ARP。
**guest 在任何意义上都没有网络，而且不需要**——字节由 hypervisor 搬运。

这件事比听起来重要：**一个必须联网才能被控制的沙箱，就必须给它的网络做安全**；
**一个用 vsock 触达的沙箱可以完全没有网络，却照样听命令。**

### Firecracker 加的那层握手

Firecracker **不会直接把 `AF_VSOCK` socket 交给宿主**。它把设备代理到宿主上的一个
Unix socket，并规定了自己的两行协议：

```
宿主:  连接 uds_path
宿主:  发送  "CONNECT 1234\n"
宿主:  读到  "OK <宿主侧端口>\n"     <- 没人监听的话，连接直接被关掉
```

**过了这一行，这个 socket 就直通 guest 里那个 `accept()` 出来的连接。**

注意这对两边代码的影响：**guest 侧的 agent 需要裸系统调用**——`socket`/`bind`/`listen`/
`accept` 打 `AF_VSOCK`，而 Rust 的 std 没有这个。**宿主侧一样都不需要**，因为 Unix socket
足够普通，`UnixStream` 就在 std 里。

> **一边是系统编程，另一边是一个下午的活。**

---

## Part 3 · agent

```bash
make && ./demo.sh
```

```
1 · Build the agent
   agent          1169824 bytes   runs as PID 1 inside the guest
   vexec          1173760 bytes   runs here

2 · Pack it into an initramfs  (a cpio archive, nothing more)
   init             1169824 bytes
   bin/busybox      1131168 bytes
   initramfs.cpio   2301472 bytes total

3 · Boot it, with a vsock device
   PUT /vsock           -> 204   (guest_cid 3, proxied through v.sock)
   guest says: agent: up, listening on vsock port 1234

4 · Run commands in it
   $ uname -a
     Linux (none) 6.1.186 #1 SMP PREEMPT_DYNAMIC x86_64 GNU/Linux
     [exit 0]
   $ free -m | head -2
                   total        used        free      shared  buff/cache   available
     Mem:            230          14         212           3           4         209
     [exit 0]
   $ ls /usr/bin | wc -l
     177
     [exit 0]
```

agent 约 180 行 Rust，**零依赖**。它需要内核做的每一件事都是手写声明的：

```rust
extern "C" {
    fn socket(domain: i32, ty: i32, protocol: i32) -> i32;
    fn bind(fd: i32, addr: *const SockAddrVm, len: u32) -> i32;
    fn fork() -> i32;
    fn execv(path: *const i8, argv: *const *const i8) -> i32;
    ...
}
```

std 本来就链接了 libc，**所以这些声明只是给已经存在的符号起个名**。手写它们既让这个 crate
保持零依赖，**又把这个程序发出的每一次内核调用集中列在一处**——后者才是更有价值的那一半。

执行命令的过程是：`fork`，然后 **`dup2` 把 socket 接到子进程的 stdout 和 stderr 上**，
再 `execv` BusyBox。调用方能实时看到输出，**因为调用方的 socket 就是子进程的 stdout**。

---

## Try It

```bash
../scripts/fetch-assets.sh
make && ./demo.sh

# 或者手动驱动
./target/release/vexec /tmp/.../v.sock 1234 'cat /proc/meminfo'
```

接下来值得动手的：

- **删掉 `install_busybox()` 调用**，看哪些命令还能用。**活下来的都是 shell 内建**，
  其余全是符号链接给的。
- **把错误路径上的 `park()` 改成让 `main` 返回**，然后在不挂 vsock 设备的情况下启动。
  内核对此的意见来得很快。
- **给协议加第二条命令**——比如写文件——然后你会发现**你已经在设计一套 API 了**，
  而那正是 `envd` 这种东西的本体。

---

## What You Just Learned

1. **initramfs 就是一个 cpio 归档**，而 cpio 是一串 ASCII 十六进制的定长头。
   四十行 Rust 就能写出来。**这就是"把程序送进一台没网络、磁盘只读的机器"的全部办法。**

2. **PID 1 不能退出**，退出码为零也不行。内核会 panic，**因为没有 init 的系统不是系统**。

3. **vsock 是"没有网络的寻址"**——一个 CID 加一个端口，十六个字节。
   **能这样触达的沙箱可以完全没有网卡**，于是一整类需要加固的东西直接消失了。

4. **在里面比在外面难。** guest 侧是裸系统调用，因为没有哪家标准库覆盖 `AF_VSOCK`；
   宿主侧是 `UnixStream`，一个 `unsafe` 都不需要。
   **这个不对称，在决定"什么跑在哪边"时值得记住。**

---

## Going Deeper

- **E2B 的 `envd` 是 Go，不是 Rust。** 我们这里选 Rust 是为了极小的静态二进制，
  也因为 [s02](../s02_write_a_vmm/README.zh.md) 刻意把 Rust 放在这一层；
  生产环境的答案 `packages/envd` 选了另一条路。**两边都不错，去读读他们的，看看换来了什么。**
- **`vsock_loopback`。** 现代内核提供 CID 1 用于宿主本地 vsock，
  **让你不用虚拟机就能测试 AF_VSOCK 程序**。
- **Firecracker 的 `docs/vsock.md`** 还记录了 guest 主动发起的方向：宿主在
  `uds_path_PORT` 上监听，guest 连 CID 2。**要推送事件而不是拉取答案，就走那条路。**
- **一个真实的 agent 会长成什么样。** 文件系统操作、stdin 流式输入、进程生命周期、
  端口转发、文件监听。**每一样都是你刚起头的那个协议上的又一个动词。**

---

**下一章：** s07 — *让它连上互联网* *（尚未写完）*
机器已经能听命令了。**但它还装不了 `pip install`。**
