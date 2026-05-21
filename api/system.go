package main

import (
	"bufio"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

// Package-level paths — overridable in tests or via CONFIG_DIR env.
var (
	loadavgPath = "/proc/loadavg"
	meminfoPath = "/proc/meminfo"
	diskPath    = "/config"
)

func init() {
	if v := os.Getenv("CONFIG_DIR"); v != "" {
		diskPath = v
	}
}

// SystemInfo describes the host's runtime state.
type SystemInfo struct {
	CPU    CPUInfo    `json:"cpu"`
	Memory MemoryInfo `json:"memory"`
	Disk   DiskInfo   `json:"disk"`
	Uptime float64    `json:"uptime_seconds"`
}

// CPUInfo holds load averages and core count.
type CPUInfo struct {
	Load1m  float64 `json:"load_1m"`
	Load5m  float64 `json:"load_5m"`
	Load15m float64 `json:"load_15m"`
	Cores   int     `json:"cores"`
}

// MemoryInfo holds memory usage in bytes plus a derived percentage.
type MemoryInfo struct {
	TotalBytes  uint64  `json:"total_bytes"`
	UsedBytes   uint64  `json:"used_bytes"`
	UsedPercent float64 `json:"used_percent"`
}

// DiskInfo holds free-space stats for the watched path.
type DiskInfo struct {
	Path        string  `json:"path"`
	TotalBytes  uint64  `json:"total_bytes"`
	UsedBytes   uint64  `json:"used_bytes"`
	UsedPercent float64 `json:"used_percent"`
}

// GetSystemInfo gathers host metrics. Missing files yield zero values rather
// than errors — the panel's health badge prefers "unknown" over a 500.
func GetSystemInfo() (*SystemInfo, error) {
	info := &SystemInfo{
		CPU:  CPUInfo{Cores: runtime.NumCPU()},
		Disk: DiskInfo{Path: diskPath},
	}

	info.CPU.Load1m, info.CPU.Load5m, info.CPU.Load15m = readLoadavg()
	info.Memory = readMeminfo()
	info.Disk = readDisk(diskPath)
	info.Uptime = readUptimeSeconds()

	return info, nil
}

func readLoadavg() (l1, l5, l15 float64) {
	data, err := os.ReadFile(loadavgPath)
	if err != nil {
		return 0, 0, 0
	}
	fields := strings.Fields(string(data))
	if len(fields) < 3 {
		return 0, 0, 0
	}
	l1, _ = strconv.ParseFloat(fields[0], 64)
	l5, _ = strconv.ParseFloat(fields[1], 64)
	l15, _ = strconv.ParseFloat(fields[2], 64)
	return
}

// readMeminfo derives total/used from MemTotal and MemAvailable (the
// canonical "used by anything that wouldn't be reclaimable" definition the
// kernel exposes; matches what `free` shows in its "available" column).
func readMeminfo() MemoryInfo {
	f, err := os.Open(meminfoPath)
	if err != nil {
		return MemoryInfo{}
	}
	defer func() { _ = f.Close() }()

	var total, available uint64
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		key, val, ok := strings.Cut(scanner.Text(), ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "MemTotal":
			total = parseMeminfoBytes(val)
		case "MemAvailable":
			available = parseMeminfoBytes(val)
		}
		if total > 0 && available > 0 {
			break
		}
	}

	if total == 0 {
		return MemoryInfo{}
	}
	used := total
	if available <= total {
		used = total - available
	}
	return MemoryInfo{
		TotalBytes:  total,
		UsedBytes:   used,
		UsedPercent: percent(used, total),
	}
}

// parseMeminfoBytes parses a /proc/meminfo value like " 16384540 kB" into bytes.
func parseMeminfoBytes(v string) uint64 {
	fields := strings.Fields(v)
	if len(fields) == 0 {
		return 0
	}
	n, err := strconv.ParseUint(fields[0], 10, 64)
	if err != nil {
		return 0
	}
	// kB → bytes when unit suffix present (it always is in /proc/meminfo).
	if len(fields) >= 2 && strings.EqualFold(fields[1], "kB") {
		return n * 1024
	}
	return n
}

func readDisk(path string) DiskInfo {
	info := DiskInfo{Path: path}
	var s syscall.Statfs_t
	if err := syscall.Statfs(path, &s); err != nil {
		return info
	}
	// Statfs returns Bsize as int64 on linux, uint32 on darwin/wasm — cast
	// uniformly to uint64.
	bsize := uint64(s.Bsize)
	total := s.Blocks * bsize
	free := s.Bfree * bsize
	used := uint64(0)
	if total >= free {
		used = total - free
	}
	info.TotalBytes = total
	info.UsedBytes = used
	info.UsedPercent = percent(used, total)
	return info
}

func readUptimeSeconds() float64 {
	data, err := os.ReadFile(uptimePath)
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(fields[0], 64)
	return v
}

func percent(used, total uint64) float64 {
	if total == 0 {
		return 0
	}
	return float64(used) / float64(total) * 100.0
}
