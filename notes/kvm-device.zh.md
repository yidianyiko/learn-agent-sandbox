# 任务简报 · `/dev/kvm`

[English](kvm-device.md) · [中文](kvm-device.zh.md)

> 出发前的装备说明。s01 起的每一章都要用它。
> 不读也能往下走——但读完你会知道手里拿的是什么。

---

## 装备

```
/dev/kvm      字符设备    10:232    crw-rw----  root:kvm
```

它不存任何数据。它是**一扇门**。

`open()` 它，你拿到一个文件描述符；用 `ioctl()` 驱动那个描述符，你就能指挥内核里的
KVM 子系统。这是 Linux 把内核能力交给用户态程序的经典形制。

背后是两个内核模块：

```
kvm          ~980 KB    架构无关的通用逻辑
kvm_intel    ~360 KB    Intel VT-x 的具体实现（AMD 机器上是 kvm_amd）
```

---

## 它让你做什么

四步，一步比一步接近硬件：

```c
fd  = open("/dev/kvm", O_RDWR);
vm  = ioctl(fd,  KVM_CREATE_VM, 0);            // 1. 要一台虚拟机
      ioctl(vm,  KVM_SET_USER_MEMORY_REGION,   // 2. 把你自己进程的一块内存
                 &region);                     //    划给它当"物理内存"
cpu = ioctl(vm,  KVM_CREATE_VCPU, 0);          // 3. 要一个虚拟 CPU
      ioctl(cpu, KVM_RUN, 0);                  // 4. ← 全部意义所在
```

**第 4 步**让物理 CPU 切进硬件虚拟化模式（Intel 术语：VMX non-root），
**直接执行 guest 的机器码**。

不是模拟，不是指令翻译。真的 CPU 在真的跑那些指令，只是被硬件圈在一个独立的
执行上下文里——独立的页表、独立的寄存器状态、独立的特权级视图。

**这就是 microVM 能在毫秒级启动、并以接近原生速度运行的物理原因。**
s01 里你会亲手测到那个数字。

所以 kvm 组成员资格的实际含义是：

> **你被允许要求内核把 CPU 切进虚拟化模式，去执行你提供的代码。**

---

## 为什么需要一把钥匙

设备权限是 `0660 root:kvm`——两头都不能选，才落到"组"这个中间解：

| 方案 | 为什么不行 |
|---|---|
| **只给 root** | 那每个 VMM（QEMU、Firecracker、安卓模拟器）都得以 root 运行。**这反而更糟**——VMM 是个庞大、复杂、要解析不可信 guest 输入的程序，正是最不该有 root 的那一类 |
| **人人可用 `0666`** | KVM 的 ioctl 接口面积不小，等于把一大片内核代码对所有用户开放 |

于是选了 Unix 的经典答案：**一个组**。

设置它的是一条 udev 规则，就在你的机器上：

```
/lib/udev/rules.d/50-udev-default.rules:114
KERNEL=="kvm", GROUP="kvm", MODE="0660", OPTIONS+="static_node=kvm"
```

### 背后的设计哲学

这个划分不是随意的，它体现了 KVM 最核心的设计决策：

```
内核里（有特权）    只做必须硬件特权才能做的事：切 CPU 模式、管二级页表
                    ↓ 面积小、接口稳定、被审计得最狠

用户态（无特权）    VMM 干所有脏活：设备模拟、磁盘格式、网络、快照
                    ↑ 庞大、复杂、必然有 bug —— 但它没有特权
```

Firecracker 把这条推到极致：它自己还用 seccomp 把可用的系统调用锁进一个极小的白名单。
**隔离了 guest 之后，剩下的攻击面就是 VMM 自己**，所以它也得被关起来。

---

## 这把钥匙有多重

**它是真实的权限授予。** KVM 的 ioctl 接口复杂，历史上出过 guest 逃逸和本地提权的 CVE。
进了 kvm 组，就意味着这个用户能直接够到那片内核代码。

**但它不等于 root。** 作为对照，如果你已经在 `docker` 组里——

```bash
docker run --rm -v /:/host alpine cat /host/etc/shadow
```

这条命令以 root 身份读你的整个宿主文件系统。**`docker` 组按设计就是 root 等价**，
Docker 官方文档明说了这一点。

```
docker 组   =  root 等价（可挂载宿主根目录）
kvm 组      =  扩大了内核攻击面，但拿不到 root
```

**kvm 组严格弱于 docker 组。** 如果你已经能跑 Docker，加入 kvm 组对你的安全态势
基本没有改变。

---

## 附带解锁的东西

同一条 udev 规则文件里，另外两个设备也归 kvm 组：

```
/dev/kvm            root:kvm     硬件虚拟化              s01 – s04
/dev/vhost-vsock    root:kvm     宿主 ↔ guest 通信通道    s05
/dev/vhost-net      root:kvm     加速虚拟网卡             s06
```

**一次 `usermod` 把后面三章的设备权限一起给齐了。** 不用再回来加第二遍。

---

## 一个值得玩味的反讽

`/dev/kvm` 本身就是 [s00](../s00_shared_kernel/README.zh.md) 警告的那个东西——
**一个通往共享内核的接口**。

我们用来逃离"共享内核"问题的工具，自己是通过共享内核拿到的。

区别在**面积与审视强度**：

```
完整 Linux 系统调用 ABI     ~350 个入口，所有程序都在碰，攻击面巨大
KVM 的 ioctl 接口           窄得多，而且是整个内核里被审计最狠的子系统
                            —— 因为全世界的公有云都压在它上面
```

> **沙箱从来不是"消除攻击面"，而是"把攻击面换成一个更小、更被盯紧的"。**

这是本教程反复出现的主题。

---

## 领取装备

```bash
sudo usermod -aG kvm $USER
```

**`-a` 不能漏。** 这是个不可逆的事故点：

| 写法 | 后果 |
|---|---|
| `usermod -aG kvm you` | **追加**，在现有组之上加 kvm ✅ |
| `usermod -G kvm you`  | **替换**，附加组被整个换成只有 kvm ❌ |

第二种会让你瞬间失去 `sudo`、`docker`、全部附加组——而且因为丢了 `sudo`，
**你连改回来的权限都没有了**。

### 改完为什么还没生效

```bash
getent group kvm     # kvm:x:993:you   ← 磁盘上改好了
id -nG               # 没有 kvm        ← 但当前 shell 看不到
```

**组成员身份是在登录时烙进进程凭证的。** 内核在你登录那一刻读 `/etc/group`，
把组列表写进进程的 credential，之后 fork 出来的所有子进程继承这份快照。
改配置文件不会回溯更新已经在跑的进程。

| 场景 | 做法 |
|---|---|
| 让它永久生效 | **关掉终端重开**——新终端 = 新登录会话 = 重读 `/etc/group` |
| 不想重开，只想验证 | `sg kvm -c '你的命令'`，它会重新读组文件 |
| WSL2 上顽固不生效 | 在 Windows 里 `wsl --shutdown` 后重开 |

> ⚠️ 如果你装了 **ast-grep**，它的二进制也叫 `sg`，会在 PATH 里把这个 `sg` 盖住。
> 用绝对路径绕开：`/usr/bin/sg`。
> （顺带一提，`/usr/bin/sg` 其实是 `newgrp` 的软链——同一个程序靠 `argv[0]`
> 分辨自己是被怎么调用的，Unix 里很老的把戏。）

### 确认拿到了

```bash
./scripts/check-env.sh
```

`Hardware virtualization` 那一节应该变成 ✅，s01 之后的章节全部转为 ready。

---

**返回：** [s00 — 你的容器不是沙箱](../s00_shared_kernel/README.zh.md)
**前往：** s01 — 125 毫秒里的一台虚拟机 *（尚未写完）*
