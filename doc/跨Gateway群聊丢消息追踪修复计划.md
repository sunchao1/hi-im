# 跨 Gateway 群聊丢消息 — 追踪修复计划（手动逐节点）

> 依据：[doc/sunchao_todo1.md](sunchao_todo1.md)  
> 关联：[doc/跨Gateway群聊丢消息修复计划.md](跨Gateway群聊丢消息修复计划.md) · [doc/常见错误集.md](常见错误集.md) §5  
> 结论记录：[doc/debug_lose_message_process_detail.log](debug_lose_message_process_detail.log)

---

## 0. 使用说明

本计划按 **消息实际经过的节点顺序** 排列。每一步由你手动执行，对照「预期入参/出参」打勾。  
**全部步骤预期符合** → 理论上不会出现跨 Gateway 群聊丢消息。

| 符号 | 含义 |
|------|------|
| `[ ]` | 待你执行并标注 |
| `[x]` | 你已确认通过 |
| `FAIL` | 不符合预期，记录现象后我们一起修 |

**测试数据（固定）**

| 窗口 | UID | Gateway WS | Demo URL |
|------|-----|------------|----------|
| A | 100001 | `ws://127.0.0.1:28080/ws` | `http://127.0.0.1:8088/group.html?gw=1` |
| B | 100002 | `ws://127.0.0.1:28081/ws` | `http://127.0.0.1:8088/group.html?gw=2&gid=1` |

群名：**测试1**。建群后 A 先加入，B 再加入，**gid 两边一致**（示例 gid=1）。

连发内容：

- A：`100001+1` … `100001+5`（共 5 条）
- B：`100002+1` … `100002+5`（共 5 条）

---

## 1. 前置条件（对应 sunchao_todo1 §1）

### 1.1 停服

```bash
cd /Users/chaosun/GolandProjects/hi-im
make m6-heal-down
```

停止 M6 全栈（hub、redis、mysql、usrsvr、msgsvr、gateway×2、**demo-web**）。不删卷（无 `-v`），Redis/MySQL 数据保留。

- [ ] 执行后 `docker ps` 无 `hi-im-*` 容器

### 1.2 启服（由你手动执行）

| 情况 | 操作 |
|------|------|
| **无任何代码改动** | 不需要 `m6-heal-down && make m6-heal`；栈已在跑则直接测；若已停服则 `make m6-demo` |
| **有任何代码改动** | 你手动：`make m6-heal-down && make m6-heal` |

`sunchao_todo1` 约定：**改代码后的停服 + 重建启服由你操作**，Agent 不代跑 `make m6-heal`。

**预期出参（终端）**

- `M6 stack ready.`
- `M6 PASS: online probe OK`（或提示 run `make m6-heal`）
- 打印 Demo URL，端口见 `deploy/compose/.env` 的 `HIIM_DEMO_WEB_PORT`（当前 **8088**）

- [ ] 1.2 启动完成，探针通过

### 1.3 健康检查（逐节点）

| 节点 | 操作 | 预期出参 |
|------|------|----------|
| hub | `curl -sf http://127.0.0.1:18080/readyz` | HTTP 200，无 stderr |
| gateway-1 | `curl -sf http://127.0.0.1:28080/readyz` | HTTP 200 |
| gateway-2 | `curl -sf http://127.0.0.1:28081/readyz` | HTTP 200 |
| usrsvr | `docker exec hi-im-usrsvr-1 wget -qO- http://127.0.0.1:8081/readyz` | `ok` 或 200 |
| msgsvr | `docker exec hi-im-msgsvr-1 wget -qO- http://127.0.0.1:8082/readyz` | `ok` 或 200 |
| demo-web | 浏览器打开 `http://127.0.0.1:8088/group.html` | 页面正常，无 502 |

- [ ] 1.3 六节点 ready

### 1.4 Demo 端口确认

- [ ] 打开的是 **8088**（或 `.env` 里配置的端口），**不是** beehive 旧 demo 的误用页面
- [ ] 两窗口 **Cmd+Shift+R** 硬刷新

### 1.5 持久化说明（群关系 + 消息）

| 数据 | 当前落地位置 | 重启后验证方法 |
|------|--------------|----------------|
| sid 发号 | MySQL（seqsvr） | `docker restart hi-im-seqsvr-1` 后重新 register，uid 不变 sid 递增 |
| 群 gid、成员、gid→nid | **Redis**（usrsvr 写入） | 见 §2.3；`docker restart hi-im-redis-1` 后 key 仍在 |
| 群消息正文 | **暂未写入 MongoDB**（sunchao_todo1 要求 Mongo，msgsvr 当前只做 fan-out） | 现阶段用 **msgsvr / gateway 日志** 中的 `text=` 作为「已落地」依据；Mongo 接入后在本节补查询命令 |

- [ ] 1.5 已理解：消息 Mongo 持久化尚未接入，追踪以日志为准

---

## 2. 建群 / 加群链路（持久化 + ImGroup）

### 2.1 注册（HTTP → seqsvr → usrsvr）

**操作（窗口 A）**

1. UID 填 `100001`，点「注册并连接」

**预期 — 浏览器日志**

```
register ok uid=100001 sid=...
ONLINE ok
```

**预期 — usrsvr**

```bash
docker logs hi-im-usrsvr-1 2>&1 | grep 'online: ok' | tail -1
# 含 sid=... uid=100001
```

**预期 — gateway-1**

```bash
docker logs hi-im-gateway-1 2>&1 | grep 'online:' | tail -3
# online: published → online ok（或 ack received）
```

- [ ] 2.1-A 100001 ONLINE ok

**操作（窗口 B）**：UID `100002`，同样注册并连接。

- [ ] 2.1-B 100002 ONLINE ok

### 2.2 建群 / 加群（WS → gateway → hub → usrsvr → Redis）

**操作（窗口 A）**

1. 群名填 **测试1**
2. 点「创建群」

**预期 — 浏览器 A**

```
建群成功 gid=1
```

**预期 — usrsvr**

```bash
docker logs hi-im-usrsvr-1 2>&1 | grep 'group-creat' | tail -2
# 无 group-creat: ... failed；成功时后续有 group-join 或 creat ok 类日志
```

**预期 — gateway-1 ImGroup**

```bash
docker logs hi-im-gateway-1 2>&1 | grep ImGroupJoin | tail -2
# ImGroupJoin gid=1 sid=<A的sid> cid=...
```

- [ ] 2.2-A 建群成功 gid=1

**操作（窗口 B）**

1. GID 栏填 **1**（或 URL 已带 `gid=1`）
2. 点「加入群」

**预期 — 浏览器 B**

```
加群成功 gid=1
```

**预期 — usrsvr**

```bash
docker logs hi-im-usrsvr-1 2>&1 | grep 'group-join: ok' | tail -1
# group-join: ok gid=1 uid=100002 sid=...
```

**预期 — gateway-2 ImGroup**

```bash
docker logs hi-im-gateway-2-1 2>&1 | grep ImGroupJoin | tail -2
# ImGroupJoin gid=1 sid=<B的sid>
```

- [ ] 2.2-B 加群成功

### 2.3 Redis 持久化抽检（gid→nid 必须含两个 gateway）

**操作**

```bash
docker exec hi-im-redis-1 redis-cli ZRANGE chat:gid:1:to:nid:zset 0 -1 WITHSCORES
docker exec hi-im-redis-1 redis-cli ZRANGE chat:gid:1:to:uid:zset 0 -1 WITHSCORES
```

**预期出参**

| Key | 预期成员 |
|-----|----------|
| `chat:gid:1:to:nid:zset` | 含 **20001** 和 **20002**（score 为 nid 或时间戳，非空即可） |
| `chat:gid:1:to:uid:zset` | 含 **100001**、**100002** |

**重启抽检（可选，验证持久化）**

```bash
docker restart hi-im-redis-1
# 等待 healthy 后重复上面 ZRANGE，成员集合不变
```

- [ ] 2.3 Redis gid→nid / gid→uid 正确
- [ ] 2.3（可选）redis restart 后 key 仍在

---

## 3. 发消息 — 浏览器操作（对应 sunchao_todo1 §2.1–2.2）

**操作**

1. 窗口 A 依次发送：`100001+1` … `100001+5`（可连发，间隔 ≥ 200ms 便于 grep）
2. 窗口 B 依次发送：`100002+1` … `100002+5`

**预期 — 发送方窗口**

- 每条有 **灰色斜体** 本地回显 `[uid xxx] 10000x+N`
- 每条有 **GROUP_CHAT_ACK**（日志 `recv cmd=0x30c` 或 ack ok）— 表示 msgsvr 已处理

**预期 — 接收方窗口 B（A 发的 5 条）**

- 收到 **5 条** `[uid 100001] 100001+N`（N=1..5），**不是**只有 1 条
- **不应**把 `[uid undefined]` 当成有效业务消息

**预期 — 接收方窗口 A（B 发的 5 条）**

- 收到 **5 条** `[uid 100002] 100002+N`

- [ ] 3.1 A→B 五收五（目检 B 窗口）
- [ ] 3.2 B→A 五收五（目检 A 窗口）

若 3.1 / 3.2 任一 FAIL，继续 §4 逐条定位，**不要**跳过。

---

## 4. 单条消息全链路追踪（A→B，以 `100001+3` 为例）

对 **每一条** A 发出的 `100001+N`（N=1..5）重复本表；B→A 方向把 gateway-1/2 对调、`text=100002+N`。

设 `TEXT='100001+3'`。

### 节点 1 — 客户端 A（WS 上行）

| 项 | 内容 |
|----|------|
| 入参 | WS 帧 `cmd=0x030B`，body 含 `gid=1, uid=100001, text=100001+3` |
| 操作 | 发送该条后看 A 窗口日志 |
| 预期出参 | 本地回显 + `recv cmd=0x30c`（ACK）；无 WS close |

- [ ] N=1 节点1 ok
- [ ] N=2 节点1 ok
- [ ] N=3 节点1 ok
- [ ] N=4 节点1 ok
- [ ] N=5 节点1 ok

### 节点 2 — gateway-1 上行

```bash
docker logs hi-im-gateway-1 2>&1 | grep "$TEXT"
```

| 预期 | 说明 |
|------|------|
| 有 uplink / publish 相关日志（含 text 或 seq） | 表示 GW1 收到并交给 hub |
| 无 `err` / `failed` | |

- [ ] N=1..5 节点2 ok（A 方向）

### 节点 3 — hub FORWARD → BACKEND（msgsvr）

hub 成功路径 **通常静默**；失败才有日志。

```bash
docker logs hi-im-hub-1 2>&1 | grep -E 'bridge|distributor|0x30[bB]|no subscribers' | tail -20
```

| 预期 | 说明 |
|------|------|
| **无** `forward publish cmd=0x30b err=no subscribers` | SUB 正常 |
| **无** `distributor queue full` / `drop` | 队列未满 |

- [ ] N=1..5 节点3 ok

### 节点 4 — msgsvr 收包 + Redis 查路由 + fan-out

```bash
docker logs hi-im-msgsvr-1 2>&1 | grep "$TEXT"
```

| 预期出参（每条 TEXT 各一行或多行） |
|-------------------------------------|
| `group-chat: received gid=1 uid=100001 ... text=100001+3` |
| `group-chat: fan-out dest ok ... destNid=20001 ... text=100001+3` |
| `group-chat: fan-out dest ok ... destNid=20002 ... text=100001+3` |
| `group-chat fan-out ok gid=1 ...` |
| **无** `partial fan-out` 且缺 20002（若出现 partial，记录 failedNids） |

- [ ] N=1 节点4 ok（destNid 20001+20002）
- [ ] N=2 节点4 ok
- [ ] N=3 节点4 ok
- [ ] N=4 节点4 ok
- [ ] N=5 节点4 ok

**若节点4 缺 `destNid=20002`** → 根因在 msgsvr 之前（Redis gid→nid）或 msgsvr fan-out，**不是** gateway-2 问题。

### 节点 5 — hub async_send → gateway-2

```bash
docker logs hi-im-hub-1 2>&1 | grep -E "20002|$TEXT" | tail -10
docker logs hi-im-gateway-2-1 2>&1 | grep "hub tcp recv" | grep "$TEXT"
```

| 预期 | 说明 |
|------|------|
| gateway-2 有 `hub tcp recv ... text=100001+3`（或等价含 TEXT 的行） | hub→GW2 TCP 到达 |
| hub **无** `[bridge] backend async_send nid=20002 err=...` | |

**历史断点**：msgsvr `fan-out dest ok destNid=20002` 有，但 gateway-2 **无** `hub tcp recv` → 丢失在 **hub→gateway-2**。

- [ ] N=1 节点5 ok
- [ ] N=2 节点5 ok
- [ ] N=3 节点5 ok
- [ ] N=4 节点5 ok
- [ ] N=5 节点5 ok

### 节点 6 — gateway-2 第二段 fan-out（ImGroup → WS）

```bash
docker logs hi-im-gateway-2-1 2>&1 | grep "$TEXT"
```

| 预期顺序 | 日志关键字 |
|----------|------------|
| 6a | `group-chat downlink: recv ... text=100001+3` |
| 6b | `downlink queued` 或 `PostDownlink` 成功类 |
| 6c | `ws write ok`（或 send ok） |
| **无** | `queue full`、`send failed`、`no ImGroup members` |

- [ ] N=1 节点6 ok
- [ ] N=2 节点6 ok
- [ ] N=3 节点6 ok
- [ ] N=4 节点6 ok
- [ ] N=5 节点6 ok

### 节点 7 — 客户端 B（WS 下行）

| 预期出参 | B 窗口出现 `[uid 100001] 100001+3` |
|----------|-------------------------------------|

- [ ] N=1 节点7 ok
- [ ] N=2 节点7 ok
- [ ] N=3 节点7 ok
- [ ] N=4 节点7 ok
- [ ] N=5 节点7 ok

---

## 5. B→A 方向（`100002+N` → gateway-1 → 窗口 A）

与 §4 对称，**gateway-1 / gateway-2 角色对调**：

| 阶段 | 检查容器 | 关键预期 |
|------|----------|----------|
| msgsvr fan-out | msgsvr | `destNid=20001` **和** `destNid=20002` 均 ok |
| hub→GW1 | gateway-1 | `hub tcp recv text=100002+N` |
| GW1 downlink | gateway-1 | `group-chat downlink: recv` → `ws write ok` |
| 客户端 A | 浏览器 | `[uid 100002] 100002+N` |

快捷命令（以 `TEXT='100002+3'` 为例）：

```bash
TEXT='100002+3'
docker logs hi-im-msgsvr-1 2>&1 | grep "$TEXT"
docker logs hi-im-gateway-1 2>&1 | grep "$TEXT"
docker logs hi-im-gateway-2-1 2>&1 | grep "$TEXT"   # GW2 也应 fan-out ok，B 本地可能也有 recv
```

- [ ] 5.1 B→A N=1..5 全链路 ok

---

## 6. 断点速查表

| 最后成功的节点 | 首先失败的节点 | 最可能根因 | 下一步 |
|----------------|----------------|------------|--------|
| — | 2.1 ONLINE | hub SUB / usrsvr | `make m6-heal` |
| 2.2 建群/加群 | 3.x 收不到 | ImGroupJoin 未执行 | 查 gateway ImGroupJoin 日志 |
| 节点4 msgsvr | 节点5 GW2 无 tcp recv | **hub→gateway-2 丢包** | hub distributor / AsyncSend |
| 节点5 tcp recv | 节点6 无 downlink | gateway downlink 队列 / writeC 阻塞 | hi-im-gateway outbound |
| 节点6 ws write ok | 节点7 浏览器无 | demo / pb.js / 前端过滤 | 查 `[uid undefined]` |
| 节点4 缺 destNid=20002 | — | Redis gid→nid 或 msgsvr fan-out | ZRANGE + msgsvr partial |

---

## 7. 一键 grep 脚本（可选）

```bash
# 用法: ./scripts/trace-one-msg.sh '100001+3'
TEXT="${1:?usage: trace-one-msg.sh TEXT}"
echo "=== msgsvr ==="
docker logs hi-im-msgsvr-1 2>&1 | grep "$TEXT" || echo "(none)"
echo "=== gateway-1 ==="
docker logs hi-im-gateway-1 2>&1 | grep "$TEXT" || echo "(none)"
echo "=== gateway-2 ==="
docker logs hi-im-gateway-2-1 2>&1 | grep "$TEXT" || echo "(none)"
echo "=== hub (errors) ==="
docker logs hi-im-hub-1 2>&1 | grep -E 'distributor|async_send.*2000[12]|no subscribers' | tail -5
```

- [ ] 7 已对至少 1 条失败消息跑过 trace

---

## 8. 完成标准（对应 sunchao_todo1 §2.5）

- [ ] §1 前置全部打勾
- [ ] §2 建群/加群 + Redis 持久化 ok
- [ ] §3 浏览器十收十（A→B 五 + B→A 五）
- [ ] §4 五条 A→B 逐节点全部 ok
- [ ] §5 五条 B→A 逐节点全部 ok

**当 §8 全部 [x]**：按 sunchao_todo1 的推论，**不应再出现**跨 Gateway 群聊丢消息。若仍出现，把 FAIL 步骤编号和 grep 输出贴到 `debug_lose_message_process_detail.log`，我们继续修。

---

## 9. 与自动化冒烟的关系

浏览器全部通过后，可选终端复核（排除前端因素）：

```bash
cd examples/smoke-group
HIIM_USRSVR_URL=http://127.0.0.1:8088 \
HIIM_GATEWAY_A_WS=ws://127.0.0.1:28080/ws \
HIIM_GATEWAY_B_WS=ws://127.0.0.1:28081/ws \
go run . -burst 10
```

预期：`M6 PASS: burst group chat OK`

- [ ] 9 burst 通过（可选）
