# 多 Hub — hi-im-msgsvr 扩展方案

> 父文档：[hi-im-档C-多hub设计方案.md](../hi-im-档C-多hub设计方案.md) §7  
> 仓库：`hi-im-msgsvr`

---

## 1. 职责

```text
gateway ──publish(GROUP-CHAT)──► Hub BACKEND ──► msgsvr SUB 回调
msgsvr ──Redis gid→{nid...}──► 对每个 nid AsyncSend（第二段 fan-out）
```

---

## 2. 多 Hub 接入

### 2.1 multi-backend

```bash
HIIM_BACKEND_ADDRS=hub-shard-0:28889,hub-shard-1:28889,...
# hubclient 维护到每个 shard 的 TCP；AsyncSend 时：
#   conn = pool[shard_id(f(dest_nid))]
```

### 2.2 跨 shard fan-out

单条群消息可能 fan-out 到多个 shard 上的 gateway NID：

```text
gid=1 → nids [20001(shard0), 25001(shard1)]
  AsyncSend(20001) → shard-0 本地
  AsyncSend(25001) → shard-0 interconnect → shard-1
```

msgsvr 侧 **best-effort** 逐 nid 发送；失败打日志不中断（已实现）。

---

## 3. SUB 与多副本

| 模式 | replicas | 说明 |
|------|----------|------|
| **single** | 1 | Hub publish 只一份；M8 默认 |
| **leader** | 1 active + N standby | K8s Lease 选举 |
| **kafka** | N = partition | 不 SUB GROUP-CHAT；消费 Kafka |

**禁止**：`replicas: 3` 且三份都 SUB 同一 cmd → 群聊处理 3 次。

---

## 4. K8s 部署

| 资源 | 配置 |
|------|------|
| Workload | `Deployment` |
| replicas | 1（single）或 Kafka 消费组规模 |
| HPA | 仅 kafka 模式按 lag |
| 资源 | CPU 密集（fan-out 循环）；4C8G 起 |

---

## 5. 横向扩展路径

| 阶段 | 方案 |
|------|------|
| M6～M8 | 单 Pod 垂直扩 |
| M9 | 热点群聊写 Kafka；msgsvr 降载 |
| 长期 | `im.group` partition key=gid；N 个 consumer Deployment |

---

## 6. 依赖

| 依赖 | 用途 |
|------|------|
| Hub BACKEND × shard | SUB + AsyncSend |
| Redis | gid→nid、群成员 |
| hi-im-usrsvr | 群成员变更（间接） |

---

## 7. 配置清单

```bash
HIIM_NID=31001              # msgsvr 进程 NID（BACKEND 连接身份）
HIIM_SUB_CMDS=0x030B
HIIM_SUB_MODE=single        # single | kafka
HIIM_BACKEND_ADDRS=...      # 多 shard
```

---

## 8. 里程碑

| 阶段 | 验收 |
|------|------|
| M6 | 单 Hub 群聊 |
| M8b | multi-backend 跨 shard burst |
| M9 | Kafka 峰值不丢 |
