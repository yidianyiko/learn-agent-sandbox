# s04：控制面与数据面，永不混合

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/README.zh.md) → [s01](../s01_first_microvm/README.zh.md) → [s02](../s02_write_a_vmm/README.zh.md) → [s03](../s03_snapshot_restore/README.zh.md) → **s04** → [s05](../s05_fork_parallel/README.zh.md) → s06 → s07 → s08

> **需要：** `/dev/kvm`、Go、已下载的资产。
> **耗时：** 约 30 分钟。

> *「控制面与数据面，永不混合。」*

---

## The Problem

你已经能启动一台 microVM（[s01](../s01_first_microvm/README.zh.md)）、知道它由什么构成
（[s02](../s02_write_a_vmm/README.zh.md)）、能把它冻住再唤醒
（[s03](../s03_snapshot_restore/README.zh.md)）。**但那始终是一台机器，手动启动，你自己盯着。**

现在起第二台。再起第十台。**必须有东西记住哪些存在、分配名字、给停掉的那些收尾。**

直觉上会想写一个"管理者"：一个拥有这些机器的进程，把它们放在一张 map 里，并且**把活儿
转发给它们**。这个形状是错的，而且原因不是品味问题——**它违背了 microVM 实际上是什么。**

---

## Part 1 · 打死管理者，虚拟机会怎样

```bash
./orphans.sh
```

由一个父进程启动两台 VM，然后用 `SIGKILL` 把父进程打死——不清理、不给反应机会，
和真实崩溃一样粗暴。

```
1 · Two microVMs under a supervisor

   supervisor pid 91670
       PID    PPID STAT COMMAND
     91672   91670 Sl   firecracker
     91711   91670 Sl   firecracker

2 · Kill the supervisor — SIGKILL, no cleanup, no warning

   supervisor: gone

3 · The machines

       PID    PPID STAT COMMAND
     91672       1 Sl   firecracker
     91711       1 Sl   firecracker

4 · Can anyone still control them?

   vm1  GET /  -> HTTP 200
   vm2  GET /  -> HTTP 200
```

**`PPID` 从管理者变成了 `1`。** 两台机器被 init 收养，继续运行，**socket 照常响应。
它们都没察觉发生过什么。**

这是 [s02](../s02_write_a_vmm/README.zh.md) 那个名字的兑现。KVM 是 **Kernel**-based：
**一台虚拟机就是一个进程**，所以它像机器上任何别的进程一样被调度、被拥有、被遗弃、被
收养。**它没有特殊到会跟着启动者一起死。**

### 这告诉你管理者到底是什么

**它是记账员，不是管道。** 没有任何 guest 流量经过它，所以失去它对运行中的东西**毫无
代价**。这个分离值得刻意保持：

```
控制面    哪些沙箱存在、谁要的、什么时候停
          低流量 · 必须正确 · 可以重启

数据面    机器本身，在干真正的活
          高流量 · 必须快 · 不该关心上面那层
```

**一旦混起来**——让 guest 的 I/O 穿过那个同时也在提供 API 的进程——一次慢 API 调用就会
拖住一个工作负载，而你 HTTP handler 里的一个 panic 会**带走这台宿主上的每一个沙箱**。

### 它也告诉你代价

那两台机器**还各占着 128 MiB，还在响应 socket**，而知道它们名字的那张表已经跟着管理者
死了。**它们是孤儿。** 永远不会有人停掉它们，因为没有任何人知道它们在。

所以**控制面不能把真相只放在自己的内存里**。它必须写在能活过崩溃的地方，而且必须能够
重新走进来、认出它找到的东西。

---

## Part 2 · 一个可以被打死的控制面

`main.go` 约 260 行 Go，零依赖，四个端点：

```
POST   /sandbox       起一台
GET    /sandbox       列出真正在跑的那些
GET    /sandbox/{id}  其中一台
DELETE /sandbox/{id}  停掉并忘记
```

```bash
./demo.sh
```

```
1 · Start the control plane, create two sandboxes
   control plane pid 99415
   POST /sandbox -> dlezmbghkrb2
   POST /sandbox -> dlezmbhltdje

2 · What is on disk  (the part that survives)
   dlezmbghkrb2.json
   dlezmbghkrb2.sock
   dlezmbhltdje.json
   dlezmbhltdje.sock

3 · Kill the control plane
   control plane: gone
   GET /sandbox : connection refused

   the machines:
       PID    PPID STAT COMMAND
     99427       1 Sl   firecracker
     99435       1 Sl   firecracker

4 · Start a new control plane
   adopted 2 sandbox(es) already running

5 · Kill one machine behind its back, then ask again
   killed pid 99427 directly, without telling the control plane
   [{"id":"dlezmbhltdje", ...}]
   reconcile: dlezmbghkrb2 is gone, forgetting it
```

**API 消失了又回来了。机器自始至终不知情。**

---

## How It Works

### 状态存储故意选最笨的方案

一个沙箱一个 JSON 文件，放在一个目录里：

```json
{
  "id": "dlezmbghkrb2",
  "pid": 99427,
  "sock": "/tmp/s04-state/dlezmbghkrb2.sock",
  "created": "2026-09-14T20:03:24.384141754+09:00"
}
```

**不用数据库。** 这一章的论点是**「状态必须活过进程」**，一个装着文件的目录就把这句话
说清楚了，不需要谁先学一套 schema。而且 **`cat` 就能看**——这在教程里比在生产里重要得多。

### 最要紧的那八行

```go
func alive(sb Sandbox) bool {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", sb.PID))
	if err != nil {
		return false
	}
	return bytes.Contains(b, []byte(sb.Sock))
}
```

直觉写法是 `syscall.Kill(pid, 0)`——那个号码上有进程吗？**但它回答的是错的问题。**

**PID 会被回收。** 你记下 99427，那个进程死了，计数器绕了一圈，99427 现在属于别人的编译器。
一个只检查"号码被占用没"的控制面，**会把 `cc` 报告成正在运行的 microVM，并最终把它
`SIGKILL` 掉。**

所以我们读它的命令行，**要求里面含有我们自己的 socket 路径**。firecracker 是以
`firecracker --api-sock <那个确切路径>` 启动的，**所以这是身份校验，不是存在性检查。**

### 调和，而不是记忆

```go
func reconcile() []Sandbox {
	// 遍历目录，逐个验活，死的就忘掉
}
```

它在**启动时**以及**每一次 `GET /sandbox`** 时被调用。这个进程从不缓存"我认为有两个"。
**每一个答案都是重新看了一遍的结果。**

这就是第 5 步能生效的原因：一台被背着杀掉的机器，**在下一次有人问起时就会被发现**，
而不是永远不会。这也正是 Kubernetes 的构造方式——**控制器观察世界并向期望状态收敛，
而不是假设自己上次的写入成功了。**

### 用 HTTP 对一个文件说话

```go
Transport: &http.Transport{
	DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", sock)
	},
},
```

**把 Transport 的拨号函数换掉**，忽略传进来的 network 和 address，改连一个 unix socket。

之后请求照样写成 `http://localhost/boot-source`——那个主机名在这里和在
`curl --unix-socket` 里一样，**是虚构的、被忽略的**。

### 用 Start 而不是 Run，并且不杀孩子

```go
cmd.Start()                      // 立刻返回；Run 会阻塞到进程结束
sb.PID = cmd.Process.Pid
go func() { _ = cmd.Wait() }()   // 它将来退出时负责收尸
```

用 goroutine `Wait` 是为了**不让退出的子进程在我们活着时变成僵尸**。

而**缺席的那部分是刻意的：控制面退出时不会杀掉任何孩子。** Part 1 已经确认那不是它的职责。

### 确认是真的了，才写下来

```go
	// 四个 VMM 请求全部成功之后：
	return sb, save(sb)
```

**一个"启动失败的沙箱"的状态文件，比没有状态文件更糟**——下一个控制面会去认领一个
从来不存在的东西。

---

## Try It

```bash
./orphans.sh    # part 1：管理者死了，机器没死
./demo.sh       # part 2：一个可以被中途替换的控制面

# 或者自己驱动它
go run . -state /tmp/sbx &
curl -X POST     localhost:8080/sandbox
curl             localhost:8080/sandbox
curl -X DELETE   localhost:8080/sandbox/<id>
```

接下来值得动手的：

- 起一个沙箱，然后 `cat` 它的状态文件、`ps` 它的 pid。**控制面知道的一切就在这两处。**
- 把某个状态文件里的 pid 改成一个不存在的号，再 `GET /sandbox`，看它被忘掉。
- 把它改成一个**确实存在但不是 firecracker** 的 pid——比如你的 shell。它**依然**被忘掉，
  因为 `alive` 校验的是身份不是存在。**然后删掉那行 `bytes.Contains` 再试一次**，
  你就看见了朴素写法会干出什么。

---

## What You Just Learned

1. **microVM 比启动它的东西活得久**，因为它是进程，而进程会被 init 收养。
   **编排器是登记处，不是监护人。**

2. **分离两个面是免费的保护。** 没有东西流经控制面，所以它可以崩溃、可以升级、可以重启，
   **对运行中的工作零影响**。

3. **这份自由的代价是失忆。** 把真相放在内存里的控制面，会在倒下时把它弄丢，
   **并遗弃它管理的一切**。

4. **所以不要记，去看。** 状态在磁盘上、存活性来自 `/proc`、身份被校验而不是被假设、
   每个答案都重新计算。**这就是调和（reconciliation），也是这个 260 行的程序能挨枪不死
   的原因。**

---

## Going Deeper

- **[`e2b-dev/runtime`](https://github.com/e2b-dev/runtime)** 正是这样切分的：
  `packages/api` 接收请求并记录意图，`packages/orchestrator` 在每个节点上持有 VMM。
  **你刚搭的这个切分和它是同一个**，少掉的是让它扛住一整个数据中心的那些部分。
- **`jailer`**（在 Firecracker 发布包里）才是生产控制面真正启动的东西：它在 `exec`
  之前把每个 VMM 放进独立的 chroot、namespace 和 cgroup。这里的 `exec.Command`
  是同一个调用，**只是没有任何约束**。
- **PID namespace 与 `pidfd`。** Linux 提供 `pidfd_open(2)`——一个指向"进程"而非"号码"
  的文件描述符，**天然免疫 `alive` 那段手工绕开的回收问题**。

---

**下一章：** [s05 — fork 机器，而不是 fork 进程](../s05_fork_parallel/README.zh.md)
s03 留下了一个可以被无限次恢复的快照。**现在同时恢复它十次。**
