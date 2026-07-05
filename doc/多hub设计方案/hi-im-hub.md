# 多 Hub — hi-im-hub（hi-im-core）分片方案

> 父文档：[hi-im-档C-多hub设计方案.md](../hi-im-档C-多hub设计方案.md) §5  
> 仓库：`hi-im-core`（C++ Hub Server）

---

## 1. 职责

| 平面 | 端口 | 连接方 |
|------|------|--------|
| FORWARD | 28888 | gateway（按 NID 注册） |
| BACKEND | 28889 | msgsvr、usrsvr、chatroom |
| interconnect | 28890 | 其他 Hub shard（跨片转发） |
| metrics | 8080 | Prometheus |

**不负责**：业务语义、持久化、客户端 WS。

---

## 2. 分片模型

- **1 Pod = 1 shard = 1 份 nid_map**（StatefulSet ordinal 映射 shard_id）。
- NID 范围 `[nid_min, nid_max]` 由 ConfigMap `shard-registry` 定义。
- `async_send(dest_nid)`：本 shard 直投；否则走 **interconnect** 转 owner shard。

---

## 3. K8s 部署

| 资源 | 配置 |
|------|------|
| Workload | `StatefulSet`（**非** Deployment 多副本同 shard） |
| Service | Headless `hi-im-hub-headless` |
| 存储 | 空 dir 即可（路由表内存）；可选 PVC 存配置 |
| 反亲和 | 每节点最多 1～2 个 hub Pod（CPU 密集） |

```yaml
labels:
  hiim.io/shard-id: "0"   # 与 HIIM_SHARD_ID 一致
```

---

## 4. 扩缩容

### 4.1 增加 Shard（水平扩吞吐）

1. `replicas++` 或 `shardCount++`（Helm）。  
2. 新 Pod 加载 shard-registry 中对应段。  
3. gateway 新 NID 注册到新 shard。  
4. 验证 `hiim_forward_cross_shard_total` 延迟。

### 4.2 禁止：同 shard 多 Pod

`replicas: 3` 若指 **同一 shard** → nid_map 分裂 → **必丢包**。

### 4.3 垂直扩

单 shard 连接/QPS 到顶：调大 CPU/内存、`--reactor-threads`、`--queue-capacity`（见 [问题集合1](../系统问题收集/问题集合1.md) MPSC 约束）。

---

## 5. 队列与线程（单 shard 内）

| 队列 | 模型 |
|------|------|
| DistQueue / RecvQueue | MPSC |
| SendQueue / ConnQueue | SPSC |
| Distributor | 单线程 Pop DistQueue |

---

## 6. interconnect API（Phase 2 实现）

```text
入站：hub-shard-B:28890
帧：wire v1 + ForwardHeader { origin_shard, dest_nid }
行为：等同本 shard 收到 AsyncSend(dest_nid)
错误：NotFound / ShardUnavailable → 回传 msgsvr
```

---

## 7. 可观测

| 指标 | 告警 |
|------|------|
| `hiim_connections{plane,shard}` | 接近规划上限 |
| `hiim_queue_depth` | dist/send 持续高位 |
| `hiim_drop_total` | >0 |
| `hiim_forward_cross_shard_latency_us` | P99 |

---

## 8. 里程碑

| 阶段 | 内容 |
|------|------|
| M1～M6 | 单 Hub Compose |
| M8a | 2 shard STS + 冒烟 |
| M8b | interconnect + multi-backend msgsvr |
