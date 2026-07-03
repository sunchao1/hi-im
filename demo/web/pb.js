// Minimal protobuf wire encoder/decoder for demo messages.
(function (global) {
  function writeVarint(v) {
    const out = [];
    let n = BigInt(v);
    while (n > 0x7fn) {
      out.push(Number((n & 0x7fn) | 0x80n));
      n >>= 7n;
    }
    out.push(Number(n & 0x7fn));
    return Uint8Array.from(out);
  }

  function readVarint(bytes, offset) {
    let result = 0n;
    let shift = 0n;
    let i = offset;
    while (i < bytes.length) {
      const b = BigInt(bytes[i++]);
      result |= (b & 0x7fn) << shift;
      if ((b & 0x80n) === 0n) break;
      shift += 7n;
    }
    return { value: result, offset: i };
  }

  function concat(arrs) {
    const len = arrs.reduce((s, a) => s + a.length, 0);
    const out = new Uint8Array(len);
    let o = 0;
    for (const a of arrs) {
      out.set(a, o);
      o += a.length;
    }
    return out;
  }

  function fieldUint64(n, v) {
    return concat([writeVarint((n << 3) | 0), writeVarint(v)]);
  }

  function fieldUint32(n, v) {
    return fieldUint64(n, v);
  }

  function fieldString(n, s) {
    const enc = new TextEncoder().encode(s);
    return concat([writeVarint((n << 3) | 2), writeVarint(enc.length), enc]);
  }

  function decodeFields(bytes) {
    const fields = {};
    let i = 0;
    while (i < bytes.length) {
      const tag = readVarint(bytes, i);
      i = tag.offset;
      const fieldNum = Number(tag.value >> 3n);
      const wire = Number(tag.value & 7n);
      if (wire === 0) {
        const val = readVarint(bytes, i);
        i = val.offset;
        fields[fieldNum] = Number(val.value);
      } else if (wire === 2) {
        const len = readVarint(bytes, i);
        i = len.offset;
        const end = i + Number(len.value);
        fields[fieldNum] = bytes.slice(i, end);
        i = end;
      } else {
        break;
      }
    }
    return fields;
  }

  function bytesToString(b) {
    if (b == null) return "";
    if (typeof b === "string") return b;
    if (b instanceof Uint8Array) return new TextDecoder().decode(b);
    if (b instanceof ArrayBuffer) return new TextDecoder().decode(b);
    return String(b);
  }

  function fieldStringValue(f, n) {
    const v = f[n];
    if (v == null) return "";
    return bytesToString(v);
  }

  global.PB = {
    encodeOnline({ uid, sid, token, app, version, terminal }) {
      const parts = [
        fieldUint64(1, uid),
        fieldUint64(2, sid),
        fieldString(3, token),
        fieldString(4, app),
        fieldString(5, version),
      ];
      if (terminal !== undefined) parts.push(fieldUint32(6, terminal));
      return concat(parts);
    },
    decodeOnlineAck(bytes) {
      const f = decodeFields(bytes);
      return {
        uid: f[1],
        sid: f[2],
        seq: f[3],
        code: f[7],
        errmsg: fieldStringValue(f, 8),
      };
    },
    encodeRoomJoin({ uid, rid }) {
      return concat([fieldUint64(1, uid), fieldUint64(2, rid)]);
    },
    decodeRoomJoinAck(bytes) {
      const f = decodeFields(bytes);
      return {
        uid: f[1],
        rid: f[2],
        gid: f[3],
        code: f[4],
        errmsg: fieldStringValue(f, 5),
      };
    },
    encodeRoomChat({ uid, rid, gid, level, time, text }) {
      return concat([
        fieldUint64(1, uid),
        fieldUint64(2, rid),
        fieldUint32(3, gid),
        fieldUint32(4, level),
        fieldUint64(5, time),
        fieldString(6, text),
      ]);
    },
    decodeRoomChat(bytes) {
      const f = decodeFields(bytes);
      return {
        uid: f[1],
        rid: f[2],
        gid: f[3],
        text: fieldStringValue(f, 6),
      };
    },
    decodeSimpleAck(bytes) {
      const f = decodeFields(bytes);
      return {
        code: f[1],
        errmsg: fieldStringValue(f, 2),
      };
    },
    encodeGroupCreat({ uid, name, desc }) {
      // gid 为 proto required；服务端 INCR 分配，客户端传 0 占位
      return concat([
        fieldUint64(1, uid),
        fieldUint64(2, 0),
        fieldString(3, name),
        fieldString(4, desc),
      ]);
    },
    encodeGroupJoin({ uid, gid }) {
      return concat([fieldUint64(1, uid), fieldUint64(2, gid)]);
    },
    encodeGroupInvite({ uid, gid, to }) {
      return concat([
        fieldUint64(1, uid),
        fieldUint64(2, gid),
        fieldUint64(3, to),
      ]);
    },
    encodeGroupQuit({ uid, gid }) {
      return concat([fieldUint64(1, uid), fieldUint64(2, gid)]);
    },
    encodeGroupDismiss({ uid, gid }) {
      return concat([fieldUint64(1, uid), fieldUint64(2, gid)]);
    },
    encodeGroupChat({ uid, gid, level, time, text }) {
      return concat([
        fieldUint64(1, uid),
        fieldUint64(2, gid),
        fieldUint32(3, level),
        fieldUint64(4, time),
        fieldString(5, text),
      ]);
    },
    decodeGroupChat(bytes) {
      const f = decodeFields(bytes);
      return {
        uid: f[1],
        gid: f[2],
        text: fieldStringValue(f, 5),
      };
    },
    decodeGroupNtf(bytes) {
      const f = decodeFields(bytes);
      return { uid: f[1], gid: f[2] };
    },
  };
})(window);
