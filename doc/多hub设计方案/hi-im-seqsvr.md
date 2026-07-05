# 多 Hub — hi-im-seqsvr 扩展方案

> 父文档：[hi-im-档C-多hub设计方案.md](../hi-im-档C-多hub设计方案.md) §10  
> 仓库：`hi-im-seqsvr`

---

## 1. 职责

gRPC 冷路径发号：`AllocSid`、`AllocGid`、`AllocRid`、`AllocSeq` 等。  
QPS 远低于 IM 热路径。

---

## 2. 多 Hub 关系

- **与 Hub 分片无强耦合**；但 **NID 分配** 扩 gateway 时需要稳定发号。
- 可选扩展：`AllocNid(shard_id)` 供 gateway Operator 使用（Phase 3）。

---

## 3. K8s 部署

| 资源 | 配置 |
|------|------|
| Workload | `Deployment` |
| Service | ClusterIP gRPC |
| replicas | M8: 1～2；长期: 3+ 无状态 |

---

## 4. 横向扩展路径

| 方案 | 说明 | 阶段 |
|------|------|------|
| **垂直扩** | 单 Pod 加 CPU | M8 |
| **无状态多副本** | Redis/MySQL 号段预取；gRPC LB | M10 |
| **分片发号** | `AllocSid` 按 uid 哈希到不同 seqsvr | 大规模 |

### 4.1 推荐：号段池

```text
seqsvr Pod 无状态：
  从 Redis INCR 或 DB 领取 [start, end] 号段
  本地发放直到耗尽再领取
  → Deployment replicas: 3，HPA 按 gRPC QPS
```

---

## 5. 依赖

| 依赖 | 用途 |
|------|------|
| MySQL / Redis | 号段持久化 |
| 无 Hub 依赖 | 纯 gRPC |

---

## 6. 里程碑

| 阶段 | 内容 |
|------|------|
| M4 | 单副本 seqsvr |
| M10 | 号段池 + 多副本 |
