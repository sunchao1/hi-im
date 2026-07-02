// hubclient-stub is a minimal M3 smoke helper: FORWARD consumer or BACKEND producer.
package main

import (
	"context"
	"encoding/binary"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/sunchao1/hi-im-api/pkg/im/cmd"
	"github.com/sunchao1/hi-im-hubclient/pkg/hubclient"
)

func main() {
	role := flag.String("role", "", "consumer (FORWARD) or producer (BACKEND)")
	count := flag.Int("count", 1, "producer: number of frames to send")
	flag.Parse()

	if *role != "consumer" && *role != "producer" {
		fmt.Fprintln(os.Stderr, "usage: hubclient-stub --role=consumer|producer [--count=N]")
		os.Exit(2)
	}

	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	user := envOr("HIIM_AUTH_USER", "proxy")
	pass := envOr("HIIM_AUTH_PASS", "proxy")
	benchCmd := parseBenchCmd(envOr("HIIM_BENCH_CMD", "0x030B"))

	switch *role {
	case "consumer":
		runConsumer(log, user, pass, benchCmd)
	case "producer":
		runProducer(log, user, pass, benchCmd, *count)
	}
}

func runConsumer(log *slog.Logger, user, pass string, benchCmd uint32) {
	forwardAddr := envOr("HIIM_FORWARD_ADDR", "")
	if forwardAddr == "" {
		log.Error("HIIM_FORWARD_ADDR is required for consumer")
		os.Exit(1)
	}

	nid := mustU32Env("HIIM_NID")
	stateFile := envOr("HIIM_SMOKE_STATE_FILE", "")
	readyFile := envOr("HIIM_SMOKE_READY_FILE", "")

	var recvCount atomic.Int32

	cfg := hubclient.DefaultConfig()
	cfg.Addr = forwardAddr
	cfg.NID = nid
	cfg.GID = 1
	cfg.User = user
	cfg.Pass = pass

	client, err := hubclient.New(cfg)
	if err != nil {
		log.Error("hubclient.New", "err", err)
		os.Exit(1)
	}

	if err := client.RegisterHandler(benchCmd, func(cmd, origNid uint32, payload []byte) {
		n := recvCount.Add(1)
		log.Info("SMOKE recv frame", "recv", n, "cmd", fmt.Sprintf("0x%04X", cmd), "origNid", origNid)
		if stateFile != "" {
			_ = os.WriteFile(stateFile, []byte(strconv.Itoa(int(n))), 0o644)
		}
	}); err != nil {
		log.Error("RegisterHandler", "err", err)
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	if err := client.Start(ctx); err != nil {
		log.Error("Start", "err", err)
		os.Exit(1)
	}
	defer client.Close()

	waitCtx, waitCancel := context.WithTimeout(ctx, 30*time.Second)
	defer waitCancel()
	if err := client.WaitReady(waitCtx); err != nil {
		log.Error("WaitReady", "err", err)
		os.Exit(1)
	}

	if readyFile != "" {
		if err := os.WriteFile(readyFile, []byte("ok"), 0o644); err != nil {
			log.Error("write ready file", "err", err)
			os.Exit(1)
		}
	}
	log.Info("SMOKE consumer ready", "addr", forwardAddr, "nid", nid)

	<-ctx.Done()
}

func runProducer(log *slog.Logger, user, pass string, benchCmd uint32, count int) {
	backendAddr := envOr("HIIM_BACKEND_ADDR", "")
	if backendAddr == "" {
		log.Error("HIIM_BACKEND_ADDR is required for producer")
		os.Exit(1)
	}

	producerNID := mustU32Env("HIIM_NID")
	destNID := mustU32Env("HIIM_DEST_NID")

	cfg := hubclient.DefaultConfig()
	cfg.Addr = backendAddr
	cfg.NID = producerNID
	cfg.GID = 1
	cfg.User = user
	cfg.Pass = pass

	client, err := hubclient.New(cfg)
	if err != nil {
		log.Error("hubclient.New", "err", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := client.Start(ctx); err != nil {
		log.Error("Start", "err", err)
		os.Exit(1)
	}
	defer client.Close()

	if err := client.WaitReady(ctx); err != nil {
		log.Error("WaitReady", "err", err)
		os.Exit(1)
	}

	imFrame := make([]byte, 48)
	binary.BigEndian.PutUint32(imFrame[0:4], benchCmd)
	binary.BigEndian.PutUint32(imFrame[4:8], destNID)

	for i := 0; i < count; i++ {
		if err := client.AsyncSend(benchCmd, destNID, imFrame); err != nil {
			log.Error("AsyncSend", "err", err, "seq", i+1)
			os.Exit(1)
		}
		log.Info("SMOKE sent frame", "seq", i+1, "destNid", destNID)
	}

	// Allow hubclient send queue to flush before tearing down the session.
	time.Sleep(500 * time.Millisecond)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func mustU32Env(key string) uint32 {
	v := os.Getenv(key)
	if v == "" {
		fmt.Fprintf(os.Stderr, "%s is required\n", key)
		os.Exit(1)
	}
	n, err := parseU32(v)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", key, err)
		os.Exit(1)
	}
	return n
}

func parseBenchCmd(s string) uint32 {
	if s == "" || s == "benchCmd" {
		return cmd.CMD_GROUP_CHAT
	}
	v, err := parseU32(s)
	if err != nil {
		fmt.Fprintf(os.Stderr, "HIIM_BENCH_CMD: %v\n", err)
		os.Exit(1)
	}
	return v
}

func parseU32(s string) (uint32, error) {
	s = strings.TrimSpace(s)
	v, err := strconv.ParseUint(s, 0, 32)
	if err != nil {
		return 0, err
	}
	return uint32(v), nil
}
