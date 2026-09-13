# learn-agent-sandbox

**亲手造出 AI agent 运行其中的那个沙箱 —— 从 `docker run` 一路到能在毫秒间 fork 的 microVM。**

[English](README.md) · [中文](README.zh.md)

> ⚠️ **状态：早期。** 设计已定稿，章节正在写。当前进度见[章节表](#章节)。

---

## 你的 agent 正在执行的代码，没有任何人看过一眼

过去二十年，我们建立的每一种隔离技术都建立在同一个假设上：
**被执行的代码是人写的、人审过的、有意部署的。** 容器、namespace、cgroup、seccomp——
全部是为「代码可信、输入不可信」的世界设计的。

Agent 打破了这个假设。

Agent 在运行时写代码，并立刻执行它。没有 review，没有部署环节，没有人在回路里。
而且如果这个 agent 可被 prompt injection 触及，那段代码背后的**意图**甚至可能不是你的。

信任模型就此翻转：**代码本身现在是不可信的。**

正是这一次翻转，让沙箱从一个运维细节变成了承重的架构构件。这个仓库讲的就是怎么造一个——
从你已经熟悉的容器出发，一路爬到一个能从快照启动、能 fork、能让真 agent 在里面干活的 microVM。

---

## 你会造出什么

```
  s00              s01 ─ s02          s03 ─ s04 ─ s05 ─ s06        s07
  ┌────────┐      ┌────────────┐     ┌──────────────────────┐    ┌────────┐
  │ Docker │  ──▶ │ Firecracker│ ──▶ │     你的编排器        │──▶ │ agent  │
  │  那堵  │      │  microVM   │     │  fork · exec · 网络  │    │ 跑在   │
  │  墙    │      │   快照     │     │                      │    │ 里面   │
  └────────┘      └────────────┘     └──────────────────────┘    └────────┘
   shell           shell + curl        Go · Rust · shell          Python

   「为什么           「别启动，          「控制面与              「现在把它
     这不够」           恢复。」            数据面」                交给 agent」
```

**每一章都独立成立。** 拿到你想要的东西之后，随时可以停。

---

## 章节

| # | 章节 | 你会带走什么 | 语言 | 需要 KVM | 状态 |
|---|------|--------------|------|:--------:|:----:|
| **s00** | 你的容器不是沙箱 | 容器与宿主共享内核的**直接证据** | shell | **否** | 🚧 |
| **s01** | 125 毫秒里的一台虚拟机 | 手动跑起一个真的 Firecracker microVM，并测时 | curl | 是 | 🚧 |
| **s02** | **别启动，恢复。** | 两个数字：冷启动 vs 快照恢复 | curl | 是 | 🚧 |
| **s03** | 控制面与数据面，永不混合 | 一个能起停沙箱的 HTTP 服务 | Go | 是 | 🚧 |
| **s04** | fork 机器，而不是 fork 进程 | 从一个快照分叉出 N 个沙箱并行运行 | Go | 是 | 🚧 |
| **s05** | 里面得有个人 | guest 内的极小静态二进制，可从宿主 `exec` 进去 | Rust | 是 | 🚧 |
| **s06** | 让它连上互联网 | tap 设备、NAT、端口转发 | Go | 是 | 🚧 |
| **s07** | 现在把它交给 agent | 一个 Python SDK，和一个住在你自建沙箱里的 coding agent | Python | 是 | 🚧 |

**如果你只读一章，读 s02。** 快照恢复是沙箱能在毫秒而非秒级启动的原因，
搞懂它之后，市面上所有 agent 沙箱产品对你来说都会突然变得透明。

---

## 为什么语言一直在换

每一层都用这一层在生产环境中真正使用的语言：

| 层 | 本项目 | 工业界 |
|---|---|---|
| 编排 / 控制面 | **Go** | E2B `packages/orchestrator`、containerd、Kubernetes、gVisor |
| guest 内 agent | **Rust** | E2B 的 `envd` 其实是 Go —— 我们刻意选 Rust，s05 会讲清这个取舍 |
| SDK | **Python** | E2B 的 SDK，以及基本上所有同类 |
| VMM 本身（本项目不造） | — | Firecracker、Cloud Hypervisor、crosvm，全是 Rust |

走完整个栈，是理解**工业界为什么这样分层**的唯一途径。

---

## 环境要求

Firecracker 需要硬件虚拟化支持。这是一张诚实的表：

| 环境 | 可用 | 说明 |
|------|:----:|------|
| Linux 裸机，或开启嵌套虚拟化的虚拟机 | ✅ | 参考环境 |
| Windows 11 上的 WSL2 | ✅ | 需开启嵌套虚拟化 |
| macOS（Intel 或 Apple Silicon） | ❌ | 没有 `/dev/kvm`，请用 Linux 云主机 |
| GitHub Codespaces / 多数 CI | ❌ | 通常不支持嵌套虚拟化 |

**s00 只需要 Docker** —— 所有人都能完成第一章。

先看看你站在哪：

```bash
git clone https://github.com/yidianyiko/learn-agent-sandbox
cd learn-agent-sandbox
./scripts/check-env.sh
```

它会告诉你这台机器能爬到第几章，以及剩下的需要装什么。

---

## 这个项目不做什么

这是一个**教学仓库**。它刻意缺失了所有会让它变成产品的东西：

- 多租户与权限
- 计费、配额、限流
- 多节点调度
- Web 控制台
- 生产级加固、审计、监控
- 模板构建系统
- 超出「你能看出它为什么快」程度的性能调优

**每章代码控制在 300 行以内**，因为只有能一口气读完的代码才有教学价值。

**当你超出这个仓库的范围时，去用 [E2B](https://e2b.dev)，或者 fork
[`e2b-dev/runtime`](https://github.com/e2b-dev/runtime)** —— 它是 Apache-2.0 的，
而本仓库是它的一个缩比模型。每一章的结尾都会指向那个代码库里对应的真实实现。

---

## 值得一读的相关项目

- [`e2b-dev/runtime`](https://github.com/e2b-dev/runtime) —— 生产级实现，Go
- [`firecracker-microvm/firecracker`](https://github.com/firecracker-microvm/firecracker) —— VMM 本身，以及它的 [NSDI '20 论文](https://www.usenix.org/conference/nsdi20/presentation/agache)
- [`shareAI-lab/learn-claude-code`](https://github.com/shareAI-lab/learn-claude-code) —— 本项目上面那一层：agent 自己是怎么造出来的

---

## 许可证

MIT
