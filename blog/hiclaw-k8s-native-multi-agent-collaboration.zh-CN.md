# HiClaw: 基于 Kubernetes 原生的多 Agent 协作编排系统

> 发布日期: 2026 年 4 月 14 日

---

## 运行多个 Agent 很简单，让它们协作才是难题

如果你用过 AI 编程 Agent，一定熟悉这个模式：一个 Agent，一个任务，一个上下文窗口。效果很好——直到不够用。

当你的项目需要一个前端开发、一个后端工程师、一个 DevOps 同时并行工作时，你又回到了手动协调的老路：在 Agent 之间复制粘贴上下文，用表格跟踪谁在做什么，祈祷它们不会互相踩代码。

这就是 HiClaw 要解决的问题。它不是又一个 Agent 运行时，而是一个让多个 Agent 像真实工程团队一样协作的编排系统——基于让 Kubernetes 成为容器编排标准的同一套声明式原则构建。

---

## 从容器编排到 Agent 编排

如果你熟悉 Kubernetes 生态，AI Agent 的演进路径会让你感到似曾相识：

| 容器生态 | Agent 生态 | 解决的问题 |
|---|---|---|
| Docker（容器运行时） | OpenClaw / Claude Code（Agent 运行时） | 如何运行一个隔离的工作单元 |
| Docker Compose（单机编排） | NemoClaw（单 Agent 沙箱管理） | 如何管理运行时的生命周期和配置 |
| **Kubernetes（集群编排）** | **HiClaw（多 Agent 协作编排）** | 如何让多个工作单元组成一个协调的系统 |

正如 Kubernetes 不替代 Docker，而是在其之上编排容器，HiClaw 也不替代 Agent 运行时——它在其之上编排协作。

但这里有一个超越类比的关键区分：**编排 vs. 协作**。

- **编排（Orchestration）**：管理 Agent 的生命周期、资源分配、安全隔离——"如何运行多个 Agent"
- **协作（Collaboration）**：定义 Agent 间的组织关系、通信权限、任务委派、状态共享——"多个 Agent 如何一起工作"

当前大多数多 Agent 系统止步于编排。HiClaw 更进一步。

---

## 声明式 Agent 团队：AI 的 CRD

HiClaw 的资源模型对写过 Kubernetes manifest 的人来说会非常亲切。四种 CRD 风格的资源类型，统一使用 `apiVersion: hiclaw.io/v1beta1`：

### Worker — Agent 编排中的 Pod

```yaml
apiVersion: hiclaw.io/v1beta1
kind: Worker
metadata:
  name: alice
spec:
  model: claude-sonnet-4-6
  runtime: openclaw
  skills: [github-operations]
  mcpServers: [github]
  soul: |
    你是一个专注于 React 的前端工程师...
```

每个 Worker 对应：一个 Docker 容器（或 K8s Pod）+ 一个 Matrix 通信账号 + 一个 MinIO 存储空间 + 一个 Gateway Consumer Token。无状态、可销毁、可重建——就像 Pod 一样。

### Team — Agent 编排中的 Deployment

```yaml
apiVersion: hiclaw.io/v1beta1
kind: Team
metadata:
  name: frontend-team
spec:
  leader:
    name: frontend-lead
    model: claude-sonnet-4-6
    heartbeat:
      enabled: true
      every: 10m
  workers:
    - name: alice
      model: claude-sonnet-4-6
      skills: [github-operations]
      mcpServers: [github]
    - name: bob
      model: qwen3.5-plus
      runtime: copaw
  peerMentions: true
```

当你 `hiclaw apply` 一个 Team 时，Controller 自动编排以下拓扑：

- **Leader Room**：Manager + Admin + Leader — 委派通道
- **Team Room**：Leader + Admin + Workers — 协作空间（Manager 不在其中）
- **Worker Room**：Leader + Admin + 单个 Worker — 私聊通道

关键设计：**Manager 永远不进入 Team Room**。这创造了一个委派边界——Manager 与 Leader 对话，Leader 协调团队。不会产生瓶颈。

### Human — 面向人的 RBAC

```yaml
apiVersion: hiclaw.io/v1beta1
kind: Human
metadata:
  name: zhangsan
spec:
  displayName: "张三"
  permissionLevel: 2
  accessibleTeams: [frontend-team]
```

三个权限级别（Admin / Team / Worker）控制谁可以和谁对话——通过 `groupAllowFrom` 配置在 Matrix 协议层面强制执行。

---

## 三层组织架构

HiClaw 的架构映射真实的企业团队结构：

```
Admin（人类管理员）
  │
  ├── Manager（AI 协调者，可选部署）
  │     ├── Team Leader A（特殊 Worker，管理团队内任务调度）
  │     │     ├── Worker A1
  │     │     └── Worker A2
  │     ├── Team Leader B
  │     │     └── Worker B1
  │     └── Worker C（独立 Worker，不属于任何 Team）
  │
  └── Human Users（真人用户，按权限级别接入）
        ├── Level 1: 等同 Admin
        ├── Level 2: Team 范围
        └── Level 3: 仅限指定 Worker
```

几个值得关注的设计原则：

- **Team Leader 本质是 Worker**——同样的容器、同样的运行时，只是 SOUL 和 Skills 不同。类似 K8s 中 control plane node 和 worker node 运行相同的 kubelet。
- **Manager 不穿透 Team**——只与 Leader 通信，不直接联系团队内 Worker。随着组织规模扩大，Manager 不会成为瓶颈。
- **通信权限是声明式的**——`groupAllowFrom` 矩阵由 Controller 根据 Team/Human 资源定义自动生成，无需手动配置。

---

## Controller 架构：Reconcile 一切

HiClaw Controller 遵循标准的 Kubernetes Controller 模式：

```
YAML 资源声明
    ↓ hiclaw apply
kine（etcd 兼容层，SQLite 后端）/ 原生 K8s etcd
    ↓ Informer Watch
Controller Runtime
    ↓ Reconcile Loop
┌──────────────────────────────────────────────┐
│  Provisioner（基础设施配置）                    │
│  - Matrix 账号注册 & Room 创建                │
│  - MinIO 用户 & Bucket 配置                   │
│  - Higress Gateway Consumer & Route 配置      │
├──────────────────────────────────────────────┤
│  Deployer（配置部署）                          │
│  - Package 解析（file/http/nacos）            │
│  - openclaw.json 生成                         │
│  - SOUL.md / AGENTS.md / Skills 推送          │
│  - 容器启动 / Pod 创建                         │
├──────────────────────────────────────────────┤
│  Worker Backend 抽象层                         │
│  - Docker Backend（embedded 模式）             │
│  - K8s Backend（incluster 模式）               │
│  - Cloud Backend（云上托管模式）                │
└──────────────────────────────────────────────┘
```

两种部署模式，同一套 Reconciler：

| 模式 | 状态存储 | Worker 运行 | 适用场景 |
|---|---|---|---|
| Embedded | kine + SQLite | Docker 容器 | 开发者本地、小团队 |
| Incluster | K8s 原生 etcd | K8s Pod | 企业级、云上部署 |

Worker Backend 抽象层类似 Kubernetes CRI——编排层不关心 Worker 是以 Docker 容器还是 K8s Pod 运行。

---

## 基于 Matrix 协议的透明通信

大多数多 Agent 系统使用内部 RPC 或消息队列进行 Agent 间通信。问题在于：这是一个黑盒。你看不到 Agent 之间在说什么，也无法在不构建自定义工具的情况下介入。

HiClaw 使用 [Matrix 协议](https://matrix.org/)——一个去中心化的开放 IM 标准——作为通信层：

- **透明**：所有 Agent 间通信发生在 Matrix Room 中，人类可以实时看到一切
- **Human-in-the-Loop 是默认行为**：人类使用同一个 IM 客户端（Element Web、FluffyChat 或任何 Matrix 客户端），@mention 即可介入
- **可审计**：消息天然持久化，开箱即用的完整审计轨迹
- **无供应商锁定**：Matrix 是去中心化开放协议，可自托管、可联邦、可独立运行

协作的实际场景：

```
[Team Room]
Leader: @alice 实现密码强度校验，规则是至少 8 位
Alice:  收到，开始实现...

[Admin 在同一个 Room 中观察到，决定调整]
Admin:  @alice 等一下，密码规则改为至少 12 位，必须包含大小写和特殊字符
Alice:  收到，已更新校验规则
Leader: 好的，我更新一下任务规格
```

没有隐藏的 Agent-to-Agent 调用。每个决策都可见、可介入。

---

## 基于 Higress（CNCF Sandbox）的 LLM/MCP 安全访问

在多 Agent 系统中，凭证管理变得至关重要。如果每个 Worker 都持有真实 API Key，一个被攻破的 Agent 就会暴露一切。

HiClaw 的安全层由 [Higress](https://github.com/alibaba/higress) 提供——一个 **CNCF Sandbox 项目**，基于 Envoy 构建的云原生 AI Gateway，原生支持 LLM 代理、MCP Server 托管和细粒度的消费者鉴权。

### 核心原则：凭证永不下发到 Agent

```
Worker（仅持有 Consumer Token: GatewayKey）
    → Higress AI Gateway
        ├── key-auth WASM 插件验证 Consumer Token
        ├── 检查该 Consumer 是否在目标 Route 的 allowedConsumers 列表中
        ├── 注入真实凭证（API Key / GitHub PAT / OAuth Token）
        └── 代理请求到上游服务
            ├── LLM API（OpenAI / Anthropic / 通义千问 等）
            ├── MCP Server（GitHub / Jira / 自定义 等）
            └── 其他外部服务
```

真实凭证只存在于 Gateway 内部。Agent 只持有一个可吊销的 Consumer Token。即使 Agent 被攻破，攻击者也拿不到任何可复用的凭证。

### LLM 访问安全

Worker 创建时，Controller 自动完成：

1. 生成 32 字节随机 GatewayKey 作为 Worker 的身份凭证
2. 在 Higress 注册 Gateway Consumer（`worker-{name}`），绑定 key-auth BEARER 凭证
3. 将该 Consumer 添加到所有 AI Route 的 `allowedConsumers` 列表

Worker 的 API endpoint 指向 Gateway 地址，而非真实的 LLM Provider 地址。Worker 完全不知道真实 API Key 的存在。

### MCP Server 安全访问

MCP（Model Context Protocol）Server 为 Agent 提供工具调用能力——GitHub 操作、数据库查询等。在多 Agent 场景下，多个 Worker 可能需要访问同一个 GitHub 仓库，但不应该每个 Worker 都持有 GitHub PAT。

HiClaw 通过 Higress 托管的 MCP Server 解决这个问题：

```
Worker 调用 MCP 工具:
    POST https://aigw-local.hiclaw.io/mcp-servers/github/mcp
    Authorization: Bearer {GatewayKey}
        ↓
    Higress Gateway:
        1. 验证 Consumer Token
        2. 检查该 Consumer 是否被授权访问 "github" MCP Server
        3. 注入真实 GitHub PAT
        4. 代理请求到 MCP Server 实现
```

### 细粒度权限控制与动态吊销

| 控制维度 | 实现方式 | 示例 |
|---|---|---|
| Worker 级 LLM 访问 | AI Route 的 allowedConsumers | Worker A 可用 GPT-4，Worker B 只能用 GPT-3.5 |
| Worker 级 MCP 访问 | MCP Server 的 allowedConsumers | Worker A 可访问 GitHub，Worker B 不可以 |
| 动态权限变更 | 修改 allowedConsumers 列表 | Manager 可实时授予/吊销 Worker 的 MCP 访问权 |
| 即时吊销 | 从 allowedConsumers 移除 | 无需轮换凭证，1-2 秒内生效（WASM 插件热同步） |

这个权限模型类似 K8s 中 ServiceAccount + RBAC——Consumer Token 是 ServiceAccount Token，`allowedConsumers` 是 RBAC Policy。

### 为什么选择 Higress

作为 CNCF Sandbox 项目，Higress 带来了：

- **AI-Native Gateway**：原生支持 LLM 代理（多 Provider 路由、Token 限流、Fallback）和 MCP Server 托管——不是通过通用 API Gateway 的插件机制勉强实现
- **WASM 插件体系**：安全插件以 WASM 运行，热更新无需重启，权限变更秒级生效
- **Envoy 内核**：继承 Envoy 的高性能和可观测性，与 CNCF 生态（Prometheus、OpenTelemetry）天然集成

---

## Kubernetes 概念映射

对于 K8s 原生用户，以下是 HiClaw 概念的对应关系：

| Kubernetes | HiClaw | 说明 |
|---|---|---|
| Pod | Worker | 最小调度单元，无状态，可销毁重建 |
| Deployment | Team | 管理一组 Worker 的期望状态 |
| Service | Matrix Room | Worker 间的通信抽象 |
| ServiceAccount + RBAC | Consumer Token + allowedConsumers | 身份认证 + 细粒度权限控制 |
| CRD | Worker/Team/Human/Manager | 声明式资源定义 |
| Controller + Reconcile Loop | hiclaw-controller | 持续将实际状态收敛到期望状态 |
| Ingress / Gateway API | Higress Route（CNCF Sandbox） | LLM/MCP 访问入口 + 凭证注入 |
| NetworkPolicy | allowedConsumers + MCP Server 授权 | Agent 级别的 API 访问控制 |
| CRI | Worker Backend 抽象层 | 可插拔的底层运行时 |
| kubectl apply | hiclaw apply | 声明式资源管理 CLI |

如果你能写 Kubernetes manifest，你就能编排一个 AI Agent 团队。

---

## 与 NVIDIA NemoClaw 的对比

NemoClaw 是 NVIDIA 的开源参考栈，用于在安全的 OpenShell 沙箱中运行 Agent。它在自己的领域做得很好——但解决的是一个根本不同的问题。

| 维度 | NemoClaw | HiClaw |
|---|---|---|
| 核心定位 | 单 Agent 安全沙箱 | 多 Agent 协作编排 |
| Agent 间关系 | 完全隔离，无通信 | 声明式通信权限矩阵，结构化协作 |
| LLM 安全 | OpenShell 拦截推理请求，Agent 不见凭证 | Higress（CNCF）Gateway 代理，Consumer Token 鉴权 |
| MCP Server 安全 | 无集中管理 | Higress 托管 MCP Server，per-Worker 细粒度授权 |
| 动态权限 | 需重建 Sandbox | 修改 allowedConsumers，秒级生效 |
| 共享状态 | 每个 Sandbox 独立 | MinIO 共享文件系统 + 任务状态机 |
| 团队结构 | 无 | Team CRD，声明式定义 |
| Human-in-the-Loop | 仅 CLI 交互 | Matrix Room 实时旁观与介入 |
| 配置模型 | Blueprint YAML（单 Agent） | K8s CRD 风格（Worker/Team/Human/Manager） |

### 互补而非竞争

NemoClaw 和 HiClaw 解决的是 Agent 技术栈中不同层次的问题：

```
┌──────────────────────────────────────────────┐
│  HiClaw（协作编排层）                          │
│  组织结构 / 通信权限 / 任务委派                  │
├──────────────────────────────────────────────┤
│  NemoClaw（安全运行时层）                       │
│  沙箱隔离 / 推理路由                            │
├──────────────────────────────────────────────┤
│  OpenClaw / CoPaw / Hermes（Agent 运行时）     │
│  LLM 交互 / 工具调用 / 技能执行                 │
└──────────────────────────────────────────────┘
```

HiClaw 的 Worker Backend 抽象层使其可以集成 NemoClaw 作为底层运行时——将 NemoClaw 的沙箱安全能力与 HiClaw 的协作编排能力结合。这类似于 Kubernetes 通过 CRI 接口对接不同的容器运行时（containerd、CRI-O）——编排层不关心运行时的具体实现。

---

## 快速开始

**前置条件**：Docker Desktop（Windows/macOS）或 Docker Engine（Linux）。最低 2 CPU + 4 GB RAM。

```bash
bash <(curl -sSL https://higress.ai/hiclaw/install.sh)
```

打开 http://127.0.0.1:18088，登录 Element Web，开始和你的 Manager Agent 对话。就这样——AI Gateway、Matrix 服务器、文件存储、Web 客户端，全部运行在你的机器上。

---

## 未来规划

- **ZeroClaw**：基于 Rust 的超轻量运行时，3.4MB 二进制，<10ms 冷启动
- **NanoClaw**：极简 Agent 运行时，<4000 行代码
- **Team 管理中心**：可视化 Dashboard，实时观察和控制 Agent 团队
- **Incluster Helm Chart**：生产级 K8s 部署
- **NemoClaw 运行时集成**：沙箱安全 + 协作编排的结合

---

## 链接

- GitHub: https://github.com/alibaba/hiclaw
- Discord: https://discord.gg/NVjNA4BAVw
- Higress（CNCF Sandbox）: https://github.com/alibaba/higress
- License: Apache 2.0
