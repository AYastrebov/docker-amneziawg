package main

import (
	"crypto/rand"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/oklog/ulid/v2"
)

// Log levels.
const (
	LogLevelDebug = "debug"
	LogLevelInfo  = "info"
	LogLevelWarn  = "warn"
	LogLevelError = "error"
)

// Log sources.
const (
	LogSourceAWG = "awg"
	LogSourceAPI = "api"
)

// LogLine is a single structured log entry returned by the API.
type LogLine struct {
	ID     string `json:"id"`
	T      string `json:"t"`
	Level  string `json:"level"`
	Source string `json:"source"`
	Msg    string `json:"msg"`

	ts time.Time `json:"-"`
}

// LogFilter narrows lines by level and source.
type LogFilter struct {
	Levels  []string
	Sources []string
}

// Matches reports whether line passes the filter.
func (f LogFilter) Matches(line LogLine) bool {
	if len(f.Levels) > 0 && !slices.Contains(f.Levels, line.Level) {
		return false
	}
	if len(f.Sources) > 0 && !slices.Contains(f.Sources, line.Source) {
		return false
	}
	return true
}

// LogQuery describes a paginated tail request.
type LogQuery struct {
	Limit  int
	Before string
	Filter LogFilter
}

// LogStore is an in-memory bounded log buffer with pub/sub.
type LogStore struct {
	mu       sync.RWMutex
	lines    []LogLine
	capacity int

	subMu sync.Mutex
	subs  map[*LogSub]struct{}

	scrubber *Scrubber
}

// LogSub is a single subscriber's channels.
type LogSub struct {
	ch       chan LogLine
	overflow chan struct{}
	done     chan struct{}
	once     sync.Once
}

// Recv returns the receive channels: lines, overflow signal, done signal.
func (s *LogSub) Recv() (<-chan LogLine, <-chan struct{}, <-chan struct{}) {
	return s.ch, s.overflow, s.done
}

// NewLogStore creates a store with a bounded ring of `capacity` lines.
func NewLogStore(capacity int) *LogStore {
	if capacity <= 0 {
		capacity = 1000
	}
	return &LogStore{
		lines:    make([]LogLine, 0, capacity),
		capacity: capacity,
		subs:     map[*LogSub]struct{}{},
		scrubber: NewScrubber(),
	}
}

// Append records a log entry, scrubbing sensitive fields from msg, and fans
// the entry out to all active subscribers. Returns the stored line.
func (s *LogStore) Append(level, source, msg string) LogLine {
	now := time.Now().UTC()
	line := LogLine{
		ID:     newULID(now),
		T:      now.Format("2006-01-02T15:04:05.000Z"),
		Level:  level,
		Source: source,
		Msg:    s.scrubber.Scrub(msg),
		ts:     now,
	}

	s.mu.Lock()
	if len(s.lines) >= s.capacity {
		// Drop oldest. Copy is fine for the workload (writes are infrequent
		// compared to reads in steady state).
		copy(s.lines, s.lines[1:])
		s.lines = s.lines[:len(s.lines)-1]
	}
	s.lines = append(s.lines, line)
	s.mu.Unlock()

	s.broadcast(line)
	return line
}

// broadcast sends line to every subscriber non-blocking. If a subscriber's
// buffer is full, it gets an overflow signal instead — the WS handler treats
// that as a backpressure close (code 1013).
func (s *LogStore) broadcast(line LogLine) {
	s.subMu.Lock()
	defer s.subMu.Unlock()
	for sub := range s.subs {
		select {
		case sub.ch <- line:
		default:
			select {
			case sub.overflow <- struct{}{}:
			default:
			}
		}
	}
}

// Query returns lines matching q, paginated by the `Before` cursor.
// Results are ordered newest first. `next` is the cursor for the following
// (older) page — empty when no more results are expected.
func (s *LogStore) Query(q LogQuery) ([]LogLine, string) {
	limit := q.Limit
	if limit <= 0 {
		limit = 200
	}
	if limit > 1000 {
		limit = 1000
	}

	var beforeTime time.Time
	var beforeID string
	if q.Before != "" {
		if t, err := time.Parse(time.RFC3339Nano, q.Before); err == nil {
			beforeTime = t
		} else {
			beforeID = q.Before
		}
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]LogLine, 0, limit)
	for i := len(s.lines) - 1; i >= 0 && len(out) < limit; i-- {
		line := s.lines[i]
		if !beforeTime.IsZero() && !line.ts.Before(beforeTime) {
			continue
		}
		if beforeID != "" && line.ID >= beforeID {
			continue
		}
		if !q.Filter.Matches(line) {
			continue
		}
		out = append(out, line)
	}

	next := ""
	if len(out) == limit && len(out) > 0 {
		next = out[len(out)-1].ID
	}
	return out, next
}

// Snapshot returns the full backing slice (copy) — for tests and diagnostics.
func (s *LogStore) Snapshot() []LogLine {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]LogLine, len(s.lines))
	copy(out, s.lines)
	return out
}

// Subscribe registers a new subscriber. Unsubscribe with store.Unsubscribe(sub).
func (s *LogStore) Subscribe(bufSize int) *LogSub {
	if bufSize <= 0 {
		bufSize = 64
	}
	sub := &LogSub{
		ch:       make(chan LogLine, bufSize),
		overflow: make(chan struct{}, 1),
		done:     make(chan struct{}),
	}
	s.subMu.Lock()
	s.subs[sub] = struct{}{}
	s.subMu.Unlock()
	return sub
}

// Unsubscribe removes sub and closes its done channel. Safe to call multiple times.
func (s *LogStore) Unsubscribe(sub *LogSub) {
	sub.once.Do(func() {
		s.subMu.Lock()
		delete(s.subs, sub)
		s.subMu.Unlock()
		close(sub.done)
	})
}

// --- Scrubber ---

// Scrubber masks sensitive substrings (private keys, preshared keys, bearer
// tokens) before they enter the store. Applied at write time so the in-memory
// buffer stays clean.
type Scrubber struct {
	patterns []*regexp.Regexp
}

// NewScrubber returns a Scrubber with the default patterns.
func NewScrubber() *Scrubber {
	return &Scrubber{
		patterns: []*regexp.Regexp{
			// PrivateKey / PreSharedKey assignments in WireGuard config syntax.
			regexp.MustCompile(`(?i)(private[_-]?key\s*[:=]\s*)\S+`),
			regexp.MustCompile(`(?i)(preshared[_-]?key\s*[:=]\s*)\S+`),
			// Bearer tokens (32+ hex chars, matches our generated tokens).
			regexp.MustCompile(`(?i)(bearer\s+)[A-Za-z0-9_\-\.]{16,}`),
		},
	}
}

// Scrub applies all patterns to msg, replacing matched secret with `***REDACTED***`.
func (s *Scrubber) Scrub(msg string) string {
	for _, p := range s.patterns {
		msg = p.ReplaceAllString(msg, "${1}***REDACTED***")
	}
	return msg
}

// --- ULID helpers ---

// ulidEntropy is a single thread-safe entropy source. crypto/rand.Reader is
// already concurrency-safe.
var ulidEntropy = rand.Reader

// newULID returns a 26-char ULID encoded from t and random bytes.
func newULID(t time.Time) string {
	return ulid.MustNew(ulid.Timestamp(t), ulidEntropy).String()
}

// --- CSV helper (used by handlers + WS) ---

// parseCSV splits "a,b,c" into ["a","b","c"], trimming whitespace and skipping empties.
func parseCSV(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
