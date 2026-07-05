追踪执行报告（只报问题，未改代码）
用 go run . -burst 5 模拟追踪计划 §3（等价于 A 发 100001+1~5、B 应收 5 条）。§3.1 已 FAIL，后续 §4/§5 在第一个断点处停止。

§1 前置 — 通过
步骤	结果
1.2 栈在跑
9 个 hi-im-* 容器 Up
1.3 健康检查
hub/gw1/gw2/usrsvr/msgsvr/demo 均 200 / ok
1.5
消息仍无 Mongo，以日志为准（已知）
§2 建群/加群 — 通过
burst 自动建群 gid=1、B 加群后 Redis 正常：

chat:gid:1:to:nid:zset → 20001, 20002
chat:gid:1:to:uid:zset → 100001, 100002
ImGroupJoin：gateway-1（sid=100001）、gateway-2（sid=100002）均有。

§3 发消息 — FAIL（第一个问题）
M6 burst FAILED: B recv from A: uid=100001 missing "100001+4" (got 4/5)
B 收到：+1, +2, +3, +5；缺 100001+4。
§3.2 B→A 未测（burst 在 A→B 阶段已失败）。

§4 逐节点定位 — 断点在 节点 5（hub → gateway-2）
以失败条 100001+4（seq=106）为例：

节点	结果	证据
4 msgsvr
✅
fan-out dest ok destNid=20001 和 destNid=20002，seq=106
5 hub→GW2
❌
gateway-2 无 hub tcp recv text=100001+4
6 GW2 downlink
❌（连带）
无 downlink / ws write
7 客户端 B
❌
收不到 100001+4
hub 日志 无任何 bridge/distributor/drop 报错（静默丢失）。

关键证据：hub 把 seq=106 发给了错误的 gateway
seq	文本	gateway-1 (20001)	gateway-2 (20002)
103
100001+1
0 次
2 次（重复）
104
+2
1
1
105
+3
1
1
106
+4
2 次（重复）
0 次 ← 断点
107
+5
1
1
msgsvr 对每条都 fan-out 到 20001+20002，但 hub 侧出现：

重复投递到 20001（seq 103、106 各 2 次）
漏投递到 20002（seq 103 本应 1 次却 2 次到 GW2；seq 106 完全没到 GW2）
这是 hi-im-core hub 路由/distributor 问题，不是浏览器、不是 Redis gid→nid、不是 gateway downlink 队列（GW2 根本没收到 tcp）。

建议先修这一个（你来修，我不动代码）
问题：msgsvr → hub AsyncSend(destNid=20002) 成功，但 hub 未把 seq=106 送到 gateway-2，反而 多送了一次到 gateway-1。

排查方向（hi-im-core）：

src/hub/bridge.cpp — backend async_send 按 nid 路由
src/hub/distributor.cpp — 队列投递 / 重复 / 丢弃
src/hub/reactor.cpp — 你本地也有未提交改动
修完：make m6-heal-down && make m6-heal，再跑：

cd examples/smoke-group
HIIM_USRSVR_URL=http://127.0.0.1:8088 \
HIIM_GATEWAY_A_WS=ws://127.0.0.1:28080/ws \
HIIM_GATEWAY_B_WS=ws://127.0.0.1:28081/ws \
go run . -burst 5
预期：M6 PASS: burst group chat OK（B 收齐 5 条后再继续 §5 B→A）。

附：次要现象（本轮不优先）
gateway-1 downlink 部分消息 uid=0（+2/+4/+5），与 demo [uid undefined] 相关，不是本次丢 +4 的直接原因（GW2 根本没收到包）。
seq=103 也有 GW1 漏收、GW2 重复，说明 hub 路由不稳定，不只 seq=106。
你修 hub 路由后告诉我，我再按追踪计划跑下一轮。