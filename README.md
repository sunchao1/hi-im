# hi-im

**hi-im** 是必嗨 IM 的现代化重写生态：C++ **[hi-im-core](https://github.com/sunchao1/hi-im-core)** 净室重写 RTMQ Hub，Go 业务层拆分为独立微服务仓库，热路径仍走 **publish / async_send** 内存总线，冷路径统一 **gRPC**。

**本仓库（主仓）** 负责生态文档、Compose/K8s 编排、版本矩阵与集成冒烟；**不**作为可部署的业务进程。

**许可证**：[Apache License 2.0](LICENSE) · 详见 [NOTICE](NOTICE)

## 一句话

> C++ **hi-im-core** 保留双平面 Hub 与 **publish / async_send** 路由，补齐 Hub 分片、Prometheus 与 Kafka 削峰；Go 层以 **Gin + gRPC** 独立演进，**gRPC 仅负责 seqsvr 等冷路径**。

## 总览文档

| 文档 | 说明 |
|------|------|
| [doc/hi-im-档C技术方案设计.md](doc/hi-im-档C技术方案设计.md) | 档 C 技术方案：架构、分层、11 仓、M1～M9 路线图 |
| [doc/技术设计文档.md](doc/技术设计文档.md) | **主仓**设计：Compose/K8s、版本矩阵、集成冒烟 |
| [doc/M1-实施清单.md](doc/M1-实施清单.md) | 生态 M3 任务（最小 Compose + unicast） |

## 子仓库（10 个）

| 仓库 | 层级 | 部署 | 说明 |
|------|------|------|------|
| [hi-im-core](https://github.com/sunchao1/hi-im-core) | L1 | ✅ | C++ Hub、bridge、bench |
| [hi-im-api](https://github.com/sunchao1/hi-im-api) | L2 | ❌ | 内部契约：48B 头、CMD、proto、Redis 键 |
| [hi-im-hubclient](https://github.com/sunchao1/hi-im-hubclient) | L2 | ❌ | Hub TCP 客户端库（必嗨 RTMQ Proxy 等价） |
| [hi-im-gateway](https://github.com/sunchao1/hi-im-gateway) | L3 | ✅ | WebSocket 接入、Gin |
| [hi-im-usrsvr](https://github.com/sunchao1/hi-im-usrsvr) | L3 | ✅ | 注册、鉴权、在线 |
| [hi-im-msgsvr](https://github.com/sunchao1/hi-im-msgsvr) | L3 | ✅ | 私聊 / 群聊第一段 fan-out |
| [hi-im-chatroom](https://github.com/sunchao1/hi-im-chatroom) | L3 | ✅ | 聊天室、rid→nid |
| [hi-im-seqsvr](https://github.com/sunchao1/hi-im-seqsvr) | L3 | ✅ | SID/RID/SEQ 发号（gRPC） |
| [hi-im-tasker](https://github.com/sunchao1/hi-im-tasker) | L3 | ✅ | TTL、在线统计 |
| [hi-im-roomfanout](https://github.com/sunchao1/hi-im-roomfanout) | L3 | ✅ | Kafka consumer → hubclient 下行 |

> **11 个 Git 仓库** = 本主仓 **hi-im** + 上表 10 个子仓库。L2 库编译进 L3 二进制，不单独起 Pod。

## 架构分层（简图）

```text
L4  对外 SDK（未来，本档 C 不做）
L3  gateway / usrsvr / msgsvr / chatroom / seqsvr / tasker / roomfanout  ← 独立部署
L2  hi-im-api + hi-im-hubclient                                         ← go get
L1  hi-im-core（Hub）                                                   ← 独立部署
```

## 里程碑（生态 M1～M9）

| 阶段 | 重点 | 验收 |
|------|------|------|
| M1 | hi-im-core Hub + bench | publish ≥ 14 万/s |
| M2 | hi-im-api + hi-im-hubclient | unicast 端到端 |
| M3 | **本仓** Compose 冒烟 | Hub publish/unicast（**不含群聊**） |
| M4 | seqsvr + usrsvr | 注册、ONLINE |
| M5 | gateway | WS 在线、单播/回声 |
| M6 | msgsvr | **双窗口群聊** |
| M7 | chatroom + tasker | 聊天室、定时任务 |
| M8 | core 分片 + 本仓 K8s | 2 shard + Prometheus |
| M9 | roomfanout + Kafka | 削峰对比 |

详见 [doc/hi-im-档C技术方案设计.md](doc/hi-im-档C技术方案设计.md) §11。

## 与必嗨（beehive-im）的关系

- 必嗨原 C 栈（2014～2017）为对照与迁移参考；hi-im 为净室重写与新架构。
- 历史设计稿曾放在 [beehive-im](https://github.com/sunchao1/beehive-im) `doc/`；**canonical 副本已迁至本仓库**。

## 状态

- **hi-im-core M1**：已完成（Hub + bench 达标）
- **hi-im-api / hi-im-hubclient M2**：v0.1.0
- **本仓 M3**：Compose + unicast 冒烟可用（`make m3-smoke`）
- **本仓 M6**：双窗口群聊 Compose + 终端冒烟（`make m6-smoke`）+ 浏览器 Demo（`make m6-demo`）

## 快速开始（M3 冒烟）

```bash
# 需 sibling checkout：../hi-im-core（或设置 deploy/compose/.env 中 HIIM_HUB_BUILD_CONTEXT）
cp deploy/compose/.env.example deploy/compose/.env   # 可选
make m3-smoke
```

| 命令 | 说明 |
|------|------|
| `make m3-up` | 启动 hub + redis + smoke 服务 |
| `make m3-smoke` | 拉起栈并跑 unicast 冒烟（退出码 0/1） |
| `make m3-down` | 停止并清理卷 |

## 快速开始（M6 双窗口群聊）

```bash
# sibling 布局：../{hi-im-core,hi-im-api,hi-im-hubclient,hi-im-gateway,hi-im-usrsvr,hi-im-msgsvr,hi-im-seqsvr}
cp deploy/compose/.env.example deploy/compose/.env   # 端口冲突时改 HIIM_*_HOST_PORT
make m6-smoke    # 终端验收
make m6-demo     # 浏览器 http://127.0.0.1:8088/group.html（两窗口）
```

| 命令 | 说明 |
|------|------|
| `make m6-up` | 启动群聊全栈（hub + redis + mysql + seqsvr + usrsvr + msgsvr + gateway×2） |
| `make m6-smoke` | 双 gateway 群聊端到端冒烟 |
| `make m6-demo` | 同上 + demo-web（静态页 + usrsvr 代理） |
| `make m6-down` | 停止并清理 |
