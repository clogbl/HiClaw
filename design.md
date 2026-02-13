# HiClaw 项目初始化设计文档

## 什么是 HiClaw

HiClaw 是一套开箱即用的开源 Agent Teams 系统，可以基于 IM 即时通讯工具实现多 Agent 协同工作管理。基于 IM 可以同时支持多 Agent 自主协同，以及 Human x Agent 的混合协同（Human in the loop）。
这个系统的核心组成如下：
- AI网关：基于 Higress 网关统一提供 LLM、MCP、REST API 接入点，管理多个 Agent 的调用凭证、Token 计量、以及不同 Agent 的权限；同时为 Worker Agent 定时签发临时凭证，确保安全隔离
- Matrix Home Server & Web Client：作为 Agent 间基于 Matrix 协议进行 IM 通信的服务器，并提供开箱即用的 IM 工具
- HTTP 文件系统：基于 MinIO 对象存储，通过 Higress 网关暴露 HTTP 文件系统 API，支持 Manager 与 Worker、Worker 与 Worker 之间基于文件系统的高效通信，长文本内容无需通过 IM 协议传输
- Matrix Bridge：支持通过 Matrix Bridge 接入微信、飞书、钉钉等生态，可以通过这些平台与 Manager Agent 进行对话，并通过 Manager 管理 Workers 工作
- Manager Agent（管家/经理人）：可以基于 Matrix 协议和 Human 通信，可以对接 AI 网关访问 LLM/MCP/REST API。接受 Human 指示管理和分配任务给 Worker Agent，基于 OpenClaw heartbeat 机制定时监控 Workers 的工作进度，同时也可以直接参与工作（可与 Worker 进行对话协作）。当 Workers 数量不足时会主动提示 Human 创建或重置 Worker（并给出对应的创建/重置命令，包含给 Worker 的 SOUL.md 设定）
- Worker Agent（工人）：可以基于 Matrix 协议和其他 Agent 以及 Human 通信，可以对接 AI 网关访问 LLM/MCP/REST API（使用 Manager 签发的临时凭证），并操作本地沙箱工作环境

需要部署的组件以及构成如下：
1. hiclaw-manager-agent 容器：
   - AI 网关（Higress，提供 LLM/MCP/REST API 统一接入点）
   - Matrix Home Server
   - Matrix Web Client
   - Matrix Bridge（微信/飞书/钉钉桥接）
   - MinIO 对象存储（HTTP 文件系统后端）
   - Manager Agent
2. hiclaw-worker-agent 容器：
   - Worker Agent

提供两种工作模式：
1. Manager Agent 模式：仅部署 hiclaw-manager 容器即可，用法上跟 OpenClaw 一致，但提供了开箱即用的 IM 工具、灵活切换模型的 AI 网关、以及 HTTP 文件系统
2. Agent Teams 模式：
   - Manager Agent 作为管家/经理人，负责统一管理 AI 网关、Matrix Home Server、HTTP 文件系统，并承担任务调度和 Worker 管理的职责；Worker Agent 用于执行具体任务
   - Manager Agent 接入 IM，既参与管理工作（接受 Human 命令、分配任务、监控进度），也可以直接参与具体工作（与 Worker 进行对话协作）
   - Manager Agent 仅限真人管理员账号进行直接命令下达，实现核心系统的安全隔离，不会导致 LLM Key 等信息被提示词注入后泄漏
   - Manager Agent 通过 Matrix Bridge 支持微信、飞书、钉钉等平台接入，Human 可以通过这些常用工具与 Manager 交互管理 Workers

第一版组件实现：
- AI网关：基于 [Higress](https://github.com/alibaba/higress) 实现
- Matrix Home Server：基于 [Tuwunel](https://github.com/matrix-construct/tuwunel) 实现
- Matrix Web Client：基于 Element Web 实现
- Matrix Bridge：基于 [mautrix](https://github.com/mautrix) 系列桥接器实现（mautrix-wechat / mautrix-lark / mautrix-dingtalk）
- HTTP 文件系统：基于 [MinIO](https://github.com/minio/minio) 实现，通过 Higress 网关暴露 S3 兼容 API
- Agent：基于 [OpenClaw fork](https://github.com/higress-group/openclaw) 实现

对 OpenClaw fork 改动点如下：
- 弃用原本的 LLM 模型代理相关逻辑，由 AI 网关统一完成 LLM 代理功能（OpenClaw相关代码暂未移除，但实际不使用）
- 定制 SOUL.md，专注在多 Agent 协作场景，做安全性加固，同时优化 Token 开销

## 安全架构设计

### Higress 网关统一接入点

Manager 上的 Higress 网关作为整个系统的统一 API 接入点，同时提供以下三类服务：

1. **LLM 接入点**：代理各大模型厂商的 API（OpenAI、通义千问等），统一使用 OpenAI 兼容协议
2. **MCP 接入点**：代理各类 MCP（Model Context Protocol）工具服务，Agent 可通过网关访问外部工具
3. **REST API 接入点**：代理其他 REST 服务（如 HTTP 文件系统、内部管理 API 等）

网关上统一配置好访问对应上游 API 的凭证（如各 LLM Provider 的 API Key、MCP 服务的认证信息等），Agent 无需直接持有上游凭证。

### 临时凭证机制

为保障安全隔离，Worker Agent 不持有长期有效的 API 凭证，而是由 Manager Agent 定时签发临时凭证：

1. **凭证签发**：Manager Agent 通过调用 Higress Console API 为每个 Worker 创建/轮转 consumer 凭证，设定有效期（例如 24 小时）
2. **凭证下发**：Manager Agent 通过安全通道（Matrix DM 或 HTTP 文件系统的加密文件）将临时凭证下发给 Worker Agent
3. **凭证轮转**：Manager Agent 基于 OpenClaw heartbeat 机制定期检查并轮转即将过期的凭证，确保 Worker 不间断工作
4. **凭证撤销**：当 Worker 被停用或重置时，Manager 立即撤销其凭证，防止凭证泄漏后被滥用

### 权限分级

| 角色 | LLM 访问 | MCP 访问 | REST API 访问 | 凭证有效期 | 管理权限 |
|------|----------|----------|---------------|-----------|---------|
| Human（管理员） | 通过 Manager | 通过 Manager | 通过 Manager | 永久 | 完全控制 |
| Manager Agent | 全部模型 | 全部工具 | 全部 API | 长期 | 管理 Worker、签发凭证 |
| Worker Agent | 指定模型 | 指定工具 | 指定 API | 临时（定时轮转） | 仅操作本地沙箱 |

## HTTP 文件系统通信设计

### 架构概述

通过 Higress 网关暴露基于 MinIO 的 HTTP 文件系统 API，提供 S3 兼容的对象存储服务。所有 Agent（Manager 和 Worker）均可通过 HTTP API 进行文件读写，实现高效的文件级通信。

### 解决的问题

- IM 协议（Matrix）适合短消息通信，但传输长文本（如代码文件、日志、报告等）效率低且容易丢失格式
- Agent 之间需要共享大量工作产物（代码、文档、配置等），文件系统是更自然的载体
- 需要一个统一的、可靠的持久化存储，支持版本管理和并发访问

### 存储结构设计

```
hiclaw-storage/
├── shared/                          # 共享空间（所有 Agent 可读写）
│   ├── tasks/                       # 任务相关文件
│   │   └── {task-id}/              # 按任务组织
│   │       ├── brief.md            # 任务简报
│   │       ├── result.md           # 任务结果
│   │       └── attachments/        # 附件
│   └── knowledge/                   # 共享知识库
├── manager/                         # Manager 专用空间
│   ├── worker-configs/             # Worker 配置和 SOUL.md 模板
│   └── credentials/                # 临时凭证存放（加密）
├── workers/                         # Worker 工作空间
│   └── {worker-name}/             # 每个 Worker 的独立空间
│       ├── workspace/              # 工作目录
│       ├── reports/                # 进度报告
│       └── logs/                   # 工作日志
└── messages/                        # 文件消息通道
    ├── manager-to-{worker}/        # Manager 发给 Worker 的消息
    └── {worker}-to-manager/        # Worker 发给 Manager 的消息
```

### 通信模式

1. **任务下发**：Manager 将详细的任务描述写入 `shared/tasks/{task-id}/brief.md`，然后通过 Matrix IM 发送简短通知给 Worker，Worker 通过 HTTP 文件系统读取完整任务内容
2. **进度汇报**：Worker 将工作进度和产物写入 `workers/{worker-name}/reports/`，Manager 通过 heartbeat 机制定期读取
3. **成果提交**：Worker 将最终成果写入 `shared/tasks/{task-id}/result.md`，并通过 Matrix IM 通知 Manager
4. **Agent 间协作**：Worker 之间可以通过 `shared/` 目录共享文件，通过 `messages/` 目录传递长文本消息

### 接入域名

- 用户填写 HTTP 文件系统域名时，表明用户会自己对这个域名做 DNS 解析；用户未填时，使用默认域名：`fs-local.hiclaw.io`
- 默认域名 `fs-local.hiclaw.io` 会被解析到 `127.0.0.1`，需要提醒用户如果 Manager 和 Worker 不在一台机器上，要自己配置域名解析
- HTTP 文件系统访问地址：`http://fs-local.hiclaw.io:8080`
- 使用与 AI 网关相同的认证机制（Bearer Token），由 Manager 签发的凭证同时包含文件系统访问权限

## Matrix Bridge 生态接入设计

### 架构概述

Manager Agent 通过 Matrix Bridge 桥接微信、飞书、钉钉等国内主流即时通讯平台，使 Human 管理员可以通过日常使用的 IM 工具与 Manager 进行对话，实现对整个 Agent Teams 的管理。

### 桥接架构

```
微信 ──── mautrix-wechat ────┐
                              │
飞书 ──── mautrix-lark ──────├──── Matrix Home Server ──── Manager Agent
                              │
钉钉 ──── mautrix-dingtalk ──┘
                              │
Element Web / FluffyChat ─────┘
```

### 支持的交互方式

1. **微信**：通过 mautrix-wechat 桥接，支持个人微信和企业微信接入。Human 可以在微信中直接与 Manager Agent 对话，下达任务指令
2. **飞书**：通过 mautrix-lark 桥接，支持飞书机器人接入。可以在飞书群组或私聊中与 Manager 交互
3. **钉钉**：通过 mautrix-dingtalk 桥接，支持钉钉机器人接入。可以在钉钉群组或私聊中与 Manager 交互
4. **原生 Matrix 客户端**：Element Web / FluffyChat 等原生客户端始终可用

### 通过外部 IM 管理 Workers 示例

Human 在微信/飞书/钉钉中对 Manager 说：

> "帮我安排 Alice 做前端页面开发，Bob 做后端 API 开发，他们之间需要协调接口定义"

Manager Agent 会：
1. 将前端任务分配给 Alice，后端任务分配给 Bob
2. 在 HTTP 文件系统 `shared/tasks/` 下创建任务文件
3. 通过 Matrix 通知 Alice 和 Bob 各自的任务
4. 创建共享的接口定义文档供两人协调
5. 通过 heartbeat 机制定期检查进度，并通过微信/飞书/钉钉向 Human 汇报

### Bridge 配置

Bridge 的安装和配置集成在 hiclaw-install 脚本中，用户可以选择性启用需要的桥接器：

```bash
# 安装时选择启用的 Bridge
hiclaw-install --bridge wechat    # 启用微信桥接
hiclaw-install --bridge lark      # 启用飞书桥接
hiclaw-install --bridge dingtalk  # 启用钉钉桥接
```

每个 Bridge 需要对应平台的开发者凭证（如飞书/钉钉的 App ID 和 Secret），安装脚本会交互式引导用户配置。

## 用例设计

### Manager Agent 安装和配置

用户通过 hiclaw-install 脚本完成 Manager Agent 的安装和配置。这个脚本通过交互式命令的方式，让用户给出以下信息：
- LLM Provider，默认使用的模型，以及对应的 API Key
- 管理员用户名和密码
- Matrix Homeserver 的域名（选填）
- Matrix Web Client 的域名（选填）
- AI 网关的接入点域名（选填）
- HTTP 文件系统的接入点域名（选填）
- 需要启用的 Matrix Bridge（选填：微信/飞书/钉钉）

用户配置好后，会自动帮用户在 Matrix 服务器里注册好两个账号：
- 真人账号（例如：@johnlanni:matrix-local.hiclaw.io:8080）
- Manager Agent 账号（例如：@manager:matrix-local.hiclaw.io:8080）

提示用户可以打开 Element Web 输入管理员用户名和密码，并将 Manager Agent 账号加入到房间里进行对话管理。

同时也提示用户可以安装其他更易用的 Matrix 客户端，支持在 Windows/Mac/IOS/Android 等系统上使用，例如可以安装 FluffyChat：https://fluffy.chat/en/

如果用户启用了微信/飞书/钉钉桥接，提示用户通过对应的 Bridge 完成绑定后，即可在微信/飞书/钉钉中与 Manager Agent 对话。

#### 实现说明

##### Matrix Homeserver 的域名

- 用户填写这个域名时，表明用户会自己对这个域名做DNS解析；用户未填时，使用默认域名：matrix-local.hiclaw.io；在创建 Higress 的 Matrix Homeserver 相关的路由时，需要配置上这个域名
- 默认域名 matrix-local.hiclaw.io 会被解析到 127.0.0.1，但也需要提醒用户，如果 Manager 和 Worker Agent 不在一台机器上，要自己配置这个域名解析到 Manager Agent 机器所在 IP；后续可以直接使用这个地址作为 Matrix Homeserver 的地址： http://matrix-local.hiclaw.io:8080
- 这个域名要作为 Matrix Homeserver 的地址在配置项中纪录下来，未来接受 Human 指令初始化 Worker Agent 时要给出此配置

##### Matrix Web Client 的域名

- 用户填写这个域名时，表明用户会自己对这个域名做DNS解析；用户未填时，使用默认域名：matrix-client-local.hiclaw.io；在创建 Higress 的 Matrix Web Client 相关的路由时，需要配置上这个域名
- 默认域名 matrix-client-local.hiclaw.io 会被解析到 127.0.0.1，但也需要提醒用户，如果 Manager Agent 和 Worker Agent 不在一台机器上，要自己配置这个域名解析到 Manager Agent 机器所在 IP；后续可以直接使用这个地址作为 Matrix Web Client 的地址： http://matrix-client-local.hiclaw.io:8080
- 这个域名要作为 Matrix Web Client 的地址在配置项中纪录下来

##### AI 网关的域名

- 用户填写这个域名时，表明用户会自己对这个域名做DNS解析；用户未填时，使用默认域名：llm-local.hiclaw.io；在创建 Higress 的 AI 路由时，需要配置上这个域名
- 默认域名 llm-local.hiclaw.io 会被解析到 127.0.0.1，但也需要提醒用户，如果 Manager Agent 和 Worker Agent 不在一台机器上，要自己配置这个域名解析到 Manager Agent 机器所在 IP；后续直接使用这个地址作为 AI 网关的接入点地址： http://llm-local.hiclaw.io:8080
- 这个域名要作为 AI Gateway Endpoint 的地址在配置项中纪录下来，未来接受 Human 指令初始化 Worker Agent 时要给出此配置

##### HTTP 文件系统的域名

- 用户填写这个域名时，表明用户会自己对这个域名做DNS解析；用户未填时，使用默认域名：fs-local.hiclaw.io；在创建 Higress 的文件系统路由时，需要配置上这个域名
- 默认域名 fs-local.hiclaw.io 会被解析到 127.0.0.1，但也需要提醒用户，如果 Manager 和 Worker Agent 不在一台机器上，要自己配置这个域名解析到 Manager Agent 机器所在 IP
- HTTP 文件系统访问地址：http://fs-local.hiclaw.io:8080
- 这个域名要作为 HTTP 文件系统的地址在配置项中记录下来，未来接受 Human 指令初始化 Worker Agent 时要给出此配置

#### Manager Agent 在 OpenClaw 基础上的改动

在 openclaw.json 的配置里需要默认配置好 matrix 的相关配置，此外限制这个 Manager Agent 只能被真人账号和已注册的 Worker Agent 账号访问，例如：
```js
  "channels": {
    "matrix": {
      "enabled": true,
      "homeserver": "http://matrix-local.hiclaw.io:8080",
      "accessToken": "xxxxxxxx",
      "deviceName": "xxxxxxx",
      "groupPolicy": "allowlist",
      "dm": {
        "policy": "allowlist",
        "allowFrom": [
          "@johnlanni:matrix-local.hiclaw.io:8080",
          "@alice:matrix-local.hiclaw.io:8080",
          "@bob:matrix-local.hiclaw.io:8080"
        ]
      },
      "groupAllowFrom": ["@johnlanni:matrix-local.hiclaw.io:8080"],
      "groups": {
        "*": { allow: true }
      }
    }
  }
```

Manager Agent 访问 Higress AI 网关的 API key，需要通过调用 higress console 的 POST /v1/consumers 接口创建，consumer 名称和 Matrix 用户名保持一致（例如: @manager:matrix-local.hiclaw.io:8080）, 使用 key-auth 认证方式，来源选择 BEARER 方式，使用脚本生成的随机生成的安全系数高的 Key。

根据用户配置的模型，在 openclaw.json 的配置里需要配置好模型相关的配置，举例来说：

```js
  "models": {
    "mode": "merge",
    "providers": {
      "bailian": {
        "baseUrl": "http://llm-local.hiclaw.io:8080/v1",
        "apiKey": "YOUR_API_KEY",
        "api": "openai-completions",
        "models": [
          {
            "id": "qwen3-max-2026-01-23",
            "name": "qwen3-max-thinking",
            "reasoning": false,
            "input": [
              "text"
            ],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "contextWindow": 262144,
            "maxTokens": 65536
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "bailian/qwen3-max-2026-01-23"
      },
      "models": {
        "bailian/qwen3-max-2026-01-23": {
          "alias": "qwen3-max-thinking"
        }
      },
      "maxConcurrent": 4,
      "subagents": {
        "maxConcurrent": 8
      },
      "heartbeat": {
        "every": "15m",
        "prompt": "Read HEARTBEAT.md. Check all worker agents' status reports in the HTTP filesystem (workers/*/reports/). If any worker is stuck, behind schedule, or has completed their task, take appropriate action. If worker capacity is insufficient for pending tasks, notify the human administrator with specific create/reset commands. Reply HEARTBEAT_OK if nothing needs attention."
      }
    }
  },
```

此外，需要给这个 Manager Agent 的 OpenClaw 预置好以下 Skill：

1. **管理 AI 网关的 Skill**：通过访问 AI 网关的 console api 来实现管控，console 的地址为：http://127.0.0.1:8001, 使用 basic-auth 进行认证，前面已经说过，用户名和密码就是管理员用户名和密码；api 文档参考当前目录下 higress-console-api.yaml
2. **管理 Matrix Server 的 Skill**：管理 Worker 账号的创建、Token 获取等
3. **管理 HTTP 文件系统的 Skill**：通过 S3 兼容 API 管理 MinIO 中的文件存储，包括创建 Bucket、管理文件、设置访问策略等
4. **Worker 管理 Skill**：管理 Worker 生命周期，包括：
   - 创建新 Worker：生成 SOUL.md 设定、创建 Matrix 账号、签发临时凭证、生成安装命令
   - 重置 Worker：重新签发凭证、更新 SOUL.md、清理工作空间
   - 监控 Worker：通过 heartbeat 机制定期检查 Worker 状态，读取 HTTP 文件系统中的进度报告
   - 任务分配：接受 Human 命令后，将任务拆解并分配给合适的 Worker
5. **临时凭证管理 Skill**：定时为 Worker 签发和轮转临时凭证（LLM/MCP/REST API/HTTP 文件系统访问凭证），通过 Higress Console API 创建带过期时间的 consumer

#### Manager Agent 的 HEARTBEAT.md 模板

```markdown
## Manager Heartbeat Checklist

### 1. Worker Status Check
- Read each worker's latest report from HTTP filesystem: workers/{worker-name}/reports/
- Check if any worker has been idle or unresponsive for too long
- Check if any worker has reported errors or is stuck

### 2. Credential Rotation
- Check all worker temporary credentials expiration
- Rotate credentials that will expire within the next 2 hours
- Deliver new credentials via secure channel

### 3. Task Progress
- Review task progress in shared/tasks/*/
- Identify completed, in-progress, and blocked tasks
- Report summary to human if significant changes occurred

### 4. Capacity Assessment
- Count active workers vs pending tasks
- If workers are insufficient, prepare create/reset commands for human:
  - hiclaw-install worker --name {name} --matrix-server {server} --gateway {gateway}
- If workers are idle, suggest task reassignment

### 5. Reply
- If nothing needs attention: HEARTBEAT_OK
- Otherwise: summarize findings and recommended actions
```

### Worker Agent 安装和配置

在完成服务端安装和配置后，可以在 Matrix 客户端里（或通过微信/飞书/钉钉）跟 Manager Agent 进行对话来对 Worker Agent 进行初始化，同时给出一键安装命令。

例如用户可以这样说："我需要增加一个 Agent 员工，名字叫做 Alice，负责前端开发工作"

Manager Agent 的答复中会包含以下信息：
- 这个 Alice 账号的 Matrix 用户名和密码，用户名需要英文小写，密码是用脚本生成的随机生成的安全系数高的密码
- Manager 会为 Alice 生成专属的 SOUL.md 设定，包含其角色定位（如"前端开发工程师"）、工作范围、协作规则等
- 一行安装命令，是使用 hiclaw-install 脚本来完成这个 Worker Agent 安装的，这个命令需要给出以下参数：
  1. Agent 的名字
  2. 给 OpenClaw 集成这个 Alice 账号用的 matrix token
  3. Matrix Homeserver 的地址
  4. Higress AI 网关的接入地址和临时 API Key（由 Manager 签发）
  5. HTTP 文件系统的接入地址
  6. Worker 的 SOUL.md 设定内容（通过 base64 编码传入或从 HTTP 文件系统下载）

提示用户，这个 Bot 的账号密码可以保留好，不要泄漏，一般情况下也无需登录 Bot 的账号，后续安装流程不依赖这个用户名和密码。

用户主要使用这个安装命令，在一台可以和 Server 所在网络联通的机器上完成 Worker Agent 安装。
并在用户执行完这个安装命令后，提醒用户 "Alice 已经完成初始化，可以通过 Element Web 搜索账号：@alice:matrix-local.hiclaw.io:8080 ，加入到房间中指派任务"

#### Worker Agent 重置

当 Worker 出现问题（如凭证过期且无法自动轮转、工作空间损坏等），Manager 会主动提示 Human 进行重置，并给出重置命令：

```bash
hiclaw-install worker --reset --name alice \
  --matrix-server http://matrix-local.hiclaw.io:8080 \
  --gateway http://llm-local.hiclaw.io:8080 \
  --fs http://fs-local.hiclaw.io:8080 \
  --soul "base64-encoded-soul-md-content"
```

重置会：
1. 撤销旧的临时凭证
2. 签发新的临时凭证
3. 更新 SOUL.md 设定
4. 清理 HTTP 文件系统中的工作空间（可选保留历史）

#### 实现说明

##### matrix token 获取方式

matrix token 按以下方式请求基于 Higress 路由的 matrix server 获取：
  ```bash
        curl --request POST \
        --url http://127.0.0.1:8080/_matrix/client/v3/login \
        --header 'Content-Type: application/json' \
        --data '{
          "type": "m.login.password",
          "identifier": {
            "type": "m.id.user",
            "user": "alice"
          },
          "password": "xxxxxx"
        }'
  ```
返回内容如下，取里面的 access_token 字段：
  ```bash
  {"user_id":"@alice:matrix-local.hiclaw.io:8080","access_token":"xxxxxxxx","home_server":"matrix-local.hiclaw.io:8080","device_id":"VW1Hmtf7UB"}
  ```

##### Higress AI 网关的临时凭证

分配给 Worker Agent 的 API key，由 Manager Agent 通过调用 Higress Console 的 POST /v1/consumers 接口创建，具体机制如下：
- consumer 名称和 Matrix 用户名保持一致（例如: @alice:matrix-local.hiclaw.io:8080）
- 使用 key-auth 认证方式，来源选择 BEARER 方式
- Key 使用脚本生成的随机安全高强度字符串
- Manager Agent 在每次 heartbeat 时检查凭证有效期，在过期前主动轮转：
  1. 通过 Higress Console API 创建新 consumer 凭证
  2. 通过 Matrix DM 或 HTTP 文件系统安全通道通知 Worker 更新凭证
  3. 确认 Worker 已切换到新凭证后，撤销旧凭证

### Manager 管理 Workers 的工作机制

#### 任务分配流程

1. **接收命令**：Manager 通过 Matrix（或微信/飞书/钉钉 Bridge）接收 Human 的任务指令
2. **任务拆解**：Manager 分析任务，拆解为可分配给不同 Worker 的子任务
3. **任务下发**：
   - 将详细任务描述写入 HTTP 文件系统 `shared/tasks/{task-id}/brief.md`
   - 通过 Matrix DM 向对应 Worker 发送简短任务通知和文件系统中的任务路径
4. **进度监控**：基于 OpenClaw heartbeat 机制（默认每 15 分钟），Manager 自动：
   - 检查各 Worker 在 HTTP 文件系统中提交的进度报告
   - 检查 Worker 的 Matrix 在线状态
   - 评估任务完成度和是否存在阻塞
5. **动态调度**：
   - 如果 Worker 被阻塞，Manager 可以直接与 Worker 对话协助解决
   - 如果 Worker 数量不足，Manager 向 Human 建议创建新 Worker 并给出命令
   - 如果 Worker 空闲，Manager 可以重新分配任务

#### 容量不足提示示例

当 Manager 通过 heartbeat 检测到 Worker 容量不足时，会通过 Matrix（或桥接的微信/飞书/钉钉）通知 Human：

> 当前有 3 个待处理任务但只有 1 个空闲 Worker。建议创建新的 Worker Agent：
>
> ```bash
> # 创建一个专注后端开发的 Worker
> hiclaw-install worker --name charlie \
>   --matrix-server http://matrix-local.hiclaw.io:8080 \
>   --gateway http://llm-local.hiclaw.io:8080 \
>   --fs http://fs-local.hiclaw.io:8080 \
>   --role "后端开发工程师"
> ```
>
> 或者重置一个已停滞的 Worker：
>
> ```bash
> hiclaw-install worker --reset --name bob \
>   --matrix-server http://matrix-local.hiclaw.io:8080 \
>   --gateway http://llm-local.hiclaw.io:8080 \
>   --fs http://fs-local.hiclaw.io:8080
> ```

### Agent 自主协作

Agent 之间的自主协作通过以下方式实现：

1. **IM 通信**：通过 Matrix 协议进行实时短消息通信（任务通知、状态同步、问题讨论等）
2. **文件协作**：通过 HTTP 文件系统共享代码、文档、配置等大量内容
3. **Manager 协调**：Manager Agent 作为协调中心，通过 heartbeat 机制定期检查全局状态，确保各 Worker 之间的工作衔接
4. **Worker 间直接通信**：Worker Agent 之间也可以通过 Matrix 直接通信，以及通过 HTTP 文件系统的 `messages/` 目录进行长文本交换，无需所有通信都经过 Manager
