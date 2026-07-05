# hi-im 文档

> **hi-im** 是生态 **主仓**：档 C 总方案、Compose/K8s 编排、版本矩阵、集成冒烟。  
> **许可证**：Apache License 2.0（见仓库根目录 `LICENSE`）

---

## 阅读顺序

| 顺序 | 文档 | 内容 |
|------|------|------|
| 1 | [hi-im-档C技术方案设计.md](hi-im-档C技术方案设计.md) | 生态总览：档 C 架构、11 仓、M1～M9 |
| 1b | [hi-im-档C-多hub设计方案.md](hi-im-档C-多hub设计方案.md) | **K8s 多 Hub 分片**、各服务横向扩缩容 |
| 2 | [技术设计文档.md](技术设计文档.md) | **本仓**：Compose profile、versions.lock、K8s、冒烟脚本 |
| 3 | [M1-实施清单.md](M1-实施清单.md) | 生态 **M3** 任务（最小 Compose + unicast 冒烟） |

### 问题与踩坑

| 文档 | 内容 |
|------|------|
| [系统问题收集/问题集合1.md](系统问题收集/问题集合1.md) | Hub 队列 MPSC/SPSC、拼帧、跨 Gateway 群聊丢消息（2026-07） |

---

## 里程碑 ↔ 本仓交付

| 生态 | 本仓重点 | 冒烟 |
|------|----------|------|
| M3 | Compose + hubclient stub | `make m3-smoke` ✅ |
| M4～M5 | 叠加 seqsvr / usrsvr / gateway | — |
| M6 | 群聊 compose + `m6-group-chat` | — |
| M8 | K8s 2 shard + Ingress | — |
| M9 | Kafka + roomfanout | — |

---

## 子仓库设计文档

| 仓库 | 文档 |
|------|------|
| hi-im-core | [doc/](https://github.com/sunchao1/hi-im-core/tree/main/doc) |
| hi-im-api | [doc/](https://github.com/sunchao1/hi-im-api/tree/main/doc) |
| hi-im-hubclient | [doc/](https://github.com/sunchao1/hi-im-hubclient/tree/main/doc) |
| hi-im-gateway 等 L3 | 各仓 `doc/`（随里程碑补齐） |

---

## 角色对照

```text
档 C 总方案     →  hi-im/doc/hi-im-档C技术方案设计.md（canonical）
编排 / 冒烟     →  hi-im/doc/技术设计文档.md（本仓）
组件实现细节   →  各子仓库 doc/
```
