# hi-im 群聊 Demo（M6）

双窗口群聊演示，对照 beehive-im `demo/web/group.html`。

## 启动

```bash
# 在 hi-im 主仓；sibling 仓库与 hi-im 同级
make m6-demo
```

浏览器打开：

- 窗口 A：`http://127.0.0.1:8088/group.html?gw=1`（gateway 28080）
- 窗口 B：`http://127.0.0.1:8088/group.html?gw=2`（gateway 28081）

## 操作

| 步骤 | 窗口 A（uid=100001） | 窗口 B（uid=100002） |
|------|----------------------|----------------------|
| 1 | 注册并连接 | 注册并连接 |
| 2 | 创建群 | — |
| 3 | — | 填入同一 gid，加入群 |
| 4 | 互发群消息 | 互发群消息 |

## 端口冲突

若本机已有 `hiim-hub` 等占用 18080/28888，在 `deploy/compose/.env` 中改：

```bash
HIIM_HEALTH_HOST_PORT=18081
HIIM_FORWARD_HOST_PORT=28898
HIIM_BACKEND_HOST_PORT=28899
```

## 终端验收

```bash
make m6-smoke
```
