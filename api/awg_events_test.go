package main

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

// mockableStats lets a test script a sequence of `awg show` results.
type mockableStats struct {
	mu      sync.Mutex
	results []func() ([]TunnelInfo, error)
	calls   int
}

func (m *mockableStats) next() ([]TunnelInfo, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.calls >= len(m.results) {
		return []TunnelInfo{}, nil
	}
	r := m.results[m.calls]
	m.calls++
	return r()
}

func (m *mockableStats) callCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.calls
}

func installMockTunnelStats(t *testing.T, m *mockableStats) {
	t.Helper()
	orig := getTunnelStatsFunc
	getTunnelStatsFunc = m.next
	t.Cleanup(func() { getTunnelStatsFunc = orig })
}

func TestAWGEventLoopSeedThenDetectHandshake(t *testing.T) {
	baseline := func() ([]TunnelInfo, error) {
		return []TunnelInfo{
			{
				Name: "wg0",
				Peers: []PeerStat{
					{PublicKey: "ABCDEFGHIJKL", Endpoint: "1.2.3.4:51820", LatestHandshake: ""},
				},
			},
		}, nil
	}
	withHandshake := func() ([]TunnelInfo, error) {
		return []TunnelInfo{
			{
				Name: "wg0",
				Peers: []PeerStat{
					{PublicKey: "ABCDEFGHIJKL", Endpoint: "1.2.3.4:51820", LatestHandshake: "2026-05-18T10:30:00Z"},
				},
			},
		}, nil
	}

	mock := &mockableStats{results: []func() ([]TunnelInfo, error){baseline, withHandshake}}
	installMockTunnelStats(t, mock)

	store := NewLogStore(50)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan struct{})
	go func() {
		runAWGEventLoop(ctx, store, 10*time.Millisecond)
		close(done)
	}()

	// Wait for at least 2 polls.
	waitFor(t, time.Second, func() bool { return mock.callCount() >= 2 })
	cancel()
	<-done

	snap := store.Snapshot()
	if len(snap) < 2 {
		t.Fatalf("expected at least 2 events, got %d (%+v)", len(snap), snap)
	}

	// First event should be the seed "tunnel wg0 up..." message.
	if !strings.Contains(snap[0].Msg, "tunnel wg0") {
		t.Errorf("first event should be tunnel seed, got %q", snap[0].Msg)
	}
	// Subsequent event should be the handshake.
	foundHandshake := false
	for _, l := range snap[1:] {
		if strings.Contains(l.Msg, "handshake completed") {
			foundHandshake = true
		}
	}
	if !foundHandshake {
		t.Errorf("did not see handshake event in %+v", snap)
	}
}

func TestAWGEventLoopDetectPeerAppearAndGone(t *testing.T) {
	noPeers := func() ([]TunnelInfo, error) {
		return []TunnelInfo{{Name: "wg0", Peers: nil}}, nil
	}
	withPeer := func() ([]TunnelInfo, error) {
		return []TunnelInfo{
			{Name: "wg0", Peers: []PeerStat{{PublicKey: "NEWPEER1234567890", Endpoint: "5.6.7.8:51820"}}},
		}, nil
	}
	gone := func() ([]TunnelInfo, error) {
		return []TunnelInfo{{Name: "wg0", Peers: nil}}, nil
	}

	mock := &mockableStats{results: []func() ([]TunnelInfo, error){noPeers, withPeer, gone}}
	installMockTunnelStats(t, mock)

	store := NewLogStore(50)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan struct{})
	go func() {
		runAWGEventLoop(ctx, store, 10*time.Millisecond)
		close(done)
	}()

	waitFor(t, time.Second, func() bool { return mock.callCount() >= 3 })
	cancel()
	<-done

	var sawAppear, sawGone bool
	for _, l := range store.Snapshot() {
		if strings.Contains(l.Msg, "appeared on wg0") {
			sawAppear = true
		}
		if strings.Contains(l.Msg, "gone from wg0") {
			sawGone = true
		}
	}
	if !sawAppear {
		t.Error("did not see 'appeared' event")
	}
	if !sawGone {
		t.Error("did not see 'gone' event")
	}
}

func TestAWGEventLoopSilentOnSeedFailure(t *testing.T) {
	mock := &mockableStats{results: []func() ([]TunnelInfo, error){
		func() ([]TunnelInfo, error) { return nil, &mockErr{msg: "boom"} },
		func() ([]TunnelInfo, error) { return nil, &mockErr{msg: "boom"} },
	}}
	installMockTunnelStats(t, mock)

	store := NewLogStore(50)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan struct{})
	go func() {
		runAWGEventLoop(ctx, store, 10*time.Millisecond)
		close(done)
	}()

	waitFor(t, time.Second, func() bool { return mock.callCount() >= 2 })
	cancel()
	<-done

	// First failure happens during seed → no event. Second failure also no
	// event because we never seeded successfully.
	if n := len(store.Snapshot()); n != 0 {
		t.Errorf("expected 0 events on persistent failure, got %d", n)
	}
}

type mockErr struct{ msg string }

func (e *mockErr) Error() string { return e.msg }

func TestShortKey(t *testing.T) {
	cases := map[string]string{
		"":             "",
		"abc":          "abc",
		"abcdefgh":     "abcdefgh",
		"abcdefghijkl": "abcdefgh…",
	}
	for in, want := range cases {
		if got := shortKey(in); got != want {
			t.Errorf("shortKey(%q) = %q, want %q", in, got, want)
		}
	}
}

func waitFor(t *testing.T, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("timed out waiting for condition")
}
