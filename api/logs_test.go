package main

import (
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestLogStoreAppendAndSnapshot(t *testing.T) {
	store := NewLogStore(3)
	for _, msg := range []string{"first", "second", "third", "fourth"} {
		store.Append(LogLevelInfo, LogSourceAWG, msg)
	}

	snap := store.Snapshot()
	if len(snap) != 3 {
		t.Fatalf("expected 3 lines after capacity overflow, got %d", len(snap))
	}
	// Oldest ("first") should have been dropped.
	if snap[0].Msg != "second" || snap[2].Msg != "fourth" {
		t.Fatalf("unexpected order: %+v", snap)
	}
}

func TestLogStoreQueryFilters(t *testing.T) {
	store := NewLogStore(10)
	store.Append(LogLevelInfo, LogSourceAWG, "awg info 1")
	store.Append(LogLevelWarn, LogSourceAWG, "awg warn")
	store.Append(LogLevelError, LogSourceAPI, "api error")
	store.Append(LogLevelInfo, LogSourceAPI, "api info")

	tests := []struct {
		name   string
		query  LogQuery
		expect []string
	}{
		{
			name:   "no filter returns newest first",
			query:  LogQuery{},
			expect: []string{"api info", "api error", "awg warn", "awg info 1"},
		},
		{
			name:   "filter by level",
			query:  LogQuery{Filter: LogFilter{Levels: []string{LogLevelError, LogLevelWarn}}},
			expect: []string{"api error", "awg warn"},
		},
		{
			name:   "filter by source",
			query:  LogQuery{Filter: LogFilter{Sources: []string{LogSourceAWG}}},
			expect: []string{"awg warn", "awg info 1"},
		},
		{
			name:   "filter by both",
			query:  LogQuery{Filter: LogFilter{Levels: []string{LogLevelInfo}, Sources: []string{LogSourceAPI}}},
			expect: []string{"api info"},
		},
		{
			name:   "limit caps results",
			query:  LogQuery{Limit: 2},
			expect: []string{"api info", "api error"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			lines, _ := store.Query(tc.query)
			if len(lines) != len(tc.expect) {
				t.Fatalf("got %d lines, want %d: %+v", len(lines), len(tc.expect), lines)
			}
			for i, want := range tc.expect {
				if lines[i].Msg != want {
					t.Errorf("lines[%d].Msg = %q, want %q", i, lines[i].Msg, want)
				}
			}
		})
	}
}

func TestLogStoreQueryBeforeCursor(t *testing.T) {
	store := NewLogStore(10)
	var ids []string
	for i := 0; i < 5; i++ {
		// Spread timestamps so the IDs are strictly monotonic.
		time.Sleep(2 * time.Millisecond)
		l := store.Append(LogLevelInfo, LogSourceAWG, "msg")
		ids = append(ids, l.ID)
	}

	// Page through using `before` = oldest seen so far.
	page1, next1 := store.Query(LogQuery{Limit: 2})
	if len(page1) != 2 {
		t.Fatalf("page1: got %d lines, want 2", len(page1))
	}
	if next1 == "" {
		t.Fatal("page1: expected non-empty next cursor")
	}
	// Newest is ids[4], second-newest ids[3]. Next cursor = ids[3].
	if next1 != ids[3] {
		t.Errorf("next1 = %q, want %q", next1, ids[3])
	}

	page2, _ := store.Query(LogQuery{Limit: 2, Before: next1})
	if len(page2) != 2 {
		t.Fatalf("page2: got %d lines, want 2", len(page2))
	}
	if page2[0].ID != ids[2] || page2[1].ID != ids[1] {
		t.Errorf("page2 IDs = [%s, %s], want [%s, %s]", page2[0].ID, page2[1].ID, ids[2], ids[1])
	}
}

func TestLogStoreLimitClamping(t *testing.T) {
	store := NewLogStore(2000)
	for i := 0; i < 1500; i++ {
		store.Append(LogLevelInfo, LogSourceAWG, "msg")
	}

	// Limit 0 → default 200.
	lines, _ := store.Query(LogQuery{Limit: 0})
	if len(lines) != 200 {
		t.Errorf("Limit=0 → got %d, want 200", len(lines))
	}

	// Limit 5000 → clamped to 1000.
	lines, _ = store.Query(LogQuery{Limit: 5000})
	if len(lines) != 1000 {
		t.Errorf("Limit=5000 → got %d, want 1000", len(lines))
	}
}

func TestLogStoreSubscribeBroadcast(t *testing.T) {
	store := NewLogStore(10)

	sub := store.Subscribe(8)
	defer store.Unsubscribe(sub)

	go func() {
		store.Append(LogLevelInfo, LogSourceAWG, "broadcasted")
	}()

	ch, _, _ := sub.Recv()
	select {
	case event := <-ch:
		if event.Line.Msg != "broadcasted" {
			t.Errorf("got msg %q", event.Line.Msg)
		}
		if len(event.Raw) == 0 {
			t.Errorf("expected pre-marshaled bytes, got empty")
		}
	case <-time.After(time.Second):
		t.Fatal("did not receive broadcast")
	}
}

func TestLogStoreSubscribeOverflow(t *testing.T) {
	store := NewLogStore(100)

	// Tiny buffer so we overflow on the second append.
	sub := store.Subscribe(1)
	defer store.Unsubscribe(sub)

	store.Append(LogLevelInfo, LogSourceAWG, "1")
	store.Append(LogLevelInfo, LogSourceAWG, "2")
	store.Append(LogLevelInfo, LogSourceAWG, "3")

	_, overflow, _ := sub.Recv()
	select {
	case <-overflow:
		// expected
	case <-time.After(time.Second):
		t.Fatal("expected overflow signal, none received")
	}
}

func TestLogStoreCloseUnblocksSubscribers(t *testing.T) {
	store := NewLogStore(10)

	sub := store.Subscribe(8)
	_, _, done := sub.Recv()

	store.Close()

	select {
	case <-done:
		// expected
	case <-time.After(time.Second):
		t.Fatal("done channel should be closed after store.Close()")
	}
}

func TestLogStoreUnsubscribeIdempotent(t *testing.T) {
	store := NewLogStore(10)
	sub := store.Subscribe(8)

	store.Unsubscribe(sub)
	store.Unsubscribe(sub) // second call must not panic

	_, _, done := sub.Recv()
	select {
	case <-done:
		// expected
	case <-time.After(time.Second):
		t.Fatal("done channel should be closed after unsubscribe")
	}
}

func TestLogStoreConcurrentAppends(t *testing.T) {
	store := NewLogStore(1000)
	var wg sync.WaitGroup
	for w := 0; w < 10; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				store.Append(LogLevelInfo, LogSourceAWG, "concurrent")
			}
		}()
	}
	wg.Wait()

	snap := store.Snapshot()
	if len(snap) != 1000 {
		t.Errorf("expected 1000 lines, got %d", len(snap))
	}
}

func TestScrubberPrivateKey(t *testing.T) {
	s := NewScrubber()

	cases := []struct {
		in       string
		contains []string
		omits    []string
	}{
		{
			in:       "PrivateKey = aB12+/Cd==XYZ",
			contains: []string{"PrivateKey", "***REDACTED***"},
			omits:    []string{"aB12+/Cd==XYZ"},
		},
		{
			in:       "preshared_key=secret/payload",
			contains: []string{"preshared_key", "***REDACTED***"},
			omits:    []string{"secret/payload"},
		},
		{
			in:       "Authorization: Bearer abcdef1234567890abcdef1234567890",
			contains: []string{"Bearer", "***REDACTED***"},
			omits:    []string{"abcdef1234567890abcdef1234567890"},
		},
		{
			in:       "no secrets here, just chatter",
			contains: []string{"chatter"},
			omits:    []string{"REDACTED"},
		},
	}
	for _, tc := range cases {
		out := s.Scrub(tc.in)
		for _, want := range tc.contains {
			if !strings.Contains(out, want) {
				t.Errorf("scrub(%q) missing %q (got %q)", tc.in, want, out)
			}
		}
		for _, bad := range tc.omits {
			if strings.Contains(out, bad) {
				t.Errorf("scrub(%q) leaked %q (got %q)", tc.in, bad, out)
			}
		}
	}
}

func TestNewULIDMonotonicWithinMs(t *testing.T) {
	// Two ULIDs produced ~now should be unique even when timestamps collide.
	now := time.Now()
	a := newULID(now)
	b := newULID(now)
	if a == b {
		t.Errorf("expected unique ULIDs, got %q twice", a)
	}
	if len(a) != 26 || len(b) != 26 {
		t.Errorf("ULIDs should be 26 chars, got %d/%d", len(a), len(b))
	}
}

func TestParseCSV(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"", nil},
		{"a", []string{"a"}},
		{"a,b,c", []string{"a", "b", "c"}},
		{" a , b , c ", []string{"a", "b", "c"}},
		{"a,,b", []string{"a", "b"}},
		{",,,", nil},
	}
	for _, tc := range cases {
		got := parseCSV(tc.in)
		if !slices.Equal(got, tc.want) {
			t.Errorf("parseCSV(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}
