package main

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// awgPollInterval is the cadence at which we sample `awg show` to detect
// peer state changes. Five seconds matches the perceived liveness in the
// panel without burning CPU.
const awgPollInterval = 5 * time.Second

// peerKey identifies a peer within one container (tunnel + public key).
type peerKey struct {
	tunnel string
	pubKey string
}

// peerState captures the bits we diff between polls.
type peerState struct {
	endpoint        string
	latestHandshake string
}

// runAWGEventLoop polls tunnel stats and emits structured log events when
// state changes. Returns when ctx is cancelled.
//
// The first iteration seeds the baseline without firing diff events
// (so we don't replay every existing peer as "appeared" on startup).
func runAWGEventLoop(ctx context.Context, store *LogStore, interval time.Duration) {
	if interval <= 0 {
		interval = awgPollInterval
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	state := map[peerKey]peerState{}
	seeded := false

	pollOnce := func() {
		tunnels, err := GetTunnelStats()
		if err != nil {
			// Avoid log spam on persistent failure: only emit when seeded
			// (i.e. we've succeeded at least once before).
			if seeded {
				store.Append(LogLevelWarn, LogSourceAWG, fmt.Sprintf("failed to read tunnel stats: %v", err))
			}
			return
		}

		nameByKey := peerNameIndex()
		newState := make(map[peerKey]peerState, len(state))

		for _, t := range tunnels {
			for _, p := range t.Peers {
				k := peerKey{tunnel: t.Name, pubKey: p.PublicKey}
				ns := peerState{
					endpoint:        p.Endpoint,
					latestHandshake: p.LatestHandshake,
				}
				newState[k] = ns

				if !seeded {
					continue
				}

				prev, existed := state[k]
				display := peerDisplay(p.PublicKey, nameByKey)
				switch {
				case !existed:
					store.Append(LogLevelInfo, LogSourceAWG,
						fmt.Sprintf("peer %s appeared on %s", display, t.Name))
				case prev.latestHandshake != ns.latestHandshake && ns.latestHandshake != "":
					store.Append(LogLevelInfo, LogSourceAWG,
						fmt.Sprintf("peer %s handshake completed (endpoint %s)", display, fallback(p.Endpoint, "unknown")))
				}
			}
		}

		if seeded {
			for k := range state {
				if _, ok := newState[k]; !ok {
					display := peerDisplay(k.pubKey, nameByKey)
					store.Append(LogLevelInfo, LogSourceAWG,
						fmt.Sprintf("peer %s gone from %s", display, k.tunnel))
				}
			}
		} else {
			for _, t := range tunnels {
				store.Append(LogLevelInfo, LogSourceAWG,
					fmt.Sprintf("tunnel %s up with %d peer(s)", t.Name, len(t.Peers)))
			}
			seeded = true
		}

		state = newState
	}

	pollOnce()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			pollOnce()
		}
	}
}

// peerNameTTL is how long a peerNameIndex result stays warm before the
// next call re-reads the filesystem. Peer add/remove is a rare event, so
// 60 s is well below "annoying staleness" but eliminates 11 of every 12
// FS reads at the default 5 s poll cadence.
const peerNameTTL = 60 * time.Second

var (
	peerNameMu     sync.RWMutex
	peerNameCache  map[string]string
	peerNameLoaded time.Time
)

// peerNameIndex builds a public-key → display-name map from the configured
// peers. Result is cached for peerNameTTL; concurrent callers share one
// refresh. Lookups for unknown keys fall back through the caller to a
// truncated key.
func peerNameIndex() map[string]string {
	peerNameMu.RLock()
	if peerNameCache != nil && time.Since(peerNameLoaded) < peerNameTTL {
		out := peerNameCache
		peerNameMu.RUnlock()
		return out
	}
	peerNameMu.RUnlock()

	peerNameMu.Lock()
	defer peerNameMu.Unlock()
	// Re-check after promoting the lock — another caller may have refreshed.
	if peerNameCache != nil && time.Since(peerNameLoaded) < peerNameTTL {
		return peerNameCache
	}

	peers, err := ListPeers()
	if err != nil {
		// Keep the previous cache on transient failure rather than blanking it.
		if peerNameCache != nil {
			return peerNameCache
		}
		return nil
	}
	fresh := make(map[string]string, len(peers))
	for _, p := range peers {
		if p.PublicKey != "" {
			fresh[p.PublicKey] = p.Name
		}
	}
	peerNameCache = fresh
	peerNameLoaded = time.Now()
	return fresh
}

// resetPeerNameCache clears the cache. Intended for tests.
func resetPeerNameCache() {
	peerNameMu.Lock()
	peerNameCache = nil
	peerNameLoaded = time.Time{}
	peerNameMu.Unlock()
}

func peerDisplay(pubKey string, names map[string]string) string {
	if name, ok := names[pubKey]; ok && name != "" {
		return name
	}
	return shortKey(pubKey)
}

func shortKey(pubKey string) string {
	if len(pubKey) <= 8 {
		return pubKey
	}
	return pubKey[:8] + "…"
}

func fallback(v, def string) string {
	if v == "" {
		return def
	}
	return v
}
