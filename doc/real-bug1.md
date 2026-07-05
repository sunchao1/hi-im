bug1:
根因是 hub 的 bridge.cpp 仍按旧 48 字节头在 offset 4 读 nid（实际是 Length），而非 hi-im-api 52 字节头 offset 24 的 destNid。正在集中常量、补回归测试并验证。

bug2:
定位到第二个 bug：DistQueue 是 SPSC 队列，但多个 worker 线程会并发调用 Publish/AsyncSend 入队，导致偶发丢包/重复路由。


分析结论：两个 bug 都存在，已修复
Bug 1：52 字节头 offset 错误 — 确认存在，已修
原代码（bridge.cpp 未提交前）：

// 注释写 48B，从 offset 4 读 nid — 实际是 Length 字段
static constexpr std::size_t kImHeaderNidOffset = 4;
对 "100001+4" 这类消息，body length ≈ 9，被当成 destNid=9 去路由 → 出现 gw1 重复收、gw2 漏收（与第一轮追踪完全吻合）。

修复：

新增 include/hiim/im/header.hpp（对齐 hi-im-api 52B 头，Nid @ offset 24）
bridge.cpp 改为 hiim::im::ReadDestNid(msg.payload)
distributor.cpp 丢弃日志同样用 offset 24
Bug 2：DistQueue 当 SPSC 多线程 Push — 确认存在，已修
多个 worker 并发调用 Publish/AsyncSend 往 同一个 SpscQueue 入队，而 distributor 线程同时在 Pop → 队列损坏 → 偶发丢包/重复路由。

修复：DistQueue 改为 MpscQueue（mutex + deque，真正的多生产者单消费者），queue_push.hpp 模板泛化以支持两种队列。

回归测试
新增 test/bridge_downlink_test.cpp，覆盖：

ReadDestNid offset 24 单元测试
双 gateway 顺序下行路由
20 轮双 fan-out（2 reactor / 4 worker，模拟生产配置）
本地跑通：

cd hi-im-core/build && make bridge_downlink_test && ./bridge_downlink_test
# bridge_downlink_test: OK
你需要做的
代码在 hi-im-core 本地未提交改动中，需重建 hub 镜像：

make m6-heal-down && make m6-heal
然后按追踪计划复测：

cd examples/smoke-group
HIIM_USRSVR_URL=http://127.0.0.1:8088 \
HIIM_GATEWAY_A_WS=ws://127.0.0.1:28080/ws \
HIIM_GATEWAY_B_WS=ws://127.0.0.1:28081/ws \
go run . -burst 5
预期：M6 PASS: burst group chat OK，B 收齐 100001+1~+5。

改动文件一览（hi-im-core）
文件	改动
include/hiim/im/header.hpp
新增，52B 头常量 + ReadDestNid
src/hub/bridge.cpp
用 offset 24 读 destNid
src/hub/queue.hpp
新增 MpscQueue
src/hub/context_impl.cpp
DistQueue 改 MpscQueue
src/hub/queue_push.hpp
PushWithBackoff 支持泛型队列
src/hub/distributor.cpp
丢弃日志增强
test/bridge_downlink_test.cpp
回归测试
CMakeLists.txt
注册测试
你 rebuild 后跑 burst，把结果告诉我，我们再继续追踪计划下一轮。


Bug 2：DistQueue 当 SPSC 多线程 Push — 确认存在，已修
多个 worker 并发调用 Publish/AsyncSend 往 同一个 SpscQueue 入队，而 distributor 线程同时在 Pop → 队列损坏 → 偶发丢包/重复路由。

修复：DistQueue 改为 MpscQueue（mutex + deque，真正的多生产者单消费者），queue_push.hpp 模板泛化以支持两种队列。

Bug3 已修：FrameBuffer::TryPopFrame 悬垂 span
根因
TryPopFrame 原先返回 FrameView{hdr, span(buf_)}，在 buf_.erase() 之后 span 失效。reactor 对 sticky TCP（msgsvr 连发 fan-out）会连续 TryPopFrame，第二帧 erase 后第一帧 payload 被读错 → 出现 同一 seq 重复进 GW1、漏 GW2。
TryPopFrame 在 erase 前把 payload 拷贝进 std::vector，避免 sticky fan-out 时第二帧 erase 后第一帧读到错误 dest_nid。
回归：TestStickyDualFanoutPayloadSurvivesPop、TestStickyDualFanoutRouting（单 TCP 双帧走完整 hub）
reactor 增加 [reactor] enqueue inbound 日志

修复（hi-im-core，本地未提交）
文件	改动
src/wire/frame_buffer.hpp
payload 改为 std::vector<uint8_t>，erase 前拷贝
src/hub/reactor.hpp/cpp
EnqueueInbound 按值接收 + move payload；[reactor] enqueue inbound 日志
test/frame_buffer_test.cpp
双 fan-out sticky 回归
test/bridge_downlink_test.cpp
新增 TestStickyDualFanoutRouting（单 TCP 写两帧，走完整 hub）
回归测试
frame_buffer_test: OK
bridge_downlink_test: OK（含 sticky dual fanout）
HIIM_TEST_CONCURRENT=1 bridge_downlink_test: OK（10 轮双 fan-out）
Docker 验证（已 make m6-heal 重建 hub）
原 bug 场景 A→B：已修复

上一轮失败的 seq=107（100001+5） 现在 hub 日志正确：

[reactor] ... im_dest_nid=20001 seq=107
[reactor] ... im_dest_nid=20002 seq=107
[bridge] backend recv dest_nid=20001 seq=107
[bridge] backend recv dest_nid=20002 seq=107   ← 不再漏 GW2
GW2 收到 +1~+5 全部 5 条，ws write ok 均有。

burst 输出：

[burst] A -> B          ← 通过（无 "B recv from A" 报错）
[burst] B -> A
B send 100002+1: ... use of closed network connection   ← 新问题
B→A 失败是 B 侧 WebSocket 已断开（与 hub 路由无关），需单独查 gateway-2 / smoke-group 在读空闲期是否被踢线。

