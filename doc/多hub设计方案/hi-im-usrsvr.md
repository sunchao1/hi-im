# 多 Hub — hi-im-usrsvr 扩展方案

> 父文档：[hi-im-档C-多hub设计方案.md](../hi-im-档C-多hub设计方案.md) §8  
> 仓库：`hi-im-usrsvr`

---

## 1. 职责

| 路径 | 说明 |
|------|------|
| HTTP | register、iplist、群 CRUD、成员 |
| Hub BACKEND | SUB ONLINE/OFFLINE 等；写 Redis 在线 |
| gRPC | seqsvr 发号 |

---

## 2. 多 Hub 关系

- **无状态 HTTP**：任意副本处理注册；数据在 MySQL/Redis。
- **iplist**：返回统一 Ingress `wss://...`；客户端不感知 shard。
- **ONLINE 下行**：经 Hub publish；多副本 SUB 时需 **单活或按 cmd 分片**（与 msgsvr 同类问题，QPS 低于群聊）。

---

## 3. K8s 部署

| 资源 | 配置 |
|------|------|
| Workload | `Deployment` |
| replicas | 3～10（HPA） |
| Service | ClusterIP + HTTP readiness |
| HPA | CPU / RPS |

```yaml
resources:
  requests:
    cpu: 500m
    memory: 512Mi
```

---

## 4. 横向扩展

| 操作 | 说明 |
|------|------|
| 扩容 | 直接 `replicas++`；无 NID 绑定 |
| 缩容 | 无状态摘流即可 |
| BACKEND | 建议 `replicas: 1` 或 Leader Election 处理 SUB |

### 4.1 SUB 策略建议

| cmd 类 | 建议 |
|--------|------|
| ONLINE / OFFLINE | 单活 Leader |
| 管理类 publish | 单活或按 shard 过滤 |

---

## 5. 依赖

| 依赖 | 说明 |
|------|------|
| Redis Cluster | 在线、token、群成员缓存 |
| MySQL | 用户、关系 |
| seqsvr gRPC | 发 sid/gid |
| Hub BACKEND | 可选单连接或连主 shard |

---

## 6. 与 gateway 扩缩协同

gateway 扩 Pod → 新 NID → register/ONLINE 写 Redis → **usrsvr 无需改配置**。

---

## 7. 里程碑

| 阶段 | 内容 |
|------|------|
| M4 | 单副本 register/ONLINE |
| M8 | HPA 3+ 副本 HTTP |
