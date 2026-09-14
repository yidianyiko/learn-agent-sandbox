# s08：现在把它交给 agent

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/README.zh.md) → ... → [s06](../s06_in_vm_agent/README.zh.md) → [s07](../s07_networking/README.zh.md) → **s08**

> **需要：** `/dev/kvm`、cargo、python3、已下载的资产。
> `ANTHROPIC_API_KEY` 可选——没有它时会有一个脚本化替身驱动同一个循环。
> **耗时：** 约 30 分钟。

> *「现在把它交给 agent。」*

---

## The Problem

一切都能用了。机器一秒内启动、冻成两个文件、以一台的代价分叉成四台、
通过一条不需要网络的通道接受命令、并在你允许时连上互联网。

**然后没有人会用它**，因为用它就意味着要懂 KVM ioctl、cpio 归档、vsock 握手和写时复制内存。

**最后一章讲的是怎么把这一切送出去。**

---

## Part 1 · SDK

```python
from sandbox import Sandbox

with Sandbox() as sbx:
    print(sbx.run("uname -r").stdout)
    snap = sbx.snapshot()

for child in snap.fork(4):
    child.run("...")
```

```bash
python3 demo.py
```

```
1 · One sandbox
   booted in 789 ms   (id 9369132d6ebb)

   $ uname -r
     6.1.186
   $ free -m | awk 'NR==2{print $2" MB"}'
     230 MB

2 · Prepare an environment, then freeze it
   prepared: installed at 21:10:24
   snapshot: 256 MiB of memory in 425 ms

3 · Fork it four ways
   four machines in 97 ms total

   fork 1   shared: installed at 21:10:24   own: branch 1
   fork 2   shared: installed at 21:10:24   own: branch 2
   fork 3   shared: installed at 21:10:24   own: branch 3
   fork 4   shared: installed at 21:10:24   own: branch 4
```

`sandbox.py` 里没有一样新东西。它是 s01（启动）、s03（快照）、s05（分叉）、s06（对话）、
s07（网络）的重新编排，**只为了让调用者不必知道这些**。

> **这是 SDK 唯一做的事：决定你被允许不再思考什么。**

这里每个方法都是一次这样的决定——

| 方法 | 它藏起了什么 |
|---|---|
| `Sandbox()` | 拉起 VMM、四个 API 请求、打包 initramfs、等待 agent 报到 |
| `.run(cmd)` | `CONNECT 1234\n` / `OK\n` 握手，以及从流里把 `[exit N]` 解析出来 |
| `.snapshot()` | 必须先暂停，然后写两个文件 |
| `.fork(n)` | 恢复只能在全新进程上做，且快照里的 vsock 路径必须被覆盖 |

### 两处值得留意的细节

**Firecracker 的 API 是走 unix socket 的 HTTP，而 Python 的 `http.client` 不会拨这种地址。**
与其加一个依赖，`_api` 自己写了那四行 HTTP。**它比那句 import 还短。**

**`/vm` 是 `PATCH` 不是 `PUT`。** 其他端点都在声明一个资源，这一个是在更新一个已经存在的
东西的状态。写错了只会返回一个光秃秃的 `400`，不带任何解释——**为此花掉了几分钟**。

---

## Part 2 · agent

```bash
python3 agent.py "find out how many commands this machine has, then verify it with a script you write"
```

```
task  find out how many commands this machine has, then verify it with a script you write

sandbox 0e032a994953 up

   $ uname -r; ls /usr/bin | wc -l
     6.1.186
     177

   $ printf 'n=0\nfor f in /usr/bin/*; do n=$((n+1)); done\necho "counted $n"\n' > /tmp/count.sh && sh /tmp/count.sh
     counted 177

I wrote a script into the sandbox and ran it; the count above matches what ls
reported, so the environment is behaving.

sandbox destroyed
```

**整个程序就是那个循环**，短到可以一口气读完：

```python
while True:
    reply = model(messages)
    messages.append({"role": "assistant", "content": reply.content})

    calls = [b for b in reply.content if b.type == "tool_use"]
    if reply.stop_reason != "tool_use" or not calls:
        break

    results = []
    for call in calls:
        out = sbx.run(call.input["command"])          # <- 八章的内容，一行
        results.append({"type": "tool_result", "tool_use_id": call.id,
                        "content": out.stdout, "is_error": out.exit_code != 0})
    messages.append({"role": "user", "content": results})
```

**问模型。它要一条命令。在沙箱里执行。把发生的事告诉它。重复到它不再要为止。**

> **这就是一个 agent。** 有意思的工程不在这个循环里——**在那行"把命令跑在一个模型伤不到的地方"上。**

### 这二十行里有三件事要紧

**要整体 append `reply.content`，不能只取文字。** 开了自适应思考之后，响应里带着 thinking
块，**下一次请求必须原样回传**。只把文字抽出来 append，会悄悄把它们丢掉。

**一个 assistant 轮次的所有 `tool_result` 必须放在同一条 user 消息里回去。**
拆成多条会**教会模型不要再并行请求**。

**命令失败是一个结果，不是一个异常。** `is_error: true` 配上真实输出，
好让模型读到错误、换个办法——**而 agent 的时间大部分就花在这件事上**。

### 没有 key 时怎么跑

没有 `ANTHROPIC_API_KEY` 时，一个脚本化替身会返回和 API 相同形状的东西，循环原封不动地跑。
**重点是这个循环不花一分钱也能被读懂和测试**；把 key 配上，Claude 驱动的是同一份代码。

---

## 这个沙箱到底为了什么

[s05](../s05_fork_parallel/README.zh.md) 论证过 fork 改变了 agent 能做什么。
**用 SDK 的语言写出来是这样：**

```python
with Sandbox() as base:
    base.run("apk add gcc && git clone ... && make deps")   # 只做一次
    ready = base.snapshot()

attempts = ready.fork(4)                                    # 97 毫秒
for attempt, fix in zip(attempts, candidate_fixes):
    attempt.run(f"git apply {fix} && make test")
```

**四次尝试跑在一个准备好的环境上，互相看不见对方，代价只是准备那一次。**
没有 fork，这就是四次串行准备；有了它，**准备发生在它们任何一个存在之前**。

---

## Try It

```bash
../scripts/fetch-assets.sh
make -C ../s06_in_vm_agent all

python3 demo.py                       # SDK
python3 agent.py                      # 循环，用替身
ANTHROPIC_API_KEY=... python3 agent.py "你的任务"
```

接下来值得动手的：

- **给 agent 一个它第一次一定会失败的任务**，看它读到错误然后换策略——
  **那条反馈路径正是"输出要原样回传"的全部理由**。
- 在 `run_command` 旁边加一个 `write_file` 工具。**你现在是在设计一个 agent 的工具面了**，
  那是这个仓库之后的下一个问题。
- 在模型执行到第三条命令之后打个快照，然后 fork 它。**agent 现在可以回退了。**

---

## What You Just Learned

1. **SDK 是一个关于"无知"的决定。** 四个方法，调用者永远不必知道 vsock 握手是什么。
   **底下的一切原封不动，而且仍在运行。**

2. **agent 的循环只有二十行。** 问、跑、汇报、重复。
   **这个仓库里所有难的部分，都在其中一次调用的后面。**

3. **难的从来不是那个循环。** 难的是**造一个"出错很便宜"的地方来跑那些命令**——
   那花了八章，也正是这二十行敢写出来的唯一原因。

---

## 这里结束，生产从哪里开始

你现在有了大约两千行代码，**形状和一个商业 agent 沙箱是一样的**。
生产系统多出来的不是某个缺失的想法——**而是这个仓库刻意划下的那条
[红线](../README.zh.md#刻意留白的部分)**：多租户、配额、跨机器调度、模板构建、
出站策略，以及把"在我笔记本上能跑"变成"给陌生人的代码用也安全"的那些加固。

**去读 [`e2b-dev/runtime`](https://github.com/e2b-dev/runtime)。**
这里每一章都指向了它里面做同一件事的那个文件。**那份代码现在读起来会不一样了**——
不再是一个高不可攀的生产系统，**而是你那个玩具在经历了所有人之后活下来的版本**。

---

**仓库到此为止。** 回到[开头](../README.zh.md)。
