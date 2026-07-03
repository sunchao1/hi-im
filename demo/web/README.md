# hi-im 群聊 Demo（M6）

双窗口群聊演示，对照 beehive-im `demo/web/group.html`。

## 启动

```bash
# 在 hi-im 主仓；sibling 仓库与 hi-im 同级
make m6-demo
```

浏览器打开（端口见 `deploy/compose/.env` 的 `HIIM_DEMO_WEB_PORT`，默认 8088；本机若与 beehive 冲突可改为 **8089**）：

- 窗口 A：`http://127.0.0.1:8089/group.html?gw=1`（gateway 28080）
- 窗口 B：`http://127.0.0.1:8089/group.html?gw=2`（gateway 28081）

**勿打开 `8088/group.html`**：若本机跑着 beehive 旧 demo，那是另一个项目，会出现 `The string did not match the expected pattern` 等错误。

若出现 `ONLINE-ACK 超时`：

1. **推荐**：`make m6-heal`（按 hub → usrsvr → gateway 顺序重启并自动探测 ONLINE）
2. 或完整重建：`make m6-down && make m6-demo`
3. 浏览器 **硬刷新**（Cmd+Shift+R），确认地址是 **8089** 不是 8088

自检（注册后若仍超时）：

```bash
docker logs hi-im-gateway-1 2>&1 | grep 'online:' | tail -3
docker logs hi-im-usrsvr-1 2>&1 | grep 'online:' | tail -3   # 应有 online: ok
docker logs hi-im-hub-1 2>&1 | grep bridge | tail -3            # no subscribers = hub 订阅丢失
```

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
