# hi-im-档C技术方案设计

> **定位**：必嗨 IM 原栈作者不再维护；以 **hi-im** 为新项目名，**hi-im-core**（C++17/20）重写 RTMQ Hub 并做架构升级，Go 业务层独立仓库迭代，**Gin + gRPC** 替换 beego + Thrift。  
> **档 C 范围**：Hub 分片 + 可观测 + io_uring 可选 + Kafka 削峰（方向二）+ K8s 部署。  
> **版本**：v0.4-draft · 2026-06-25  
> **主仓**：本文档 canonical 副本位于 **[hi-im](https://github.com/sunchao1/hi-im)**（编排、文档、Compose/K8s）；原稿中的 `hi-im-deploy` 已统一为本仓库名 **`hi-im`**。  
> **许可证**：[Apache License 2.0](../LICENSE)

---

## 1. 背景与目标

### 1.1 为什么要另起项目

| 问题 | 现状 | hi-im 目标 |
|------|------|------------|
| 维护主体 | 必嗨原 C 栈（2014～2017）无人续维护 | 你主导的开源/产品化迭代 |
| 语言与工程 | C + 手动内存、无单测、Hub 单点 | C++17/20、RAII、单测、Prometheus |
| Go 业务栈 | beego + GOPATH + mgo + Thrift | **Go module + Gin + gRPC + mongo-driver** |
| 扩展 | frwder 盲 replicas 会丢包 | **Hub 按 NID 分片**、Ingress 固定入口 |
| 削峰 | chatroom 同步 fan-out | **Kafka + roomfanout**（可选热路径旁路） |

### 1.2 设计目标（档 C）

| 维度 | 指标 |
|------|------|
| **兼容** | hi-im bus wire v1 与必嗨 RTMQ **二进制兼容**（20 字节头 + payload）；现有 Go Demo 可渐进迁移 |
| **性能** | 不低于现网 bench：**publish ≥ 14 万 msg/s**（256B、单机、无持久化）；P99 转发延迟可控 |
| **扩展** | Hub **M 分片**；websocket **无脑水平扩**；msgsvr/chatroom SUB 策略可配置 |
| **可观测** | Prometheus metrics + 结构化日志；Hub 队列深度、SUB 数、nid 连接数可告警 |
| **RPC** | 业务 **冷路径** 统一 **gRPC**；**热路径 IM 帧** 仍走 hi-im 总线（不用 gRPC 替代每一包聊天） |

### 1.3 非目标（Non-Goals）

- hi-im-core **不**理解群/好友/会话语义；只认 `cmd/type` + `nid`。
- hi-im-core **不**持久化、不替代 Kafka 做日志型 MQ。
- 第一期 **不**重写 listend（C TCP 接入可后续单独 C++ 或弃用，以 Go websocket 为主）。

---

## 2. 必嗨原栈澄清：什么不是 gRPC

很多人会把「进程间通信」统称 RPC；必嗨里实际是 **三套通道**：

| 通道 | 技术 | 用途 | 是否 gRPC |
|------|------|------|-----------|
| **IM 热路径** | 自研 **RTMQ**（TCP + 20B 头） | 客户端上行/下行在进程间转发：`publish` / `async_send(nid)` | **否** |
| **ID 发号** | **Apache Thrift** | seqsvr：`AllocSid` / `AllocRid` / `AllocSeq` | **否**（新栈改 **gRPC**） |
| **对外 HTTP** | **beego** Router | 注册、iplist、管理接口 | **否**（新栈改 **Gin**） |

```text
浏览器 ──WS──► gateway ──hi-im-hubclient──► Hub FORWARD
                              │
                              ▼ publish(cmd)
                         msgsvr / chatroom / usrsvr
                              │
                              ▼ async_send(nid)
                         Hub FORWARD ──► websocket ──► 浏览器

usrsvr ──gRPC──► seqsvr          （冷路径，毫秒级，QPS 低）
客户端 ──HTTP──► usrsvr / Gin    （注册、配置）
```

**结论**：

- **hi-im-core** 替代的是 **RTMQ + frwder Hub**，不是 gRPC。
- **gRPC** 用于 **seqsvr、服务间管理/查询、可选 Hub 控制面**；**不**用于每条群聊/弹幕转发（延迟与开销不合适）。

---

## 3. 总体架构

### 3.1 逻辑分层

```mermaid
flowchart TB
  subgraph client["客户端"]
    APP[Web / App]
  end

  subgraph edge["接入层 · Go 独立仓库"]
    ING[Ingress / 固定 wss URL]
    WS[hi-im-gateway<br/>Gin + WS<br/>内嵌 hubclient]
  end

  subgraph core["hi-im-core · C++ 独立仓库"]
    subgraph shard0["Hub Shard-0"]
      F0[FORWARD :28888]
      BR0[bridge]
      B0[BACKEND :28889]
    end
    subgraph shard1["Hub Shard-1"]
      F1[FORWARD :28888]
      BR1[bridge]
      B1[BACKEND :28889]
    end
  end

  subgraph biz["业务层 · Go 多仓库"]
    USR[hi-im-usrsvr]
    MSG[hi-im-msgsvr]
    CR[hi-im-chatroom]
    RF[hi-im-roomfanout]
  end

  subgraph rpc["冷路径 gRPC"]
    SEQ[hi-im-seqsvr]
  end

  subgraph stream["削峰 · 可选"]
    KF[Kafka im.room / im.group]
  end

  subgraph store["状态"]
    RD[(Redis)]
    MY[(MySQL / Mongo)]
  end

  APP --> ING --> WS
  WS <-->|bus wire v1 TCP| F0
  WS -.->|NID 分片| F1
  F0 --- BR0 --- B0
  F1 --- BR1 --- B1
  B0 --> USR & MSG & CR
  CR --> RD
  CR -.-> KF --> RF
  RF -->|async_send| B0
  USR --> SEQ
  CR --> SEQ
  USR & MSG & CR --> RD & MY
```

### 3.2 与必嗨组件映射

| 必嗨 | 新栈（hi-im） | 仓库 |
|------|---------------|------|
| RTMQ Server + frwder | **hi-im-core Hub + bridge** | `hi-im-core` |
| RTMQ C Proxy | hi-im-core C++ Proxy（listend 如需） | `hi-im-core` |
| RTMQ Go Proxy（进程内客户端库） | **hi-im-hubclient** | 独立 Go module，**不独立部署** |
| websocket | **hi-im-gateway** | 独立 |
| usrsvr / msgsvr / chatroom | 各独立仓库 | `hi-im-*` |
| seqsvr (Thrift) | **hi-im-seqsvr (gRPC)** | 独立 |
| tasker / monitor | hi-im-tasker / hi-im-monitor | 独立 |
| roomfanout（方向二新增） | **hi-im-roomfanout** | 独立 |

---

## 4. 仓库与项目划分

建议 **1 个 C++ 核心 + 1 个 Go 公共库 + N 个 Go 微服务仓库**（便于单独发版、面试叙事清晰）。

### 4.1 仓库清单

| 仓库 | 语言 | 职责 |
|------|------|------|
| **`hi-im-core`** | C++17/20 | Hub Server、bridge、C++ Proxy SDK、bench、Prometheus exporter |
| **`hi-im-hubclient`** | Go | **Hub 客户端库**（必嗨 RTMQ Proxy 等价物）；编译进各 Go 进程；纯 Go 实现 bus wire v1 |
| **`hi-im-api`** | Go + protobuf | **内部契约**：48B 头、IM cmd 常量、gRPC `.proto`、Redis 键规范；**不独立部署** |
| **`hi-im-gateway`** | Go + Gin | WebSocket 接入、ChatTab、内嵌 hubclient、健康检查 |
| **`hi-im-usrsvr`** | Go + Gin | 注册、鉴权、Redis 在线；gRPC 调 seqsvr |
| **`hi-im-msgsvr`** | Go + Gin | 私聊、群聊 fan-out 第一段 |
| **`hi-im-chatroom`** | Go + Gin | 聊天室、rid→nid；可选写 Kafka |
| **`hi-im-roomfanout`** | Go | Kafka consumer → Redis rid→nid → hubclient AsyncSend |
| **`hi-im-seqsvr`** | Go + gRPC | 替代 Thrift 的 SID/RID/SEQ |
| **`hi-im-tasker`** | Go | TTL、统计 |
| **`hi-im`** | YAML / Helm / 文档 | **主仓**：Compose、K8s、Ingress、版本矩阵、生态文档 |

> Go module 路径：`github.com/sunchao1/hi-im-api`、`github.com/sunchao1/hi-im-hubclient` 等，与仓库名一致。

### 4.2 依赖关系

```text
hi-im-api        ◄────  所有 Go 服务 + hi-im-hubclient
hi-im-hubclient  ◄──  gateway / usrsvr / msgsvr / chatroom / roomfanout
hi-im-core       ◄──  hi-im 主仓编排；Go 服务运行时 TCP 连 Hub，不 CGO 编译 core
```

**原则**：Go 服务 **不 CGO 依赖 hi-im-core**；`hi-im-hubclient` 纯 Go 连 Hub TCP，与 C++ Hub 对接。

### 4.3 架构分层（L1～L4）

```text
┌─────────────────────────────────────────────────────────────┐
│ L4 对外集成（未来可选，本档 C 不实现）                          │
│     hi-im-sdk-go / 开放 HTTP·gRPC · 移动端 SDK                 │
│     「我要 IM 能力」→ 调 usrsvr/msgsvr 或 WS，不直连 Hub       │
├─────────────────────────────────────────────────────────────┤
│ L3 业务服务（独立部署 · 各自 Git 仓库）                         │
│     gateway / usrsvr / msgsvr / chatroom / seqsvr / tasker …  │
│     群聊 fan-out、注册、聊天室、发号                           │
├─────────────────────────────────────────────────────────────┤
│ L2 内部 Go 库（不独立部署 · go get 依赖）                       │
│     hi-im-api（契约） + hi-im-hubclient（Hub 客户端）           │
│     仅 L3 进程编译进去；**不是**对外「接入 SDK」                │
├─────────────────────────────────────────────────────────────┤
│ L1 基础设施（独立部署 · C++）                                   │
│     hi-im-core（hi-im-hub） publish / async_send / SUB       │
└─────────────────────────────────────────────────────────────┘
```

| 层级 | 仓库 | 独立部署？ | 谁用 |
|------|------|------------|------|
| L1 | hi-im-core | ✅ Pod/进程 | 全栈运行时 |
| L2 | hi-im-api | ❌ Go module | 所有 Go 服务 + hubclient |
| L2 | hi-im-hubclient | ❌ Go module | gateway / msgsvr / chatroom / usrsvr / roomfanout |
| L3 | hi-im-gateway 等 | ✅ 各服务 Pod | 平台自身 |
| L4 | （未来）hi-im-sdk-go | ❌ 库，但 **面向外部业务** | 二开 / SaaS 集成方 |

> **命名约定**：必嗨文献中的 **RTMQ Proxy** = 本方案的 **hi-im-hubclient**（Hub 客户端），**不是** GoF 设计模式里的 Proxy，也 **不是** 给外部业务用的 hi-im-sdk-go。

### 4.4 独立部署 vs 独立仓库

**11 个 Git 仓库 ≠ 11 个运行时 Pod。**

| 类型 | 仓库 | 运行时 |
|------|------|--------|
| **要部署** | hi-im-core | `hi-im-hub` × shard |
| **要部署** | hi-im-gateway, usrsvr, msgsvr, chatroom, seqsvr, tasker, roomfanout | 各 1～N 副本 |
| **只依赖** | hi-im-api, hi-im-hubclient | 编译进上述 Go 二进制 |
| **只编排** | hi-im（本仓库） | Compose / Helm YAML、文档、冒烟脚本 |

最小 **群聊可跑**（生态 M6）需起的进程：

```text
hi-im-hub + Redis + hi-im-seqsvr + hi-im-usrsvr + hi-im-msgsvr + hi-im-gateway
（每个 Go 镜像内已编入 hi-im-api + hi-im-hubclient）
```

### 4.5 hi-im-api 与 hi-im-hubclient 分工

对应必嗨 **`lib/comm` + `lib/mesg`** 与 **`lib/rtmq`**，但职责拆开：

| | **hi-im-api** | **hi-im-hubclient** |
|--|---------------|---------------------|
| **是什么** | 协议字典、数据结构、proto | 连 Hub 的 TCP 客户端库 |
| **典型内容** | `CMD_*`、`MesgHeader` 48B、Redis key、gRPC proto | AUTH、SUB、AsyncSend、RegisterHandler、重连、保活 |
| **必嗨等价** | `lib/comm`、`lib/mesg` | `lib/rtmq`（Go 部分） |
| **变更频率** | 有 **新 cmd / 新 proto / 新 key** 时 | **很少**（除非 bus wire v2、多 shard 连接） |
| **发版** | semver，谁用新 cmd 谁 `go get` 升 | 稳定版，与业务发版解耦 |

**hubclient 应保持很薄**，不包含群逻辑、fan-out、Redis：

```go
// hubclient 只提供传输原语（示意）
hubclient.AsyncSend(cmd, destNid, payload []byte)
hubclient.RegisterHandler(cmd, func(payload []byte))
```

业务在 **msgsvr / chatroom** 里：`import hi-im-api` 拼包 → `hubclient.AsyncSend`。

### 4.6 业务迭代时「谁改什么」（变更归属）

| 场景 | hi-im-api | hi-im-hubclient | msgsvr/chatroom/… | hi-im-core |
|------|-----------|-----------------|-------------------|------------|
| 新业务 cmd（如房间礼物） | ✅ 加 CMD + proto | ❌ 通常不改 | ✅ handler + 业务 | ❌ |
| gateway SUB 新 cmd | ✅ 常量 | ❌（配置 SUB 列表） | ✅ | ❌ |
| 群聊 fan-out 策略调整 | 可能 Redis key | ❌ | ✅ | ❌ |
| bus wire **v2** | ✅ | ✅ | 随 api 升 | ✅ |
| 客户端连多 Hub shard | 可能配置 struct | ✅ | 配置 | ✅ |
| chatroom 加 Kafka 削峰 | ❌ | ❌ | ✅ + roomfanout | ❌ |

**结论**：usrsvr / msgsvr / chatroom **各自迭代业务**，不应迫使 hubclient 跟着改；若每次加功能都要改 hubclient，说明 **业务代码渗进了传输层**，需回退边界。

**独立仓库仍合理**：api 与 hubclient 都是 **`go get` 依赖**，不增加 Pod；分开便于 **api 常发版、hubclient 少发版**。

### 4.7 与「对外 SDK」的边界

| 名称 | 定位 | 本档 C |
|------|------|--------|
| **hi-im-api + hi-im-hubclient** | IM **团队内部**写 L3 服务用 | ✅ M2 起 |
| **hi-im-sdk-go**（未来） | 外部业务「接入 IM 能力」：`SendGroupMessage` 等，走 HTTP/gRPC/WS | ❌ 不做；不与此二者混名 |

---

## 5. hi-im-core 设计（C++）

### 5.1 命名与版本

| 项 | 说明 |
|----|------|
| 项目名 | **hi-im**（生态名）；C++ Hub 仓库 **hi-im-core** |
| 线协议 | **hi-im bus wire v1** = 与 RTMQ 二进制兼容 |
| 扩展 | **hi-im bus wire v2**（可选）：增加 shard_id、trace_id 字段，通过 flag 协商 |

### 5.2 进程模型（单 Shard）

每个 **Hub 进程** 内仍保持双平面（与必嗨一致）：

| 平面 | 默认端口 | 连接方 |
|------|----------|--------|
| **FORWARD** | 28888 | gateway、listend（hubclient） |
| **BACKEND** | 28889 | usrsvr、msgsvr、chatroom、roomfanout |

**bridge** 模块（替代 `frwd_mesg.c`）：

```text
FORWARD 收到业务帧  →  Hub.publish(BACKEND, cmd, payload)
BACKEND 收到下行帧  →  Hub.async_send(FORWARD, cmd, dest_nid, payload)
```

### 5.3 线程 / IO 模型（档 C 升级）

| 模块 | v1 对齐 | 档 C 升级 |
|------|---------|-----------|
| listen | accept → connq | 同左 + SO_REUSEPORT 多 listen（可选） |
| rsvr × N | epoll 收发包、snap 拼帧 | epoll 或 **io_uring**（编译开关 `HIIM_USE_URING`） |
| dist × 1 | nid → rsvr 投递 | 同左 + 分片路由表 |
| worker × M | 业务回调 / bridge | 同左 |
| 队列 | pipe + 有锁队列 | **SPSC 无锁环** + 内存池（`std::vector` 预分配） |
| 发送 | writev 批量 | 同左 + 发送 coalesce |

### 5.4 Hub 分片（档 C 核心）

**问题**：多 Pod frwder + Service LB → nid 注册与 async_send 跨 Pod 丢包。

**方案：按接入 NID 范围分片**

```text
Shard-0: NID ∈ [20001, 20100]  →  hi-im-hub-0:28888/28889
Shard-1: NID ∈ [20101, 20200]  →  hi-im-hub-1:28888/28889
```

| 角色 | 规则 |
|------|------|
| **gateway** | 启动时 `--shard-id=0 --nid=20001`；只连 **本 shard** Hub |
| **msgsvr / chatroom** | 可连 **任意 shard BACKEND**（multi-backend 配置） |
| **async_send(nid)** | Hub 若 nid 不属于本 shard，**转发至 owner shard**（Hub 间 gRPC 或 TCP 内部链路，Phase 2） |

**Phase 1（简化）**：单 Shard 跑通 + bench 对齐；**Phase 2** 多 Shard + 跨 shard 转发。

### 5.5 对外 API（C++ Proxy SDK）

与 RTMQ 对齐，命名空间 `hiim::`：

```cpp
// 业务线程调用（线程安全，内部入队）
Status Proxy::AsyncSend(uint32_t cmd, uint32_t dest_nid,
                        const uint8_t* data, size_t len);
Status Proxy::Publish(uint32_t cmd, const uint8_t* data, size_t len); // Server 侧 bridge 用

// 注册下行 handler
void Proxy::RegisterHandler(uint32_t cmd, MessageHandler handler);
```

Go 侧 **`hi-im-hubclient`** 提供等价 API（包名示例 `hubclient`）：

```go
func (c *Client) AsyncSend(cmd, destNid uint32, payload []byte) error
func (c *Client) RegisterHandler(cmd uint32, h Handler)
```

### 5.6 可观测

| 指标 | 说明 |
|------|------|
| `hiim_connections` | 按平面、shard 的连接数 |
| `hiim_subscriptions` | 按 cmd 的 SUB 数 |
| `hiim_publish_total` | publish QPS |
| `hiim_async_send_total` | async_send QPS |
| `hiim_queue_depth` | sendq/recvq 深度 |
| `hiim_drop_total` | 背压丢弃 |
| `hiim_forward_latency_us` | 转发耗时 histogram |

暴露：`/metrics` HTTP（Prometheus）+ 结构化 JSON 日志（spdlog）。

### 5.7 目录结构（`hi-im-core` 仓库）

```text
hi-im-core/
├── CMakeLists.txt
├── include/hiim/
│   ├── wire/header.hpp      # 20B 头，v1 兼容
│   ├── hub/context.hpp
│   └── proxy/proxy.hpp
├── src/
│   ├── wire/
│   ├── hub/
│   │   ├── listener.cpp
│   │   ├── reactor.cpp      # epoll / uring
│   │   ├── router.cpp       # sub + nid map
│   │   ├── distributor.cpp
│   │   └── bridge.cpp
│   └── proxy/
├── cmd/
│   ├── hi-im-hub/           # Hub 主程序
│   └── hi-im-bench/         # 对齐 rtmq-bench
├── test/                    # 协议单测、路由单测
└── docs/
```

---

## 6. gRPC 设计边界

### 6.1 必须用 gRPC 的场景

| 服务 | API 示例 | 替代 |
|------|----------|------|
| **hi-im-seqsvr** | `AllocSid`, `AllocRid`, `AllocGid`, `AllocSeq` | Thrift |
| **hi-im-usrsvr → seqsvr** | 注册时取 sid | Thrift client |
| **Hub 控制面（Phase 2）** | `RegisterShard`, `HealthCheck`, `DumpRoute` | 原无 |
| **roomfanout 配置** | 动态 rid 黑名单 | 可选 |

### 6.2 不用 gRPC 的场景

| 场景 | 原因 | 方案 |
|------|------|------|
| 群聊/弹幕/私聊每一包 | 延迟、吞吐、长连接无关 | **hi-im async_send / publish** |
| websocket → msgsvr 上行 | 已是 IM 二进制帧 | hi-im bus |
| Kafka → 客户端最后一跳 | 需 nid 精确投递 | hi-im async_send |

### 6.3 proto 示例（seqsvr）

```protobuf
syntax = "proto3";
package hi.im.seq.v1;

service SeqService {
  rpc AllocSid(AllocSidRequest) returns (AllocSidResponse);
  rpc AllocRid(AllocRidRequest) returns (AllocRidResponse);
  rpc AllocSeq(AllocSeqRequest) returns (AllocSeqResponse);
}
```

---

## 7. Go 业务服务（Gin + hi-im-hubclient）

### 7.1 框架迁移

| 项 | 必嗨 | 新栈 |
|----|------|------|
| HTTP | beego | **Gin** |
| 日志 | beego/logs | **zap** 或 slog |
| Mongo | mgo | **mongo-driver** |
| Redis | redigo | redigo 或 go-redis |
| 模块 | GOPATH + vendor | **Go 1.22+ module** |

### 7.2 单服务结构（以 gateway 为例）

```text
hi-im-gateway/
├── cmd/gateway/main.go
├── internal/
│   ├── ws/              # WebSocket 读写的协程
│   ├── chattab/         # rid/gid → cid（从 beehive 迁移）
│   ├── bus/             # 封装 hi-im-hubclient
│   └── http/            # Gin：/health, /metrics, /debug
├── config/
└── go.mod               # require hi-im-api, hi-im-hubclient
```

### 7.3 连接配置（环境变量）

```bash
HIIM_FORWARD_ADDR=hi-im-hub-0:28888
HIIM_BACKEND_ADDR=hi-im-hub-0:28889   # 业务进程用
HIIM_NID=20001                         # 本进程唯一
HIIM_SHARD_ID=0
HIIM_AUTH_USER=websocket
HIIM_AUTH_PASS=***
```

### 7.4 SUB 策略（msgsvr / chatroom）

| cmd | 建议 SUB 数 | 说明 |
|-----|-------------|------|
| GROUP-CHAT | **1**（或 Kafka 分片后 0 SUB） | 避免 publish 广播重复消费 |
| ROOM-CHAT | **1** | 同上 |
| ONLINE / 生命周期 | 1 或按 shard | usrsvr 可单活 |

配置化：`HIIM_SUB_MODE=single|broadcast` + `HIIM_SUB_OWNER=pod-name`。

---

## 8. 协议与迁移策略

### 8.1 保持不变

| 协议 | 说明 |
|------|------|
| **IM 48 字节头 + Protobuf 体** | 客户端协议不变 |
| **hi-im bus wire v1（20 字节头）** | 与 RTMQ 兼容，便于对照必嗨文档 |

### 8.2 迁移路径

```text
Stage 0  文档 + hi-im-bench 对齐 14 万/s
Stage 1  hi-im-hub 单 Shard 替换 compose 里 frwder（Hub 层）
Stage 2  hi-im-hubclient 连 Hub：publish / unicast 集成测试（测试桩，非群聊）
Stage 3  hi-im-seqsvr + usrsvr：注册 / ONLINE
Stage 4  hi-im-gateway：WS 接入 + 连 usrsvr
Stage 5  hi-im-msgsvr：群聊 gid→nid 第一段 fan-out → 双窗口群聊冒烟
Stage 6  hi-im-chatroom + hi-im-tasker
Stage 7  Hub 分片 + hi-im K8s
Stage 8  hi-im-roomfanout + Kafka
```

> **注意**：「双窗口群聊互通」至少依赖 **core + hubclient + api + hi-im（Compose）+ gateway + usrsvr + msgsvr + seqsvr + Redis**，不可能在仅有 gateway 的 Stage 4 之前完成。

### 8.3 兼容期双跑（可选）

Compose 内 **`frwder` + `hi-im-hub`** 不同端口；部分 Go 进程切到 hi-im Hub 地址，逐步切流。

---

## 9. Kafka 与 roomfanout（方向二）

| 项 | 设计 |
|----|------|
| Topic | `im.room`（key=rid）、`im.group`（key=gid） |
| 生产者 | chatroom 峰值时异步写 Kafka |
| 消费者 | **hi-im-roomfanout**：按 partition 扩展；读 Redis rid→nid；**hi-im async_send** |
| 热路径 | 低峰仍 chatroom 直发 hi-im |

**原则**：Kafka 管削峰与持久；**最后一跳仍是 hi-im 总线**，不是 gRPC 推 gateway。

---

## 10. 部署（K8s 概要）

```text
Ingress (wss://im.example.com)
  └── hi-im-gateway Deployment (HPA on CPU/conn)
        └── HIIM_FORWARD → hi-im-hub-{shard}

hi-im-hub-0 StatefulSet  (固定 NID 范围)
hi-im-hub-1 StatefulSet

hi-im-msgsvr / chatroom / usrsvr Deployment
hi-im-seqsvr Deployment
hi-im-roomfanout Deployment (replicas ≈ Kafka partitions)
```

| 组件 | 扩缩容 |
|------|--------|
| gateway | ✅ HPA |
| hi-im-hub | ⚠️ 按 shard 增删，非 blind replicas |
| msgsvr SUB=single | ⚠️ 垂直扩或 Kafka 分片 |
| roomfanout | ✅ 跟 partition |

---

## 11. 实施路线图与工期

假设 **你全职**，已有必嗨 RTMQ 文档基础。

> **hi-im-core 内部里程碑**（core-M1～M4）见独立仓库 `hi-im-core/doc/技术设计文档.md` §13；与下表 **生态 M1～M9** 勿混用。

### 11.1 群聊为什么不能在 M3 做？

必嗨群聊是 **双段 fan-out**，缺任何一段都无法「双窗口互通」：

```text
窗口 A ──WS──► gateway(NID=20001)
                  │ AsyncSend GROUP-CHAT
                  ▼ publish
              msgsvr  ──查 Redis gid→{20001,20002,...}──► 对每个 nid AsyncSend（第一段 fan-out）
                  │
                  ▼ async_send(nid=20002)
              gateway(NID=20002) ──ChatTab ImGroup──► 窗口 B（第二段 fan-out）
```

| 组件 | 群聊中的角色 | M3 时是否存在 |
|------|--------------|---------------|
| hi-im-core | Hub 路由 publish / async_send | M1 后有 |
| hi-im-hubclient | 嵌入 gateway / msgsvr（L2 库） | M2 后有 |
| hi-im-gateway | WS + 第二段 fan-out | **M5** 起；**不能单独验收群聊** |
| **hi-im-msgsvr** | **第一段 gid→nid fan-out** | **M6 才有** |
| hi-im-usrsvr | 建群、加群、ONLINE | M4 后有 |
| hi-im-seqsvr | 注册分配 sid | M4 后有 |
| Redis | gid→nid、成员表 | hi-im 主仓 Compose 提供 |

因此：**M3 只能验收 WS 接入 + Hub 单播/回声**；**群聊双窗口冒烟放在 M6**（msgsvr 就绪后）。

### 11.2 仓库 × 里程碑对照（11 个全覆盖）

| 仓库 | 首次纳入 | 说明 |
|------|----------|------|
| **hi-im-core** | M1 | Hub + bench |
| **hi-im-api** | M2 | 48B 头、cmd 常量、proto |
| **hi-im-hubclient** | M2 | Hub 客户端：AUTH/SUB/AsyncSend |
| **hi-im** | M3 | 最小 Compose；M8 扩展 K8s/Helm |
| **hi-im-seqsvr** | M4 | gRPC 发号 |
| **hi-im-usrsvr** | M4 | 注册、ONLINE、群成员 HTTP/gRPC |
| **hi-im-gateway** | M5 | WS 长连接；M5 末可双窗口 **单播/回声**，非群聊 |
| **hi-im-msgsvr** | M6 | 群聊 / 私聊第一段 fan-out |
| **hi-im-chatroom** | M7 | 聊天室、rid→nid |
| **hi-im-tasker** | M7 | TTL、在线统计（可与 chatroom 并行） |
| **hi-im-roomfanout** | M9 | Kafka Consumer（档 C 削峰） |

### 11.3 里程碑明细

| 阶段 | 涉及仓库 | 内容 | 工期 | 验收（可执行） |
|------|----------|------|------|----------------|
| **M1** | hi-im-core | bus wire v1 + Hub 单 Shard + bench | 3 周 | `hi-im-bench` publish **≥ 14 万/s** |
| **M2** | hi-im-api, hi-im-hubclient | 契约 + Hub 客户端单测 | 2 周 | hubclient 连 Hub，unicast 端到端 |
| **M3** | hi-im | Compose：hub + hubclient 测试桩 + Redis | 1 周 | **Hub 集成冒烟**（publish/unicast）；**不含群聊** |
| **M4** | hi-im-seqsvr, hi-im-usrsvr | gRPC 发号 + Gin 注册/ONLINE | 2 周 | HTTP 注册拿 sid，ONLINE 写 Redis |
| **M5** | hi-im-gateway | WS 接入 + 调 usrsvr | 2 周 | 浏览器连 WS、注册上线；可选 **双窗口 echo/单播** |
| **M6** | hi-im-msgsvr | 群聊：建群/加群/GROUP-CHAT fan-out | 3 周 | **Demo 双窗口群聊互通** |
| **M7** | hi-im-chatroom, hi-im-tasker | 聊天室 + 定时任务 | 2 周 | 进房发弹幕；tasker 跑通 |
| **M8** | hi-im-core, hi-im | Hub 分片 + Prometheus + K8s | 3 周 | 2 shard 压测；Ingress 固定 wss |
| **M9** | hi-im-roomfanout | Kafka 削峰 + consumer | 2 周 | 峰值对比数据（v0 vs v3 表） |

**合计约 20 周（~5 个月）**；原 M1～M7 估 17 周偏乐观，主要补了 **M3 主仓 Compose**、**M5/M6 拆分** 与 **tasker/chatroom 独立 M7**。

### 11.4 两条并行策略（省时间）

若希望 **尽早看到浏览器 Demo**，可与 M2 并行从 beehive-im **只读对照**迁移，但验收仍按上表：

| 策略 | 做法 | 风险 |
|------|------|------|
| **A. 严格净室** | 按 M1→M9 顺序写 hi-im 仓库 | 最慢，叙事最干净 |
| **B. 混合对照** | M5 前 gateway 临时 **连 beehive 旧 msgsvr** 验证 WS 链 | 仅本地调试，**不算 hi-im 里程碑完成** |
| **C. 推荐** | M5 只做 WS+注册；**M6 再切 hi-im-msgsvr**，一次验收群聊 | 工期清晰，不误导 |

### 11.5 M3 / M5 / M6 验收对照（避免再混淆）

| 里程碑 | 能做什么 | 不能做什么 |
|--------|----------|------------|
| **M3** | Hub + hubclient 压测、unicast 测试桩 | 群聊、WS 浏览器 |
| **M5** | 双窗口 WS 在线、单播/回声 | **群聊 fan-out** |
| **M6** | **双窗口群聊** | 聊天室峰值 Kafka |

---

## 12. 风险与决策记录

| ID | 决策 | 理由 |
|----|------|------|
| D1 | 热路径不用 gRPC | 延迟与吞吐；必嗨原设计正确 |
| D2 | seqsvr Thrift → gRPC | 统一栈、易代码生成、你简历叙事 |
| D3 | **hi-im-hubclient** 纯 Go、与 **hi-im-api** 分仓 | 传输层稳定；协议常改只 bump api；避免 CGO |
| D4 | hi-im-core 独立 C++ 仓库 | 与 Go 服务解耦、便于 C++ 第二曲线 |
| D5 | 生态统一命名 **hi-im** | 仓库、镜像、K8s 资源前缀一致 |
| D6 | listend 延后 | 浏览器 Demo 以 WS 为主 |
| D7 | 开源协议 **Apache 2.0** | 商业友好、与 gRPC/Protobuf/K8s 生态一致；各 hi-im 独立仓库根目录携带相同 LICENSE |
| D8 | 不用 **hi-im-sdk-go** 指代 api+hubclient | 对外 SDK 与未来内部契约分层，避免集成方误用 Hub TCP |

| 风险 | 缓解 |
|------|------|
| rsvr 拼帧 bug | Wire 层单测 + 必嗨 pcap 对照 |
| Hub 分片跨 shard 复杂 | M1 单 Shard 跑通再 M8 |
| Go 迁移面大 | 先 gateway + usrsvr（M4/M5），msgsvr 群聊 M6 再验收 |
| 里程碑与仓库数不一致 | 见 §4.4、§11.2；11 仓库均有归属 |
| hubclient 被业务拖改 | 见 §4.6 变更归属表；fan-out 只放 L3 |
| 性能回退 | 每 Milestone 跑 hi-im-bench 对比基线 JSON |

---

## 13. 面试 / 开源 README 一句话

> **hi-im** 是必嗨 IM 的现代化重写：C++ **hi-im-core** 保留 **publish / async_send** 双路由与双平面 Hub，补齐 **Hub 分片、Prometheus 与 Kafka 削峰**；Go 业务层以 **Gin + gRPC** 独立演进，热路径 IM 帧仍走 hi-im 内存总线，**gRPC 仅负责 seqsvr 等冷路径 RPC**。

---

## 14. 开源许可证

| 项 | 说明 |
|----|------|
| **协议** | [Apache License 2.0](../LICENSE) |
| **版权** | Copyright 2026 Sun Chao |
| **适用范围** | hi-im 生态新代码（hi-im-core、hi-im-hubclient、各 Go 服务等） |
| **NOTICE** | 见仓库根目录 [NOTICE](../NOTICE)；必嗨遗留 C 源码保留原文件头版权，hi-im-core 为净室重写 |
| **拆仓要求** | 每个独立 GitHub 仓库根目录复制 `LICENSE` + `NOTICE`；Go 源文件头可选加 SPDX：`SPDX-License-Identifier: Apache-2.0` |

---

## 15. 下一步建议

1. 推进 **`hi-im-core`** M1：见 `hi-im-core/doc/M1-实施清单.md`。
2. 创建 **`hi-im-api`** + **`hi-im-hubclient`**（M2，见 §4.5～§4.6）。
3. **`hi-im`**（本仓库）最小 Compose 与 M3 对齐（hub + redis，**不要**把群聊写进 M3 验收）。
4. **M6 之前**不要承诺「双窗口群聊 Demo」；M5 最多验收 WS + 注册 + 单播。

如需，可继续拆 **M2 hi-im-hubclient 状态机清单** 或 **`hi-im-api` proto 全量定义**。
