# s02：自己写一个 hypervisor

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/README.zh.md) → [s01](../s01_first_microvm/README.zh.md) → **s02** → [s03](../s03_snapshot_restore/README.zh.md) → ... → s08

> **需要：** `/dev/kvm`、一个 C 编译器（`gcc` 或 `clang`）、`make`。不需要 root。
> **耗时：** 约 30 分钟。**你不需要会 C**——下面有专门一节。

> *「没有设备。只有一个 switch 语句。」*

---

## The Problem

在 [s01](../s01_first_microvm/README.zh.md) 里你发了四个 HTTP 请求，一台机器就出现了。
这是对**用户行为**的准确描述，但它不是**解释**。

[`/dev/kvm` 简报](../notes/kvm-device.zh.md)声称 `KVM_RUN` 会把物理 CPU 切进 guest 模式、
执行你提供的指令。你是**被告知**的。你没有亲手做过。

所以这一章里没有 Firecracker。**我们自己写那个 hypervisor。**

---

## The Solution

`tinyvmm.c` —— **79 行代码**，除了 libc 不依赖任何库。它创建一台虚拟机，给它一页内存和
一个 CPU，装进 12 字节机器码，跑起来，然后打印 guest 产出的东西。

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

那个 `5` 是**你的物理 CPU 算出来的**——它执行了 guest 的指令，而且处在一个看不见你内存的
模式里。宿主在启动前把 `2` 和 `3` 写进寄存器，guest 把它们相加，宿主事后又把答案读了回来。

---

## 读懂这段 C 需要知道的五件事

这一章**不要求你会写 C**。你只需要读懂 79 行，而其中几乎每一行都是下面五种形状之一。

**1 · 文件描述符就是一个代表"某个已打开的东西"的小整数**

```c
int kvm = open("/dev/kvm", O_RDWR);
```

`kvm` 现在是（比如）`3`。之后每次调用都把这个数字传进去，用来说明**你指的是哪个**已打开的
东西。**把它当成一个句柄，而不是一个值。**

**2 · `ioctl` 的意思是"对这个句柄做一件它支持的事"**

```c
ioctl(kvm, KVM_CREATE_VM, 0);
```

`read()` 和 `write()` 只负责搬字节。一个设备能做的其他所有事——"创建一台虚拟机"、
"设置这些寄存器"、"跑起来"——**全部走 `ioctl(句柄, 哪个操作, 参数)`**。
整套 KVM API 就是这一个函数配不同的常量。

**3 · `struct` 是一组有名字的字段，`.字段 = 值` 填其中一个**

```c
struct kvm_regs regs = {
    .rip = 0,
    .rax = 2,
};
```

**没提到的字段自动为零。** 这些 struct 定义在 `<linux/kvm.h>` 里，是内核期待的**精确内存
布局**——这也是为什么即使调用方是 Rust，这个接口本质上仍是个 C 接口。

**4 · `mmap` 是向内核要内存，或者要一扇"看向某个东西的窗"**

```c
void *mem = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
```

这里用了两次，目的完全不同。一次是要一页空白内存，**它将成为 guest 的物理内存**。
另一次是要**一扇看向内核结构体的窗**——这样 `KVM_RUN` 返回后，我们能直接读出它为什么停，
不需要任何拷贝。

**5 · 指针加偏移就是一个地址**

```c
(char *)run + run->io.data_offset
```

这是全文唯一看起来费解的一行。`run` 指向那个共享结构体；KVM 告诉我们 guest 写出的那个
字节位于**再往后 `data_offset` 个字节**的位置。所以：从 `run` 出发，往前走那么多字节，
从那里读。

**整套词汇就这些。** 剩下的全是 `printf`。

---

## How It Works

六步，和文件里的注释一一对应。

### 1 · 开门

```c
int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
ioctl(kvm, KVM_GET_API_VERSION, 0);     // -> 12
```

版本 12 从 2007 年至今没变过。之所以要检查，是因为这个 ABI **承诺**在这个数字上保持稳定，
如果读到别的数，说明你身处一个非常奇怪的地方。

### 2 · 要一台机器

```c
int vm = ioctl(kvm, KVM_CREATE_VM, 0);
```

它返回**另一个文件描述符**。这个模式一路向下嵌套：`/dev/kvm` 句柄造出 VM 句柄，
VM 句柄造出 vCPU 句柄，每一层接受属于自己的 ioctl。**关掉 VM 句柄，这台机器就没了。**

### 3 · 捐内存

```c
void *mem = mmap(NULL, 0x1000, ...);          // 一页 4 KiB
memcpy(mem, guest_code, sizeof guest_code);

struct kvm_userspace_memory_region region = {
    .guest_phys_addr = 0x1000,                 // 在 guest 眼里它在哪
    .memory_size     = 0x1000,
    .userspace_addr  = (unsigned long)mem,     // 它实际在哪
};
ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region);
```

> **guest 的"物理内存"，就是 VMM 自己虚拟内存里的一段。**

这句话值得重读一遍。没有特殊分配，没有预留硬件。**你把一段你本来就拥有的地址范围交给内核，
说"guest 眼里它在 0x1000"。**

这就是为什么给一台 microVM 256 MB 在没被真正触碰之前几乎不花钱，也是后面快照和写时复制
分叉能成立的机制基础。

### 4 · 要一个 CPU，并找到信箱

```c
int vcpu     = ioctl(vm, KVM_CREATE_VCPU, 0);
int run_size = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);      // 这台机器上是 12288
struct kvm_run *run = mmap(NULL, run_size, ..., vcpu, 0);
```

`struct kvm_run` 是内核和你**共享**的。guest 一停，内核填好这个结构体然后返回，你直接读。
**不拷贝、不传消息**——因为退出路径每秒要走几百万次，它必须是一次内存读取。

### 5 · 摆好 CPU 的姿势

```c
struct kvm_sregs sregs;
ioctl(vcpu, KVM_GET_SREGS, &sregs);
sregs.cs.base     = 0x1000;    // 代码段指向我们那一页
sregs.cs.selector = 0;
ioctl(vcpu, KVM_SET_SREGS, &sregs);

struct kvm_regs regs = { .rip = 0, .rax = 2, .rbx = 3, .rflags = 0x2 };
ioctl(vcpu, KVM_SET_REGS, &regs);
```

x86 CPU 上电时处在 **16 位实模式**——从 1978 年到现在一直如此——它去一个固定地址取第一条
指令。在真实硬件上，接下来该干什么是由固件安排的。**在这里，你就是固件。**

注意 `rax` 和 `rbx` 发生了什么：guest 没有输入、没有参数、没有文件可读。
**宿主只是在它启动之前写了它的寄存器。** 这就是 VMM 和 guest 之间调用约定的全部。

### 6 · 跑

```c
for (;;) {
    ioctl(vcpu, KVM_RUN, 0);              // 物理 CPU 开始执行 guest 的指令
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

**一切顺利时 `KVM_RUN` 不返回。** 物理核心在全速跑 guest 的代码，内核完全不参与。
它只在 guest 做了某件需要外部介入的事时才返回——这里是一条往端口 `0x3f8` 写的 `out` 指令。

> **guest 以为自己在跟串口说话。没有串口。只有一个 `case` 标签。**

这个程序里发生了三次退出：两条 `out`，一条 `hlt`。**虚拟机有史以来的每一个设备，
都是这个形状。**

---

## Try It

```bash
cd s02_write_a_vmm
make
./tinyvmm
```

接下来值得动手的三件事，按有趣程度递增：

- 改掉 `.rax` 和 `.rbx`，看打印出来的数字跟着变。**你刚刚给一台虚拟机传了参数。**
- 把 `guest_code` 里的端口从 `0x3f8` 改成别的，看那个 `if` 不再匹配。
  **你刚刚拔掉了一个设备。**
- 删掉 `KVM_EXIT_HLT` 那个 case。guest 停机，你的 switch 落进 `default`，
  **你就见到了一个 VMM 遇到它不认识的 guest 行为时是什么样子。**

---

## 那另外的 120,626 行，到底在干什么？

Firecracker v1.17.0 是 **120,626 行 Rust**（不含测试）。你刚写了 79 行就虚拟化了一个 CPU。
这个差距去哪了值得说精确——因为**诚实的答案不是"他们写得啰嗦"**。

以下数字实测自 v1.17.0 源码树：

| | 行数 | 是什么 |
|---|---:|---|
| `vmm/src/devices/` | **40,306** | **设备模拟 —— 占全仓 33%** |
| `vmm/src/arch/` | 12,015 | 启动协议、内存布局、各架构的初始化 |
| `vmm/src/dumbo/` | 6,514 | 一个小型 TCP/IP 栈，给元数据服务用 |
| `vmm/src/vstate/` | **6,333** | **vCPU、VM、内存状态 —— 你刚写的那部分** |
| `vmm/src/cpu_config/` | 6,283 | CPU 特性掩码，让快照能在不同型号的宿主上恢复 |
| `vmm/src/device_manager/` | 4,293 | 把设备接到总线和中断上 |
| `vmm/src/mmds/` | 2,776 | 实例元数据服务 |
| `vmm/src/io_uring/` | 2,773 | 异步磁盘 I/O |
| `vmm/src/rate_limiter/` | 1,400 | 每设备限流——因为多租户共享硬件 |
| `jailer/` | 3,170 | 把 VMM 自己关进 chroot 和独立 namespace |
| `seccompiler/` | 634 | 编译 VMM 自我约束用的系统调用白名单 |

而 `devices/` 内部：

| | 行数 |
|---|---:|
| `virtio/vsock/` | 6,937 |
| `virtio/block/` | 6,625 |
| `virtio/net/` | 5,174 |
| `virtio/transport/` | 4,544 |
| `virtio/balloon/` | 3,020 |
| `legacy/serial.rs` | **592** |

**最后一行是最值得坐下来想一想的。**

> **你那三行 `case KVM_EXIT_IO`，就是 `serial.rs`。而 `serial.rs` 有 592 行。**

差距不在聪明程度。而在于：一个真实的 16550 UART 有发送缓冲、接收缓冲、中断使能寄存器、
线路状态寄存器、调制解调器控制寄存器、流控——而 guest 会去读这些寄存器，并**根据读到的
内容改变行为**。你那版只处理了 Linux 打印一个字符时恰好走的那一条路径。
他们那版处理的是**硬件真正承诺过的全部**，因为 guest 内核有权依赖其中任何一条。

把这个乘以一台机器需要的每一个设备。然后再加上：

- **Linux 启动协议** —— `arch/` 存在，是因为当载荷是一个内核时，你不能只设个 `rip` 就走。
  你要填 setup header、合成 e820 内存映射、构造 zero page、准备 CPUID 各叶。
- **快照与恢复** —— `vstate/` 的大部分和 `cpu_config/` 的全部，都是在解决"抓取一台机器的
  状态并把它放回去，而且可能是放回一个不同型号的 CPU 上"。**那就是 s03。**
- **在敌意代码于内部运行时保持安全** —— `jailer/`、`seccompiler/`、限流器之所以存在，
  是因为 Firecracker 的威胁模型假定 **guest 就是攻击者**，而 VMM 是它与宿主之间最后一道东西。

**这些没有一样是"虚拟化"。** 虚拟化在你那个文件的第 60 行就已经做完了。
**上面这一切都是设备模拟、硬件兼容性，以及不被攻破。**

> 你的 79 行 : `vstate/` 的 6,333 行 : 整个 VMM 的 120,626 行
> 比例大约是 **1 : 80 : 1,500**。而那个 1,500，
> **就是把一个能跑通的想法，变成一个你敢让陌生人在里面执行代码的东西所需的代价。**

这也是这个仓库不去重写 Firecracker 的诚实理由。不是因为它难——虽然确实难。
而是因为那十二万行是**工程量**——必要的、有技术含量的、不出彩的工程量——
**而那个想法，你已经学会了。**

---

## What You Just Learned

1. **虚拟化本身很小。** 开一个设备、要一台 VM、捐一段内存、要一个 CPU、设好寄存器、
   在 `KVM_RUN` 上循环。六步，79 行，零依赖。

2. **设备模拟就是一个 switch 语句。** 每一个虚拟串口、磁盘、网卡，都是某人退出循环里的
   一个 `case`。**硬件不存在，存在的是那份"契约"**，而 VMM 负责守约。

3. **guest 的内存就是你的内存。** `KVM_SET_USER_MEMORY_REGION` 交给 guest 的是 VMM 自己
   地址空间的一段。**记住这一条，s03 要用**——这就是为什么快照是一个文件、分叉很便宜。

4. **难的不是那个想法。** Firecracker 有 33% 在"扮演硬件扮演得足够像，以至于一个真实的
   内核被骗过去"，而剩下相当一部分在"干这事的同时不被攻破"。
   **活儿都在那里，这也是为什么用他们的实现才是对的选择。**

---

## Going Deeper

- **Linux 源码里的 `Documentation/virt/kvm/api.rst`** —— 这里用到的每个 ioctl，
  以及没用到的那几百个，的权威参考。
- **[`kvm-ioctls`](https://github.com/rust-vmm/kvm-ioctls)** —— 封装了这些调用的 Rust
  crate，而且**正是 Firecracker 用的那个**。写完 `tinyvmm.c` 之后再读它会异常轻松，
  因为你知道每个函数是干什么的。
- **[`rust-vmm`](https://github.com/rust-vmm)** —— Firecracker、Cloud Hypervisor、crosvm
  共用的那一套 crate。你刚跳过的设备模拟，占了它的大部分。
- **Firecracker 源码树里的 `src/vmm/src/devices/legacy/serial.rs`**，592 行。
  把它和你那三行 `case` 并排读。**这是"一个演示"和"一个产品"之间差距最清晰的一张图。**

---

**下一章：** [s03 — 别启动，恢复。](../s03_snapshot_restore/README.zh.md)
你 guest 的内存，是你自己拥有的一段区域。那么——**如果把它写进一个文件会怎样？**
