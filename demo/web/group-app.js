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

const state = { uid: 100001, sid: 0, wsURL: "", gid: 0, seq: 1, ws: null };

const $ = (id) => document.getElementById(id);

function packMsg(cmd, sid, seq, body) {
  const buf = new ArrayBuffer(HEAD_SIZE + body.length);
  const view = new DataView(buf);
  view.setUint32(0, cmd, false);
  view.setUint32(4, body.length, false);
  setUint64(view, 8, sid);
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

function parseGidFromOk(errmsg) {
  return errmsg.startsWith("Ok:") ? Number(errmsg.slice(3)) : 0;
}

async function goOnline() {
  state.uid = Number($("uid").value);
  $("wsUrl").value = DemoCommon.gatewayWS();
  await DemoCommon.registerUser(state, log);
  await connectWs();
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
    ws.onerror = () => reject(new Error("websocket error"));
    ws.onmessage = (ev) => onMessage(ev.data);
  });
}

function send(cmd, bodyBytes) {
  state.ws.send(packMsg(cmd, state.sid, state.seq++, bodyBytes || new Uint8Array(0)));
}

function onMessage(buf) {
  const msg = parseMsg(buf);
  switch (msg.cmd) {
    case CMD.ONLINE_ACK: {
      const ack = PB.decodeOnlineAck(msg.body);
      if (ack.code !== 0) {
        log(`ONLINE-ACK error: ${ack.errmsg}`, "err");
        return;
      }
      state.seq = Number(ack.seq) + 1;
      $("creatBtn").disabled = false;
      $("joinBtn").disabled = false;
      log("ONLINE ok");
      break;
    }
    case CMD.GROUP_CREAT_ACK: {
      const ack = PB.decodeSimpleAck(msg.body);
      if (ack.code !== 0) {
        log(`CREAT-ACK: ${ack.errmsg}`, "err");
        return;
      }
      const gid = parseGidFromOk(ack.errmsg);
      state.gid = gid;
      $("gid").value = String(gid);
      $("sendBtn").disabled = false;
      $("chatBox").disabled = false;
      log(`建群成功 gid=${gid}`, "sys");
      break;
    }
    case CMD.GROUP_JOIN_ACK: {
      const ack = PB.decodeSimpleAck(msg.body);
      if (ack.code !== 0) {
        log(`JOIN-ACK: ${ack.errmsg}`, "err");
        return;
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
  send(
    CMD.GROUP_CREAT,
    PB.encodeGroupCreat({
      uid: state.uid,
      name: $("groupName").value.trim() || "demo-group",
      desc: "hi-im M6",
    })
  );
}

function joinGroup() {
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
