# s03：别启动，恢复。

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/README.zh.md) → [s01](../s01_first_microvm/README.zh.md) → [s02](../s02_write_a_vmm/README.zh.md) → **s03** → s04 → ... → s08

> **需要：** `/dev/kvm`、C 编译器、`make`，以及已下载的资产。
> **耗时：** 约 30 分钟。

> *「别启动，恢复。」*

---

## The Problem

[s01](../s01_first_microvm/README.zh.md) 测了一次启动，发现时间花的地方和直觉不同：
内核 0.93 秒就干完了，shell 却要到 2.6 秒才出现，大头是 systemd。当时说了一句
"这个时间可以往下压，但压不到零"。

这一章解释为什么压不到零。**每一次启动，内核都在重做上一次做过的同一件事：**

```
探测 virtio 总线      找到一块从没挪过位置的磁盘
挂载根文件系统        和上次一模一样的文件系统
启动 systemd          拉起同样的三十来个 unit
到达 shell            2.6 秒之后
```

**这里面没有一件是"发现"，全是在重新推导一批根本没变过的事实。**

那就别推导了。**推导一次，把答案写下来，交给下一台来问的机器。**

---

## The Solution

一个快照，而它只由两样东西构成：

```
guest 的内存      —— s02 证明过，那就是你进程里的一段区域
处理器的状态      —— 几百字节，内核你一问它就给
```

**把这两样存下来，一台虚拟机就变成了文件。** 把它们装进一个新进程，它会从话说到一半的地方继续。

这一章做两遍：**先亲手做一遍**（99 行 C，让你确认中间没有隐藏步骤），**再用 Firecracker
对一个真的 Ubuntu 做一遍**，拿数字。

---

## Part 1 · 亲手做

`tinysnap.c` 给 [s02](../s02_write_a_vmm/README.zh.md) 的 VMM 加了两个操作，而它们
**互为镜像**：

```c
快照 =  write(guest 内存)  +  KVM_GET_REGS  +  KVM_GET_SREGS
恢复 =  read (guest 内存)  +  KVM_SET_REGS  +  KVM_SET_SREGS
```

guest 在数数。打印一个数字、寄存器加一、无限循环：

```
88 d8      mov  al, bl        取出计数器
04 30      add  al, '0'       变成可打印字符
ba f8 03   mov  dx, 0x3f8     串口地址
ee         out  dx, al        打印出去        -> VM exit
fe c3      inc  bl            计数加一
eb f4      jmp  -12           永远循环
```

```bash
$ make
$ ./tinysnap
before snapshot: 01234
snapshot  rip=7  rbx=4
          snapshot.cpu        456 bytes   the processor
          snapshot.mem       4096 bytes   the memory

Now run:  ./tinysnap restore

$ ./tinysnap restore
restored  rip=7  rbx=4  (456 bytes of cpu state)
after  restore: 45678
```

**另一个进程把数数接着数下去了。** 两次运行之间除了两个文件，什么都没共享。

### 承载整个思想的那两行

```c
if (restoring) read_file(MEM_FILE, mem, MEM_SIZE, "memory snapshot");
else           memcpy(mem, guest_code, sizeof guest_code);
```

**"启动"和"恢复"的唯一区别，是这块内存的字节从哪儿来**——一个是程序里的数组，一个是
磁盘上的文件。guest 分辨不出来，因为**从里面看根本没有可分辨的东西**：两种情况下它面对
的都是同一页内存。

这就是恢复更快的全部原因。**启动是让内核推导出它的世界，恢复是把它上次推导好的世界直接
递给它。**

### 为什么 4 被打印了两次

再看一眼：

```
before snapshot: 01234
after  restore:  45678
                 ^ 这个
```

快照记下的是 `rip=7`，而 guest 程序里偏移 7 正是那条 `out` 指令**本身**，不是它的下一条。
**这台机器是在一条指令执行到一半时被拍下来的**：`out` 已经陷出到 VMM，但**从 guest 的角度
它还没执行完**。

于是恢复后 CPU 从 `out` 继续，**重新发了一次**，4 就又出现了一遍。

**这不是玩具的粗糙之处，这就是快照的本义**：它记的不是"程序跑到第几行"，而是"处理器正
处在什么事情的中途"。真实的 VMM 在这件事上投入巨大——飞行中的 I/O、填了一半的设备队列、
即将投递的中断。

---

## Part 2 · 同样两个操作，换成真实规模

```bash
./snapshot.sh
```

```
1 · Cold boot
   Ubuntu reached a shell in 2659 ms

2 · Leave a mark, then snapshot
   PATCH /vm {"state":"Paused"}      -> HTTP 204
   PUT /snapshot/create              -> HTTP 204   (456 ms)
   snapshot.mem              268435456 bytes   the guest RAM
   snapshot.state                12993 bytes   everything else

3 · Restore  (a fresh firecracker — /snapshot/load is pre-boot only)
   PUT /snapshot/load                -> HTTP 204   (16 ms)

4 · Ask it what it remembers
   the guest answered: I-WAS-HERE-BEFORE-THE-SNAPSHOT

The two numbers
   cold boot to a shell   2659 ms
   restore from snapshot  16 ms
   166x faster
```

### API 强制的三件事

**必须先暂停。** `PATCH /vm {"state":"Paused"}` 要在 `PUT /snapshot/create` 之前。
**你没法给一台运动中的机器拍照**——那样会拍到某一瞬间的内存配上另一瞬间的寄存器。

**恢复必须用全新进程。** 规范原文写着 `/snapshot/load` *"只接受全新的 Firecracker 进程"*。
你不是"把快照推进一个运行中的 VMM"，而是**起一个 VMM，让快照成为它的第一条指令**。
其余的一切——内核路径、磁盘、机器配置——都从文件里回来。

**那个标记证明是同一台机器。** 快照之前在 guest 里写的文件，快照之后在**另一个进程**里
读得出来。这就是"恢复"和"重新启动一台长得像的机器"之间的区别。

### 那个不对称才是重点

```
snapshot.mem     268,435,456 字节    恰好是我们配置的 256 MiB
snapshot.state        12,993 字节    寄存器、设备、时钟、中断状态
```

> **一台机器的状态，99.995% 是内存。**
> 那 13 KB 是"它正在干什么"，那 256 MiB 是"它知道的一切"。

我们的玩具在六千分之一的规模上是同一个形状——4,096 字节内存对 456 字节处理器状态。
**同样两个文件，同样的悬殊比例。**

这也解释了造快照为什么要 456 毫秒：那是 256 MiB 以约 600 MB/s 写进磁盘。
**造快照的代价就是写内存的代价。而恢复不是**——下一节讲。

---

## Part 3 · 为什么是 16 毫秒

16 毫秒里读完 256 MiB 需要 16 GB/s。没有磁盘做得到。**所以它根本没在读文件。**

**`mmap` 是惰性的。** 映射一个 256 MiB 的文件，只是建立映射关系，**一个字节都不读**；
页面按需到达——guest 第一次碰哪一页，才加载哪一页。一台刚醒来、打印一行、又暂停的机器，
可能只碰了六万五千页里的几百页。

**你不为没用到的内存付费**——而一台刚恢复的机器，在最初的几毫秒里，几乎什么都没用到。

Firecracker 还能走得更远：API 支持 `mem_backend` 类型为 `Uffd`，把缺页处理交给你自己的
用户态进程（`userfaultfd`）。那个进程可以从**任何地方**取页——另一台机器、对象存储。
**这就是沙箱平台能把几千个快照存在便宜的地方、却仍能在毫秒级恢复其中任意一个的原理。**

### 快照是模板，不是备份

**恢复不消耗文件。** 同一对文件可以一次又一次地装载，每次进入各自的进程，各自成为一台
独立的机器，从恢复那一刻起开始分化。把同一份快照恢复五次，你得到五台**共享同一个起点、
此后毫无关系**的虚拟机——而文件本身一个字节没变。

**备份回答的是「我能回到原来那里吗」。这里的快照回答的是「这一瞬间你想要几份拷贝」。**

**这个问题就是 s05。**

---

## Try It

```bash
make            # 编译 tinysnap
./tinysnap      # 打印 01234，写出两个文件
./tinysnap restore

./snapshot.sh   # 对真实 Ubuntu 做同样的事，带计时
```

接下来值得动手的：

- **把 `./tinysnap restore` 跑两遍。** 两次都从 4 开始——恢复不会推进快照，
  **每次恢复都从同一个瞬间开始**。
- **删掉 `snapshot.mem` 只留 `snapshot.cpu`，然后恢复。** 寄存器说"从 rip=7 接着跑"，
  但那页内存是空的。看看一台机器在它的记忆和它的意识对不上时会怎样。
- **在 `snapshot.sh` 里注释掉 `PATCH /vm {"state":"Paused"}` 那行**，
  看 `/snapshot/create` 会怎么说。

---

## What You Just Learned

1. **快照 = 内存 + 寄存器。** 两个文件，没有第三样东西。机制能塞进 99 行，
   是因为 guest 内存本来就是你拥有的一段区域，而处理器状态一个 ioctl 就能拿到。

2. **恢复不是"快速启动"，它根本不是启动。** 没有任何东西被发现、初始化、拉起。
   **里面的内核永远不会知道时间流逝过。**

3. **造快照的代价是内存带宽，恢复的代价几乎为零。** 写 256 MiB 要 456 毫秒，
   映射回来只要 16 毫秒，因为 `mmap` 在 guest 开口要之前什么都不读。

4. **你在意的那部分状态，是个舍入误差。** 13 KB 的"正在干什么"对 256 MiB 的"知道什么"
   ——这就是为什么这个领域所有的优化，从 diff 快照到 userfaultfd，**针对的全是内存，
   不是寄存器**。

---

## Going Deeper

- **Diff 快照。** `snapshot_type: "Diff"` 配合脏页追踪，只写自上次快照以来变过的页。
  它的 API 就在 `assets/release-v1.17.0-x86_64/firecracker_spec-v1.17.0.yaml` 里，
  和这一章调用的其他接口并排。
- **`userfaultfd`。** `mem_backend: {backend_type: "Uffd"}` 把缺页处理搬进你自己的进程。
  这是"从对象存储恢复"背后的机制。
- **恢复到不同的 CPU 上。** 快照里带着 guest 已经见过的 CPUID 和 MSR 值。落到一台特性
  不同的宿主上，guest 可能会执行一条已经不存在的指令。Firecracker 的 `cpu_config/`
  （6,283 行）和它的 CPU 模板（发布包里的 `T2`、`T2S`、`C3`）就是为此存在的。
- **`snapshot-editor`**，同样在发布包里，可以离线检查和改写快照文件。

---

**下一章：** s04 — *控制面与数据面，永不混合* *（尚未写完）*
一台虚拟机是个演示。当你想要第二台的那一刻，就必须有东西来记账了。
