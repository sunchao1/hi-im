// Copyright 2026 sunchao1
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// smoke-group runs M6 dual-gateway group chat verification (ported from beehive-im/tools/smoke-group).
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	imv1 "github.com/sunchao1/hi-im-api/gen/go/im/v1"
	"github.com/sunchao1/hi-im-api/pkg/im/cmd"
	"github.com/sunchao1/hi-im-api/pkg/im/header"
	"github.com/gorilla/websocket"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

type registerResp struct {
	UID    uint64 `json:"uid"`
	SID    int64  `json:"sid"`
	Code   int    `json:"code"`
	ErrMsg string `json:"errmsg"`
}

type wsClient struct {
	uid   uint64
	sid   uint64
	wsURL string
	seq   uint64
	conn  *websocket.Conn
}

func main() {
	usrsvr := env("HIIM_USRSVR_URL", "http://127.0.0.1:8081")
	gatewayA := env("HIIM_GATEWAY_A_WS", "ws://127.0.0.1:28080/ws")
	gatewayB := env("HIIM_GATEWAY_B_WS", "ws://127.0.0.1:28081/ws")

	onlineOnly := len(os.Args) > 1 && os.Args[1] == "-online-only"
	if onlineOnly {
		if err := probeOnline(usrsvr, gatewayA); err != nil {
			fmt.Fprintf(os.Stderr, "\nM6 online probe FAILED: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("M6 PASS: online probe OK")
		return
	}

	if err := run(usrsvr, gatewayA, gatewayB); err != nil {
		fmt.Fprintf(os.Stderr, "\nM6 smoke-group FAILED: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("M6 PASS: smoke-group OK")
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func probeOnline(usrsvr, gatewayA string) error {
	fmt.Println("[probe] register + online uid=100001")
	c, err := setupClient(usrsvr, gatewayA, 100001)
	if err != nil {
		return err
	}
	defer c.close()
	return nil
}

func run(usrsvr, gatewayA, gatewayB string) error {
	fmt.Println("[1/5] register + online uid=100001,100002 on two gateways")
	a, err := setupClient(usrsvr, gatewayA, 100001)
	if err != nil {
		return err
	}
	defer a.close()
	b, err := setupClient(usrsvr, gatewayB, 100002)
	if err != nil {
		return err
	}
	defer b.close()

	fmt.Println("[2/5] GROUP-CREAT by A")
	gid, err := a.groupCreat("smoke-group", "hi-im M6 demo")
	if err != nil {
		return err
	}
	fmt.Printf("       gid=%d\n", gid)

	fmt.Println("[3/5] GROUP-JOIN B")
	if err := b.groupJoin(gid); err != nil {
		return err
	}

	fmt.Println("[4/5] GROUP-CHAT (B waits)")
	ch := make(chan error, 1)
	go func() {
		_, payload, err := b.waitCmd(cmd.CMD_GROUP_CHAT, 20*time.Second)
		if err != nil {
			ch <- err
			return
		}
		chat := &imv1.GroupChat{}
		if err := proto.Unmarshal(payload, chat); err != nil {
			ch <- err
			return
		}
		if chat.GetText() != "group hello" {
			ch <- fmt.Errorf("unexpected text %q", chat.GetText())
			return
		}
		ch <- nil
	}()
	time.Sleep(1 * time.Second)
	if err := a.groupChat(gid, "group hello"); err != nil {
		return err
	}
	if err := <-ch; err != nil {
		return fmt.Errorf("user B recv: %w", err)
	}

	fmt.Println("[5/5] done")
	return nil
}

func setupClient(base, wsURL string, uid uint64) (*wsClient, error) {
	c, err := register(base, uid)
	if err != nil {
		return nil, err
	}
	c.wsURL = wsURL
	if err := c.connect(); err != nil {
		return nil, err
	}
	if err := c.online(); err != nil {
		return nil, err
	}
	return c, nil
}

func register(base string, uid uint64) (*wsClient, error) {
	u := fmt.Sprintf("%s/im/register?uid=%d&nation=1&city=1&town=1", base, uid)
	resp, err := http.Get(u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	var out registerResp
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	if out.Code != 0 || out.SID == 0 {
		return nil, fmt.Errorf("register failed code=%d %s", out.Code, out.ErrMsg)
	}
	return &wsClient{uid: uid, sid: uint64(out.SID), seq: 1}, nil
}

func (c *wsClient) connect() error {
	conn, _, err := websocket.DefaultDialer.Dial(c.wsURL, nil)
	if err != nil {
		return err
	}
	c.conn = conn
	return nil
}

func (c *wsClient) close() {
	if c.conn != nil {
		_ = c.conn.Close()
	}
}

func (c *wsClient) online() error {
	if err := c.send(cmd.CMD_ONLINE, &imv1.Online{
		Uid:      c.uid,
		Sid:      c.sid,
		Token:    "m6-smoke",
		App:      "hi-im-demo",
		Version:  "1.0",
		Terminal: 1,
	}); err != nil {
		return err
	}
	_, payload, err := c.waitCmd(cmd.CMD_ONLINE_ACK, 15*time.Second)
	if err != nil {
		return err
	}
	ack := &imv1.OnlineAck{}
	if err := proto.Unmarshal(payload, ack); err != nil {
		return err
	}
	if ack.GetCode() != 0 {
		return fmt.Errorf("online code=%d", ack.GetCode())
	}
	c.seq = ack.GetSeq() + 1
	return nil
}

func (c *wsClient) groupCreat(name, desc string) (uint64, error) {
	body := encodeGroupCreat(c.uid, name, desc)
	if err := c.sendRaw(cmd.CMD_GROUP_CREAT, body); err != nil {
		return 0, err
	}
	_, payload, err := c.waitCmd(cmd.CMD_GROUP_CREAT_ACK, 15*time.Second)
	if err != nil {
		return 0, err
	}
	ack := &imv1.GroupJoinAck{}
	if err := proto.Unmarshal(payload, ack); err != nil {
		return 0, err
	}
	if ack.GetCode() != 0 {
		return 0, fmt.Errorf("code=%d errmsg=%s", ack.GetCode(), ack.GetErrmsg())
	}
	return parseGidFromOk(ack.GetErrmsg())
}

func (c *wsClient) groupJoin(gid uint64) error {
	if err := c.send(cmd.CMD_GROUP_JOIN, &imv1.GroupJoin{
		Uid: c.uid,
		Gid: gid,
	}); err != nil {
		return err
	}
	_, payload, err := c.waitCmd(cmd.CMD_GROUP_JOIN_ACK, 15*time.Second)
	if err != nil {
		return err
	}
	ack := &imv1.GroupJoinAck{}
	if err := proto.Unmarshal(payload, ack); err != nil {
		return err
	}
	if ack.GetCode() != 0 {
		return fmt.Errorf("code=%d errmsg=%s", ack.GetCode(), ack.GetErrmsg())
	}
	return nil
}

func (c *wsClient) groupChat(gid uint64, text string) error {
	if err := c.send(cmd.CMD_GROUP_CHAT, &imv1.GroupChat{
		Uid:   c.uid,
		Gid:   gid,
		Level: 0,
		Time:  uint64(time.Now().Unix()),
		Text:  text,
	}); err != nil {
		return err
	}
	_, payload, err := c.waitCmd(cmd.CMD_GROUP_CHAT_ACK, 15*time.Second)
	if err != nil {
		return err
	}
	ack := &imv1.GroupChatAck{}
	if err := proto.Unmarshal(payload, ack); err != nil {
		return err
	}
	if ack.GetCode() != 0 {
		return fmt.Errorf("chat ack code=%d", ack.GetCode())
	}
	return nil
}

func encodeGroupCreat(uid uint64, name, desc string) []byte {
	var b []byte
	b = protowire.AppendTag(b, 1, protowire.VarintType)
	b = protowire.AppendVarint(b, uid)
	b = protowire.AppendTag(b, 3, protowire.BytesType)
	b = protowire.AppendString(b, name)
	b = protowire.AppendTag(b, 4, protowire.BytesType)
	b = protowire.AppendString(b, desc)
	return b
}

func parseGidFromOk(errmsg string) (uint64, error) {
	if strings.HasPrefix(errmsg, "Ok:") {
		return strconv.ParseUint(strings.TrimPrefix(errmsg, "Ok:"), 10, 64)
	}
	return 0, fmt.Errorf("creat ack missing gid in errmsg: %q", errmsg)
}

func (c *wsClient) send(cmdID uint32, msg proto.Message) error {
	body, err := proto.Marshal(msg)
	if err != nil {
		return err
	}
	return c.sendRaw(cmdID, body)
}

func (c *wsClient) sendRaw(cmdID uint32, body []byte) error {
	frame, err := packFrame(cmdID, c.sid, c.nextSeq(), body)
	if err != nil {
		return err
	}
	return c.conn.WriteMessage(websocket.BinaryMessage, frame)
}

func (c *wsClient) waitCmd(want uint32, timeout time.Duration) (*header.Header, []byte, error) {
	if err := c.conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return nil, nil, fmt.Errorf("read cmd 0x%04X: %w", want, err)
	}
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return nil, nil, fmt.Errorf("read cmd 0x%04X: %w", want, err)
		}
		hdr, payload, err := parseFrame(data)
		if err != nil {
			continue
		}
		if hdr.Cmd == want {
			return hdr, payload, nil
		}
	}
}

func (c *wsClient) nextSeq() uint64 {
	seq := c.seq
	c.seq++
	return seq
}

func packFrame(cmdID uint32, sid, seq uint64, body []byte) ([]byte, error) {
	h := &header.Header{
		Cmd:    cmdID,
		Length: uint32(len(body)),
		Sid:    sid,
		Seq:    seq,
	}
	buf, err := h.Pack()
	if err != nil {
		return nil, err
	}
	return append(buf, body...), nil
}

func parseFrame(data []byte) (*header.Header, []byte, error) {
	if len(data) < header.Size {
		return nil, nil, fmt.Errorf("short packet")
	}
	hdr, err := header.Unmarshal(data[:header.Size])
	if err != nil {
		return nil, nil, err
	}
	return hdr, data[header.Size:], nil
}
