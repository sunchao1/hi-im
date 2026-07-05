# 多 Hub 设计方案 — 各服务细则

> 总览：[hi-im-档C-多hub设计方案.md](../hi-im-档C-多hub设计方案.md)

| 服务 | 仓库 | 文档 | 横向扩 Pod |
|------|------|------|------------|
| Hub 分片 | hi-im-core | [hi-im-hub.md](./hi-im-hub.md) | ⚠️ 增 shard（STS） |
| WebSocket 接入 | hi-im-gateway | [hi-im-gateway.md](./hi-im-gateway.md) | ✅ HPA |
| 群聊 / 私聊 | hi-im-msgsvr | [hi-im-msgsvr.md](./hi-im-msgsvr.md) | ⚠️ Kafka/单活 |
| 用户 / 在线 | hi-im-usrsvr | [hi-im-usrsvr.md](./hi-im-usrsvr.md) | ✅ HPA |
| 聊天室 / 削峰 | hi-im-chatroom、hi-im-roomfanout | [hi-im-chatroom.md](./hi-im-chatroom.md) | ✅ partition |
| 发号 | hi-im-seqsvr | [hi-im-seqsvr.md](./hi-im-seqsvr.md) | ⚠️ 号段池 |

**库（不独立部署）**：`hi-im-api`、`hi-im-hubclient` — 随各 L3 服务发版，无 Pod 扩缩。
