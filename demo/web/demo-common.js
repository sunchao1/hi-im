(function (global) {
  function usrsvrOrigin() {
    return global.location.origin;
  }

  function gatewayWS() {
    const params = new URLSearchParams(global.location.search);
    const gw = params.get("gw") || "1";
    if (params.get("ws")) {
      return params.get("ws");
    }
    const port = gw === "2" ? "28081" : "28080";
    return `ws://127.0.0.1:${port}/ws`;
  }

  async function registerUser(state, log) {
    const url = `${usrsvrOrigin()}/im/register?uid=${state.uid}&nation=1&city=1&town=1`;
    const res = await fetch(url);
    const data = await res.json();
    if (data.code !== 0 || !data.sid) {
      throw new Error(data.errmsg || "register failed");
    }
    state.sid = data.sid;
    state.seq = 1;
    state.wsURL = gatewayWS();
    log(`register ok uid=${state.uid} sid=${state.sid} ws=${state.wsURL}`);
  }

  global.DemoCommon = {
    usrsvrOrigin,
    gatewayWS,
    registerUser,
  };
})(window);
