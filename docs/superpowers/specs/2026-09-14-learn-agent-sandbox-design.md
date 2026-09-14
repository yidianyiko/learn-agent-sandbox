# learn-agent-sandbox — 设计文档

- 日期：2026-09-14
- 状态：待 review
- 仓库：`/data/projects/learn-agent-sandbox`

---

## 1. 项目定位

**名称**：`learn-agent-sandbox`

**Tagline**：
> Build the sandbox your AI agent runs in — from `docker run` to a microVM that forks in milliseconds.

**一句话**：一个循序渐进的教学项目，带读者从"容器为什么不够"一路建到"能跑真 agent 的最小沙箱平台"。

**性质**：教学项目，不是产品。名字里的 `learn-` 是自我约束。

### 命名决策依据

- `learn-` 前缀的最强参照是 `shareAI-lab/learn-claude-code`（76.7k⭐）——同领域（AI agent）、同体裁（分章动手建造）、同年代、同为中文社区起源。参照系相似度高于 `hello-`（hello-algo 130k / hello-agents 78.7k，但属不同体裁）。
- 否决 `hello-`：该前缀承诺"全程入门友好"，而本项目 s05（Rust）、s06（网络）、s07（手搓 agent）后半程难度真实偏高，承诺与曲线不匹配。
- 否决 `-from-scratch` 后缀：用户偏好前缀式命名。
- 否决 `awesome-`：社区约定该前缀专指精选清单。
- 否决 `simple-`：实测弱（SimpleKernel 8 年 3.2k、SimpleCompiler 46）。
- 避开的高星撞名：`microsandbox`(8.2k)、`tinyvm`(3.3k)、`nanobox`(1.6k)、`minivm`(1.7k)。
- `ag9920/learn-agent-sandbox`(1⭐) 占用可忽略。

---

## 2. 世界观（README 第一屏要立的论点）

> 过去二十年的隔离技术，都假设跑的代码是人写的、审过的、部署过的。
> Agent 打破了这个假设 —— 它执行的代码没有任何人看过一眼。
> 沙箱因此从一个运维细节，变成了架构基石。

这是本项目对应 learn-claude-code 中 "An Agent Product = Model + Harness" 的位置：先给读者一个重构认知的框架，再进代码。

**依据**：教学仓库的传播来自观点而非代码。learn-claude-code 以约 2000 字哲学开篇；SimpleCompiler 以 cmake 编译步骤开篇（46⭐）。

---

## 3. 目标读者

1. **后端开发者，零系统背景** —— 会写业务代码，没碰过 KVM / 内核 / Linux 网络。
2. **AI 应用开发者** —— 在用 E2B / Docker 跑 agent 代码，想搞懂手里的黑盒。

**由此产生的硬约束**：读者 1 要动手建，读者 2 要心智模型。因此**每一章必须独立完整、可以停在那里**，不能设计成"必须走完才有收获"。读者 2 读到 s02 即可收手。

---

## 4. 范围

**弧线**：容器 → 能跑真 agent 的最小平台（完整 build-your-own-X 闭环）。

### 红线（写进 README）

明确**不做**：

- 多租户与权限
- 计费与配额
- 多节点调度
- Web UI / 控制台
- 生产安全加固（审计、限流、监控）
- 模板构建系统
- 性能调优到生产水平

并给出指路牌：**"走到这一步，你该去用 E2B，或基于 `e2b-dev/runtime` 改。"**

红线是防止教学项目滑向产品的唯一有效手段，也是对读者诚实的一部分。

---

## 5. 章节大纲

| # | 目录 | motto | 语言 | 环境 | 读者产出 |
|---|---|---|---|---|---|
| s00 | `s00_shared_kernel` | *Your container is not a sandbox* | Docker | **仅 Docker** | 亲眼看到容器与宿主共享内核的证据 |
| s01 | `s01_first_microvm` | *A virtual machine in 125 ms* | shell + curl | `/dev/kvm` | 跑起第一个 Firecracker VM，测出启动耗时 |
| s02 | `s02_snapshot_restore` | ***Don't boot. Restore.*** | shell + curl | `/dev/kvm` | 冷启动 vs 快照恢复的对比数字 |
| s03 | `s03_orchestrator` | *Control plane, data plane, never mixed* | Go | `/dev/kvm` | 能起停沙箱的 HTTP 服务 |
| s04 | `s04_fork_parallel` | *Fork the machine, not the process* | Go | `/dev/kvm` | 从一个快照 fork 出 N 个沙箱并行跑 |
| s05 | `s05_in_vm_agent` | *Someone has to be inside* | Rust | `/dev/kvm` | VM 内静态二进制 agent，可从宿主 exec 进去 |
| s06 | `s06_networking` | *Now let it reach the internet* | Go + shell | `/dev/kvm` | tap / NAT / 端口转发，VM 能联网并暴露服务 |
| s07 | `s07_sdk_and_agent` | *Now hand it to an agent* | Python | `/dev/kvm` | Python SDK + 手搓 coding agent 跑在自建沙箱上 |

### 排序依据

- **s02 排第三**：快照恢复是全项目的认知分水岭，尽早到达认知高点，不让读者爬到第六章才拿到最有价值的东西。
- **s05 先于 s06**：「能在里面执行命令」比「能上网」更根本；s05 也是 Rust 的自然落点（小、自包含、需极小静态二进制）。

### s00 的分寸

教的是**共享内核的可观测证据**，不是攻击手法。三个演示均为公开文档化行为：

1. 容器内 `uname -r` 等于宿主内核 —— 共享内核的直接证据
2. `--privileged` 容器可访问宿主资源 —— 配置错误的代价
3. 资源耗尽外溢到宿主 —— 资源隔离 ≠ 安全隔离

目的是让读者理解边界位置，不涉及漏洞利用。

---

## 6. 语言方案：按层选语言

每种语言出现在它在工业界真实所处的层，**无任何重复实现**：

| 层 | 本项目用 | 工业界实际情况 |
|---|---|---|
| 入门演示 | Docker / shell | — |
| VMM 调用 | shell + curl | Firecracker socket REST API |
| 编排 / 控制面 | **Go** | E2B `packages/orchestrator`、`packages/api`、containerd、Kubernetes、gVisor、Nomad |
| VM 内 agent | **Rust**（刻意偏离） | **E2B `packages/envd` 实际是 Go** |
| SDK / 接口层 | **Python** | E2B Python/TS SDK |
| （本项目不涉及）VMM 本身 | — | Firecracker、Cloud Hypervisor、crosvm 均为 **Rust** |

### s05 选 Rust 是刻意偏离，需在章节中说明

**事实**：E2B 的 envd 是 Go（已核实 `packages/envd/go.mod`）。本项目在这一层选 Rust 属于有意的教学取舍，理由：

1. 它是小而自包含的程序（收命令、执行、回传），是理想的 Rust 练手场，不会失控
2. 需要极小的静态二进制塞进 rootfs —— Rust 在此有真实优势
3. Rust 是 VMM 层（Firecracker / Cloud Hypervisor / crosvm）的事实标准语言，读者借此接触到系统层为何选 Rust
4. **"我们选 Rust，E2B 选 Go，这里是取舍"** 本身就是一个极好的教学时刻

**要求**：s05 的 README 必须明确写出这一点，不得暗示"工业界这层就是用 Rust"。教学项目的事实准确性优先于叙事整洁。

### 附加教学收益

读者走完会自己得出"为什么 VMM 层用 Rust、编排层用 Go、接口层用 Python"的结论。这个认知只有横跨全栈的项目能教。

## 7. 仓库结构

```
learn-agent-sandbox/
├── README.md                    # 英文主文档：世界观 + 路径图 + 环境矩阵
├── README.zh.md                 # 中文
├── LICENSE                      # MIT
├── CONTRIBUTING.md
├── scripts/
│   ├── check-env.sh             # 5 秒环境诊断
│   └── fetch-assets.sh          # 下载 firecracker/kernel/rootfs，版本+checksum 硬钉
├── .github/workflows/ci.yml
└── s0N_<topic>/
    ├── README.md                # 英文
    ├── README.zh.md             # 中文
    ├── <主代码文件>              # 单文件，≤ 300 行
    └── images/
```

**依据**：learn-claude-code 使用 `s01_…`~`s17_…` 分章目录（76.7k⭐）；SimpleCompiler 使用 `src/ test/ doc/` 产品式结构（46⭐）。用教材方式组织仓库，而非软件工程方式。

---

## 8. 每章 README 模板

```markdown
# s0N: <标题> — <motto>

[English](README.md) · [中文](README.zh.md)
s0(N-1) → **s0N** → s0(N+1)

> 环境徽章：Docker only / 需要 /dev/kvm
> 预计耗时：xx 分钟

## The Problem            ← 先让读者疼（问题驱动，非概念驱动）
## The Solution           ← 一句话思路 + 一张图
## How It Works           ← Step 1/2/3，代码逐步长出来
## Try It                 ← 可复制粘贴的命令
## What You Just Learned  ← 3 条要点
## Going Deeper           ← 延伸阅读 + 在 e2b-dev/runtime 里对应的真实实现位置
```

- 前四段结构照搬 learn-claude-code（已验证）。
- `Going Deeper` 为本项目新增，作用是把玩具与生产系统连起来——因 E2B 开源，此路可通。已核实的章节→真实实现映射：

  | 本项目 | `e2b-dev/runtime` 对应 |
  |---|---|
  | s03 编排器 | `packages/orchestrator`、`packages/api` |
  | s05 VM 内 agent | `packages/envd`（Go 实现） |
  | s06 网络 | `packages/client-proxy` |
  | s07 SDK | `e2b-dev/E2B`（Python/TS SDK 仓库） |

- **硬规则：每章主代码 ≤ 300 行**，超出说明该章需拆分。（learn-claude-code 实测 s01 4.5KB / s06 12.5KB，约 120–350 行）

---

## 9. 环境门槛对策（最高优先级）

本项目相对 learn-claude-code 的唯一结构性劣势：后者跑通第一章只需一个 API key，本项目需要 `/dev/kvm` + Linux + x86_64。

| 措施 | 说明 |
|---|---|
| s00 零 KVM 依赖 | 100% 读者可完成第一章，建立承诺感后再面对门槛 |
| `scripts/check-env.sh` | 检查 `/dev/kvm`、CPU vmx/svm、嵌套虚拟化、架构、用户组；输出"你能跑到哪一章"+ 缺什么怎么补 |
| README 首屏环境矩阵 | Linux 裸机 ✅ / WSL2 ✅（需开启嵌套虚拟化）/ macOS ❌ / Codespaces ❌ |
| 云主机退路 | 列出确认支持嵌套虚拟化的具体机型 + 一键开机脚本 |
| 每章顶部环境徽章 | 避免读者爬到一半才发现跑不了 |

---

## 10. CI 与防腐烂

教学仓库的主要死因是"跑不起来"。三道防线：

1. **版本硬钉** —— firecracker 二进制、kernel、rootfs 全部锁定版本与 checksum，集中在 `scripts/fetch-assets.sh`
2. **CI 跑每章真实代码**，而非单元测试
3. **定时 CI（每周）** —— 无人改动时也能发现外部资源失效

**待验证项**：GitHub 的 Ubuntu runner 据称支持 KVM（Android 模拟器 CI 依赖此能力），若成立则 s01+ 可在 CI 中运行。**须在 s01 落地时实测确认**。若不成立，退化方案为：s00 跑完整 CI，其余章节仅做静态检查 + 构建验证。

---

## 11. 多语言

- `README.md`（英文）为主，`README.zh.md`（中文）并列，每章同构。
- 日文暂不做，等社区贡献。

**依据**：learn-claude-code 英/中/日三语 → 76.7k⭐；SimpleCompiler 仅中文 → 46⭐。语言是成本最低、回报最高的杠杆。

---

## 12. 发布节奏

**不写完再发。**

| 里程碑 | 内容 | 依据 |
|---|---|---|
| M1 | README（世界观+路径图）+ `check-env.sh` + s00 + s01 + CI | s00/s01 已独立有价值；早期收环境反馈远比写完再修便宜 |
| M2 | s02 | 第一个值得主动传播的时刻——"Don't boot. Restore." 的对比表本身是传播单元 |
| M3 | s03 + s04 | Go 编排器成型 |
| M4 | s05 + s06 | Rust + 网络 |
| M5 | s07 | 闭环，正式宣传 |

---

## 13. 竞品与参照

**形态参照**（教学项目）：

- `shareAI-lab/learn-claude-code` 76.7k⭐ —— 结构、README 模板、多语言、motto 的主要来源
- `Simple-XX/SimpleKernel` 3.2k⭐（8 年）、`Simple-XX/SimpleCompiler` 46⭐ —— 反面参照（产品式目录、无观点、单语言）
- `karpathy/nanoGPT` 63k⭐、`micrograd` 17.5k⭐ —— 极小可读实现的范式

**领域现状**（产品，非竞品）：

- `e2b-dev/runtime` 1.4k⭐ Go Apache-2.0 —— 本项目 `Going Deeper` 指向的真实实现
- `superradcompany/microsandbox` 8.2k⭐ Rust —— local-first microVM runtime 产品
- E2B / Modal / Daytona 等托管服务

**结论**：agent 沙箱的**产品位不空**（需求已验证），**教学位空**。本项目占教学位。

### 叙事原则：不得把本项目定位为任何厂商的附属

面向读者的文档（README、章节正文）中：

- **论证"层决定语言"这类行业规律时，举一类而非一家。** 引用单一厂商会同时削弱论点
  和项目的独立性。
- **不得出现"本项目是 X 的缩比模型"一类表述。** 教学项目的价值不依附于任何产品。
- E2B 及其他具体产品只出现在「相关项目 / 延伸阅读」中，与 Firecracker、learn-claude-code
  并列，**每份 README 中提及不超过 1–2 次**。
- 章节末的 `Going Deeper` 可以指向真实生产实现的具体位置（这是本项目的独有优势），
  但措辞是"真实系统里这一块在哪"，而非"我们在模仿谁"。
- 「刻意留白的部分」一节写**教学取舍**（工程量 vs 认知量），不写产品免责声明。

---

## 14. 开放问题（实现时解决）

1. GitHub Ubuntu runner 的 KVM 可用性 —— s01 落地时实测
2. 云主机退路的具体机型清单需实测确认
3. s00 三个演示的具体实现形式（脚本 vs docker-compose）
4. Firecracker / kernel / rootfs 的具体钉定版本

---

## 15. 本次设计已确认的决策清单

- [x] 项目名 `learn-agent-sandbox`
- [x] 目标读者：后端开发者（零系统背景）+ AI 应用开发者
- [x] 范围：容器 → 能跑真 agent 的最小平台，8 章
- [x] 语言按层：Docker/shell → curl → Go → Rust → Python
- [x] 仓库形态：分章独立目录（方案 A）
- [x] 每章 README 六段式模板，主代码 ≤ 300 行
- [x] 英文主 + 中文并列
- [x] 环境门槛四条对策
- [x] 红线清单
- [x] M1–M5 发布节奏
- [x] LICENSE：MIT（教学项目取最简许可，降低读者复用摩擦）
