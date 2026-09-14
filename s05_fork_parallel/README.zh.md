# s05：fork 机器，而不是 fork 进程

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/README.zh.md) → [s01](../s01_first_microvm/README.zh.md) → [s02](../s02_write_a_vmm/README.zh.md) → [s03](../s03_snapshot_restore/README.zh.md) → [s04](../s04_orchestrator/README.zh.md) → **s05** → s06 → s07 → s08

> **需要：** `/dev/kvm`、C 编译器、`make`、已下载的资产，以及一个 s03 的快照
> （`cd ../s03_snapshot_restore && make && ./tinysnap`）。
> **耗时：** 约 30 分钟。

> *「fork 机器，而不是 fork 进程。」*

---

## The Problem

[s03](../s03_snapshot_restore/README.zh.md) 结尾抛了一个没有验证的断言：**恢复不消耗
快照**，所以同一对文件可以被反复装载。

**那才是有意思的那一半。** 如果快照是一个**分叉点**而不是备份，问题就不再是"恢复一台
能多快"，而变成：

> **第六台要花多少钱？**

如果每次恢复都是实打实的 256 MiB，那十个沙箱就是 2.5 GB，这个想法在笔记本上当场夭折。
**如果它们能共享没改动过的部分**，十个沙箱的成本就只比一个多一点点——而一整类用法就此打开。

---

## Part 1 · 一个标志位

```bash
make && ./tinyfork
```

```
one snapshot, 4 machines

   fork 2   resumes at 2   prints 43456   wrote 0xA2 to its own page
   fork 3   resumes at 3   prints 44567   wrote 0xA3 to its own page
   fork 4   resumes at 4   prints 45678   wrote 0xA4 to its own page
   fork 1   resumes at 1   prints 42345   wrote 0xA1 to its own page

snapshot.mem, byte 100:  before 0x00   after 0x00   unchanged
   every machine wrote there. None of them reached the file.
```

四台机器，各自带着自己的计数器从 [s03](../s03_snapshot_restore/README.zh.md) 的快照恢复，
**四台都往 guest 内存的同一个地址写了字节**——而它们共同的来源文件，一个字节都没变。

**整个机制就是一次调用上的一个标志位：**

```c
void *mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE, memfd, 0);
```

`MAP_PRIVATE` 映射一个文件的含义是：**读，走的是所有人共用的那份页缓存；对某一页的第一次
写，会悄悄给你一份属于你自己的副本。**

内核的写时复制机制已经存在几十年了——**让 `fork()` 变便宜的就是它**——这里只是把它指向了
一台虚拟机的内存。

于是四台机器共享所有没碰过的页，而它们被切出来的那个快照，**谁也改不了**。
没有人需要去实现"共享"、"引用计数"或"差分"。**就是一个词。**

> 每一行输出都以 `4` 开头，是 [s03](../s03_snapshot_restore/README.zh.md) 那个 `rip=7`
> 的后果：快照拍在 `out` 指令执行到一半时，所以每台机器恢复后都会先把那个飞行中的 I/O
> 重发一遍，然后才按自己的计数器往下走。**它们连一个没做完的动作都一起继承了。**

### `fork()` 会给你下的两个绊子

这个程序两个都踩到了，注释里写明了：

```c
fflush(stdout);              /* fork 之前 */
```

**`fork()` 会把父进程的 stdio 缓冲区一起复制。** 已经 `printf` 但还没刷出去的内容，
会被复制进每一个子进程，并在它们各自退出时再打印一遍。四个子进程，一行横幅，打印五遍。

```c
write(STDOUT_FILENO, line, len);   /* 不是 printf */
```

**四个进程往同一个终端写会交错。** 先把整行拼好，再用一次 `write` 发出去，才能保证每行完整。

---

## Part 2 · 同样的事，换成真机器

```bash
./fork.sh
```

启动一台 Ubuntu、给它拍快照，然后恢复六次：

```
1 · Boot one Ubuntu and snapshot it
   snapshot: 256 MiB of memory, 12987 bytes of state

2 · Restore it 6 times

   #    restore      sum of RSS     system memory used
   1    21 ms        19 MB          8 MB
   2    21 ms        40 MB          49 MB
   3    20 ms        62 MB          57 MB
   4    29 ms        83 MB          66 MB
   5    19 ms        104 MB         69 MB
   6    19 ms        135 MB         76 MB

   if nothing were shared: 6 x 256 MiB = 1536 MB

3 · Give each one a different future
   fork 1 sees: BASE-IMAGE fork-1
   fork 2 sees: BASE-IMAGE fork-2
   ...
   fork 6 sees: BASE-IMAGE fork-6
```

**看右边两列。** 六台机器，每台都认为自己有 256 MiB，**加起来只占了系统 76 MB**，
而不是 1536 MB。

**再看最左边那列：第六次恢复和第一次一样快。** 因为没有任何东西是按台复制的，
所以机器越堆越多也不会变慢。

### 共享过去，各自的未来

`BASE-IMAGE` 是在快照之前写进 guest 的——**在这六台机器中任何一台存在之前**。
六台都记得它，因为**六台就是那一台**。

`fork-N` 是它们恢复之后各自写的。每台只看得见自己那个，因为**从恢复的那一瞬间起，
它们就是陌生人了**。

这比"这些 VM 是互相隔离的"要强得多：**它们互相隔离，同时又免费地共享了一切共同之处，
不需要任何协调。**

---

## Part 3 · 为什么 agent 需要这个

前面每一章都在朝"一个 agent 能用的沙箱"推进。**这一章改变的是 agent 能做什么。**

一个在环境就绪之后拍下的快照——依赖装好了、仓库克隆了、测试套件热了——**就是一个分叉点**。
从它出发，你能在启动一台的时间里启动十台，让每一台去试不同的东西：

```
              ┌─ fork 1 ── 试试加空值检查 ──── 测试失败
              │
  快照    ────┼─ fork 2 ── 试试提前返回 ───── 测试通过
 (环境就绪)   │
              ├─ fork 3 ── 试试改类型 ─────── 测试失败
              │
              └─ fork 4 ── 回滚重来 ───────── 测试通过
```

**没有 fork，这就是四次串行启动加四次串行准备。有了它，准备只发生一次**，
而那四次尝试是唯一要花钱的部分。

这也正是"在真实环境上做强化学习"的形状——**从一个 checkpoint 展开 N 条轨迹**——
所以同一个原语会同时出现在 agent 平台和训练基础设施里。

---

## Try It

```bash
cd ../s03_snapshot_restore && make && ./tinysnap && cd -
make && ./tinyfork
./fork.sh
FORKS=12 ./fork.sh
```

接下来值得动手的：

- **把 `tinyfork.c` 里的 `MAP_PRIVATE` 改成 `MAP_SHARED`。** 机器的写入会**穿透到文件**，
  快照在它们脚下被改掉，最后一行会报 `MODIFIED`。
  **你刚刚把一个分叉点变成了四台 VM 之间的共享可变状态。**
- 跑 `FORKS=12 ./fork.sh`，看单次恢复耗时怎么拒绝增长。
- `fork.sh` 运行时，对其中一个 firecracker 进程 `cat /proc/<pid>/smaps_rollup`，
  对比 `Private_Dirty` 和 `Rss`。**那个差额就是共享给你省下的。**

---

## What You Just Learned

1. **fork 一台机器 = `MAP_PRIVATE`。** 不是谁实现的一个功能，而是 `mmap` 上的一个标志位，
   **它把内核几十年的写时复制机制交到你手上，指向 guest 的内存。**

2. **第 N 台机器只为它的差异付费。** 六台 256 MiB 的 VM 装进 76 MB，因为它们几乎还没分化。
   恢复时间保持平坦也是同一个原因：**没有任何东西被预先复制。**

3. **快照是分叉点，不是备份。** 恢复永远不消耗它，任何恢复出来的机器也写不回它。
   **这才是把同一个文件交给所有人仍然安全的原因。**

4. **这是改变 agent 能力的那个原语。** 环境准备一次，然后从它并行探索多个未来，
   **只为分歧的部分付费。**

---

## Going Deeper

- **又是 `userfaultfd`。** s03 提过 `mem_backend: {backend_type: "Uffd"}`。
  和 fork 结合起来，**就是一个平台把一份基础镜像放在对象存储里、为上千个沙箱提供缺页服务
  的做法。**
- **KSM（内核同页合并）。** `/sys/kernel/mm/ksm/` 会在**没有共享来源**的进程之间找出内容
  相同的页并合并。它是"你没规划过的共享"的兜底；**fork 是你规划过的共享。**
- **`smaps_rollup`。** `/proc/<pid>/smaps_rollup` 里的 `Private_Dirty` 对 `Rss`，
  就是这一章在测的东西，**按进程、免算术**。
- **Diff 快照。** Firecracker 的 `snapshot_type: "Diff"` 只写自基础快照以来变过的页
  ——**同一个思想，作用在文件上而不是内存上。**

---

**下一章：** s06 — *里面得有个人* *（尚未写完）*
你已经能启动机器、冻住它、分叉它。**但你还没法让其中一台执行一条命令。**
