# 多 Hub — hi-im-gateway 接入方案

> 父文档：[hi-im-档C-多hub设计方案.md](../hi-im-档C-多hub设计方案.md) §6  
> 仓库：`hi-im-gateway`（独立 Go 服务）

---

## 1. 职责

| 项 | 说明 |
|----|------|
| 协议 | 客户端 WebSocket ↔ IM 二进制帧 |
| Hub | 内嵌 hubclient，**FORWARD** 平面 TCP |
| 状态 | ChatTab（sid→cid）、ImGroup（gid 成员下行） |
| 对外 | 仅 HTTP/WS；**不暴露** Hub 地址给客户端 |

---

## 2. 多 Hub 接入规则

```text
启动参数 / 环境变量：
  HIIM_NID          全局唯一（如 20107）
  HIIM_SHARD_ID     f(HIIM_NID) 由 shard-registry 决定
  HIIM_FORWARD_ADDR hub-shard-{id}.hi-im-hub-headless:28888
```

- **禁止**连 `hi-im-hub` ClusterIP（随机 Pod）。
- 进程生命周期内 **不换 shard**；迁移 = 新 Pod 新 NID + 客户端重连。

---

## 3. K8s 部署

| 资源 | 配置 |
|------|------|
| Workload | `Deployment` |
| Service | `ClusterIP`（Ingress 后端） |
| Ingress | 统一 `wss://im.example.com/ws` |
| HPA | `minReplicas` / `maxReplicas` + 自定义 `hiim_gateway_ws_connections` |
| PDB | `minAvailable: 80%` 防滚动全断 |

---

## 4. 横向扩展

### 4.1 扩容

1. HPA 或手动增加 `replicas`。  
2. 为新 Pod 分配 **未占用 NID**（Operator / seqsvr 租约 / Helm nidPool）。  
3. 从 shard-registry 解析 `HIIM_FORWARD_ADDR`、`HIIM_SHARD_ID`。  
4. Pod Ready 后接收 Ingress 流量；ONLINE 注册到 usrsvr/Redis。

### 4.2 缩容

1. Ingress / Service 对该 Pod 摘流（readiness 失败）。  
2. PreStop：等待 WS 自然断开或发 KICK（可选）。  
3. 释放 NID 租约。

### 4.3 容量参考

| Pod 规格 | 参考 WS 连接数（需压测） |
|----------|-------------------------|
| 2C4G | 1～2 万 |
| 4C8G | 2～5 万 |

---

## 5. 依赖

| 依赖 | 用途 |
|------|------|
| hi-im-hub（FORWARD） | 上行 publish、下行 async_send |
| hi-im-usrsvr HTTP | register、iplist、token |
| Redis | 间接（usrsvr 写在线） |

---

## 6. 可观测

| 指标 | 用途 |
|------|------|
| `hiim_gateway_ws_connections` | HPA |
| `hiim_gateway_ws_write_fail_total` | downlink 队列满 |
| `hiim_hubclient_send_errors` | Hub 断连 |

---

## 7. 里程碑

| 阶段 | 内容 |
|------|------|
| M5 | 单 Hub 双 gateway 容器 |
| M8 | Deployment + HPA + Ingress + NID 池 |
| M10 | Operator 自动 NID/shard 绑定 |
