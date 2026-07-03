const CMD = {
  ONLINE: 0x0101,
  ONLINE_ACK: 0x0102,
  GROUP_CREAT: 0x0301,
  GROUP_CREAT_ACK: 0x0302,
  GROUP_JOIN: 0x0305,
  GROUP_JOIN_ACK: 0x0306,
  GROUP_CHAT: 0x030b,
  GROUP_CHAT_ACK: 0x030c,
};

const HEAD_SIZE = 52;

const state = {
  uid: 100001,
  sid: 0,
  wsURL: "",
  gid: 0,
  seq: 1,
  ws: null,
  pendingOnline: null,
  onlineReady: false,
};

const $ = (id) => document.getElementById(id);

function packMsg(cmd, sid, seq, body) {
  const buf = new ArrayBuffer(HEAD_SIZE + body.length);
  const view = new DataView(buf);
  view.setUint32(0, cmd, false);
  view.setUint32(4, body.length, false);
  setUint64(view, 8, sid);
  setUint64(view, 16, 0);
  view.setUint32(24, 0, false);
  setUint64(view, 28, seq);
  new Uint8Array(buf, HEAD_SIZE).set(body);
  return buf;
}

function setUint64(view, offset, value) {
  const hi = Math.floor(value / 0x100000000);
  const lo = value >>> 0;
  view.setUint32(offset, hi, false);
  view.setUint32(offset + 4, lo, false);
}

function parseMsg(buf) {
  const view = new DataView(buf);
  return {
    cmd: view.getUint32(0, false),
    body: new Uint8Array(buf, HEAD_SIZE),
  };
}

function log(line, cls) {
  const el = document.createElement("div");
  el.className = "msg" + (cls ? " " + cls : "");
  el.textContent = `[${new Date().toLocaleTimeString()}] ${line}`;
  $("log").prepend(el);
}

function setStatus(text, ok) {
  $("status").textContent = text;
  $("status").className = ok ? "ok" : "err";
}

function setGroupActionsEnabled(on) {
  state.onlineReady = on;
  for (const id of ["creatBtn", "joinBtn"]) {
    const el = $(id);
    el.classList.toggle("btn-disabled", !on);
    el.setAttribute("aria-disabled", on ? "false" : "true");
  }
}

function parseGidFromOk(errmsg) {
  return errmsg.startsWith("Ok:") ? Number(errmsg.slice(3)) : 0;
}

function waitOnlineAck(timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      state.pendingOnline = null;
      reject(new Error("ONLINE-ACK 超时：请确认 gateway 已启动 (make m6-demo)"));
    }, timeoutMs);
    state.pendingOnline = { resolve, reject, timer };
  });
}

async function goOnline() {
  state.uid = Number($("uid").value);
  $("wsUrl").value = DemoCommon.gatewayWS();
  setGroupActionsEnabled(false);
  $("sendBtn").disabled = true;
  $("chatBox").disabled = true;

  await DemoCommon.registerUser(state, log);
  await connectWs();

  const ackWait = waitOnlineAck();
  send(
    CMD.ONLINE,
    PB.encodeOnline({
      uid: state.uid,
      sid: state.sid,
      token: "demo",
      app: "hi-im-demo",
      version: "1.0",
      terminal: 1,
    })
  );
  await ackWait;
}

function connectWs() {
  return new Promise((resolve, reject) => {
    if (state.ws) state.ws.close();
    const ws = new WebSocket(state.wsURL);
    ws.binaryType = "arraybuffer";
    state.ws = ws;
    ws.onopen = () => {
      setStatus("WS connected", true);
      resolve();
    };
    ws.onerror = () => reject(new Error("websocket 连接失败，请确认 gateway 端口可达"));
    ws.onclose = () => {
      setStatus("WS closed", false);
      if (state.pendingOnline) {
        clearTimeout(state.pendingOnline.timer);
        state.pendingOnline.reject(new Error("连接在 ONLINE 完成前关闭"));
        state.pendingOnline = null;
      }
    };
    ws.onmessage = (ev) => onMessage(ev.data);
  });
}

function send(cmd, bodyBytes) {
  if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
    throw new Error("WebSocket 未连接，请先点「注册并连接」");
  }
  state.ws.send(packMsg(cmd, state.sid, state.seq++, bodyBytes || new Uint8Array(0)));
}

function onMessage(buf) {
  const msg = parseMsg(buf);
  switch (msg.cmd) {
    case CMD.ONLINE_ACK: {
      const ack = PB.decodeOnlineAck(msg.body);
      const code = ack.code ?? 0;
      if (code !== 0) {
        log(`ONLINE-ACK error: ${ack.errmsg || code}`, "err");
        if (state.pendingOnline) {
          clearTimeout(state.pendingOnline.timer);
          state.pendingOnline.reject(new Error(ack.errmsg || `online code=${code}`));
          state.pendingOnline = null;
        }
        return;
      }
      state.seq = Number(ack.seq) + 1;
      setGroupActionsEnabled(true);
      log("ONLINE ok");
      if (state.pendingOnline) {
        clearTimeout(state.pendingOnline.timer);
        state.pendingOnline.resolve();
        state.pendingOnline = null;
      }
      break;
    }
    case CMD.GROUP_CREAT_ACK: {
      const ack = PB.decodeSimpleAck(msg.body);
      const code = ack.code ?? 0;
      if (code !== 0) {
        log(`CREAT-ACK 失败: ${ack.errmsg || code}`, "err");
        return;
      }
      const gid = parseGidFromOk(ack.errmsg);
      if (!gid) {
        log(`CREAT-ACK 无 gid: ${ack.errmsg}`, "err");
        return;
      }
      state.gid = gid;
      $("gid").value = String(gid);
      $("sendBtn").disabled = false;
      $("chatBox").disabled = false;
      log(`建群成功 gid=${gid}`, "sys");
      break;
    }
    case CMD.GROUP_JOIN_ACK: {
      const ack = PB.decodeSimpleAck(msg.body);
      const code = ack.code ?? 0;
      if (code !== 0) {
        log(`JOIN-ACK 失败: ${ack.errmsg || code}`, "err");
        return;
      }
      const gid = parseGidFromOk(ack.errmsg) || Number($("gid").value);
      if (gid) {
        state.gid = gid;
        $("gid").value = String(gid);
      }
      $("sendBtn").disabled = false;
      $("chatBox").disabled = false;
      log(`加群成功 gid=${$("gid").value}`, "sys");
      break;
    }
    case CMD.GROUP_CHAT: {
      const chat = PB.decodeGroupChat(msg.body);
      log(`[uid ${chat.uid}] ${chat.text}`);
      break;
    }
    default:
      log(`recv cmd=0x${msg.cmd.toString(16)}`, "sys");
  }
}

function createGroup() {
  if (!state.onlineReady) {
    log("请先点「注册并连接」，等待日志出现 ONLINE ok", "err");
    return;
  }
  const name = $("groupName").value.trim() || "demo-group";
  log(`创建群中 name=${name}...`, "sys");
  try {
    send(
      CMD.GROUP_CREAT,
      PB.encodeGroupCreat({
        uid: state.uid,
        name,
        desc: "hi-im M6",
      })
    );
  } catch (e) {
    log(String(e.message || e), "err");
  }
}

function joinGroup() {
  if (!state.onlineReady) {
    log("请先点「注册并连接」，等待日志出现 ONLINE ok", "err");
    return;
  }
  const gid = Number($("gid").value);
  if (!gid) {
    log("填写 GID", "err");
    return;
  }
  send(CMD.GROUP_JOIN, PB.encodeGroupJoin({ uid: state.uid, gid }));
}

function sendChat() {
  const text = $("chatBox").value.trim();
  const gid = Number($("gid").value) || state.gid;
  if (!text || !gid) return;
  send(
    CMD.GROUP_CHAT,
    PB.encodeGroupChat({
      uid: state.uid,
      gid,
      level: 0,
      time: Math.floor(Date.now() / 1000),
      text,
    })
  );
  $("chatBox").value = "";
}

$("gwA").textContent = "ws://127.0.0.1:28080/ws (?gw=1)";
$("gwB").textContent = "ws://127.0.0.1:28081/ws (?gw=2)";
$("wsUrl").value = DemoCommon.gatewayWS();

$("goBtn").addEventListener("click", () => {
  goOnline().catch((e) => {
    setStatus(String(e.message || e), false);
    log(String(e.message || e), "err");
  });
});
$("creatBtn").addEventListener("click", createGroup);
$("joinBtn").addEventListener("click", joinGroup);
$("sendBtn").addEventListener("click", sendChat);
$("chatBox").addEventListener("keydown", (e) => {
  if (e.key === "Enter") sendChat();
});
