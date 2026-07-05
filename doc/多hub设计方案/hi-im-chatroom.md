# 多 Hub — hi-im-chatroom / hi-im-roomfanout 扩展方案

> 父文档：[hi-im-档C-多hub设计方案.md](../hi-im-档C-多hub设计方案.md) §9  
> 仓库：`hi-im-chatroom`、`hi-im-roomfanout`

---

## 1. hi-im-chatroom

### 1.1 职责

- 聊天室消息；Redis `rid→nid`；SUB `ROOM-CHAT`。
- 低峰：**直发 Hub** AsyncSend；高峰：**写 Kafka**（M9）。

### 1.2 多 Hub

- 同 msgsvr：`HIIM_BACKEND_ADDRS` multi-backend。
- rid 可能映射多个 gateway NID（跨 shard）。

### 1.3 扩缩

| 模式 | replicas |
|------|----------|
| 直发 Hub | 1（SUB single） |
| Kafka 旁路 | chatroom 可 2+（只写 Kafka，不 SUB） |

---

## 2. hi-im-roomfanout

### 2.1 职责

```text
Kafka im.room / im.group
  → consumer（roomfanout Pod）
  → Redis rid/gid→nid
  → hubclient AsyncSend(dest_nid)  # multi-backend
```

### 2.2 K8s

| 资源 | 配置 |
|------|------|
| Workload | `Deployment` |
| replicas | **≤ topic partition 数** |
| HPA | 按 `kafka_consumer_lag`（不超过 partition） |

```yaml
replicas: 12
env:
  - name: KAFKA_TOPIC_IM_ROOM
    value: im.room
  - name: HIIM_BACKEND_ADDRS
    value: hub-shard-0:28889,hub-shard-1:28889,...
```

### 2.3 横向扩展

1. 增加 Kafka **partition**（需 rebalance 规划）。  
2. `replicas = partitions`。  
3. 每 Pod 独立 consumer group member。

**天然水平扩**：partition 数 = 最大并行 consumer 数。

---

## 3. 与 msgsvr 分工

| 场景 | 路径 |
|------|------|
| 普通群聊 | msgsvr 直发 Hub |
| 万人群 / 弹幕峰值 | chatroom → Kafka → roomfanout → Hub |
| 聊天室 | chatroom / roomfanout |

---

## 4. 里程碑

| 阶段 | 内容 |
|------|------|
| M6 | msgsvr 群聊 |
| M9 | Kafka + roomfanout 压测 |
