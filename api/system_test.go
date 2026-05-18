package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestSystemHandlerBasicShape(t *testing.T) {
	r := setupTestRouter(t)

	w := doRequest(r, http.MethodGet, "/api/v1/system", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data SystemInfo `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)

	if resp.Data.CPU.Cores <= 0 {
		t.Errorf("expected CPU cores > 0, got %d", resp.Data.CPU.Cores)
	}
	if resp.Data.Disk.Path == "" {
		t.Errorf("expected disk path set, got empty")
	}
}

func TestSystemHandlerUnauthenticated(t *testing.T) {
	r := setupTestRouter(t)
	w := doRequest(r, http.MethodGet, "/api/v1/system", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

func TestReadLoadavgFromTempFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "loadavg")
	if err := os.WriteFile(p, []byte("0.42 0.38 0.30 1/123 456\n"), 0644); err != nil {
		t.Fatal(err)
	}

	orig := loadavgPath
	loadavgPath = p
	t.Cleanup(func() { loadavgPath = orig })

	l1, l5, l15 := readLoadavg()
	if l1 != 0.42 || l5 != 0.38 || l15 != 0.30 {
		t.Errorf("loadavg parse: got (%v, %v, %v)", l1, l5, l15)
	}
}

func TestReadLoadavgMissingFile(t *testing.T) {
	orig := loadavgPath
	loadavgPath = "/nonexistent/loadavg"
	t.Cleanup(func() { loadavgPath = orig })

	l1, l5, l15 := readLoadavg()
	if l1 != 0 || l5 != 0 || l15 != 0 {
		t.Errorf("expected zero loadavg on missing file, got (%v, %v, %v)", l1, l5, l15)
	}
}

func TestReadMeminfoParsesKB(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "meminfo")
	if err := os.WriteFile(p, []byte(
		"MemTotal:       16000 kB\n"+
			"MemFree:         4000 kB\n"+
			"MemAvailable:    8000 kB\n"+
			"Buffers:           10 kB\n",
	), 0644); err != nil {
		t.Fatal(err)
	}

	orig := meminfoPath
	meminfoPath = p
	t.Cleanup(func() { meminfoPath = orig })

	mem := readMeminfo()
	if mem.TotalBytes != 16000*1024 {
		t.Errorf("total: got %d", mem.TotalBytes)
	}
	if mem.UsedBytes != (16000-8000)*1024 {
		t.Errorf("used: got %d", mem.UsedBytes)
	}
	if mem.UsedPercent < 49 || mem.UsedPercent > 51 {
		t.Errorf("used pct: got %v, expected ~50", mem.UsedPercent)
	}
}

func TestReadMeminfoMissingFile(t *testing.T) {
	orig := meminfoPath
	meminfoPath = "/nonexistent/meminfo"
	t.Cleanup(func() { meminfoPath = orig })

	mem := readMeminfo()
	if mem.TotalBytes != 0 || mem.UsedBytes != 0 {
		t.Errorf("expected zeroed memory on missing file, got %+v", mem)
	}
}

func TestReadDiskOnTempDir(t *testing.T) {
	dir := t.TempDir()
	disk := readDisk(dir)
	if disk.TotalBytes == 0 {
		t.Errorf("expected non-zero disk total for %q", dir)
	}
	if disk.UsedPercent < 0 || disk.UsedPercent > 100 {
		t.Errorf("disk pct out of range: %v", disk.UsedPercent)
	}
	if disk.Path != dir {
		t.Errorf("path: got %q, want %q", disk.Path, dir)
	}
}

func TestPercentZeroDivision(t *testing.T) {
	if got := percent(10, 0); got != 0 {
		t.Errorf("percent(10, 0) = %v, want 0", got)
	}
	if got := percent(50, 200); got != 25 {
		t.Errorf("percent(50, 200) = %v, want 25", got)
	}
}

// Compile-time sanity: SystemInfo serializes to the documented shape.
func TestSystemInfoJSONFields(t *testing.T) {
	info := SystemInfo{
		CPU:    CPUInfo{Load1m: 0.1, Cores: 2},
		Memory: MemoryInfo{TotalBytes: 1024, UsedBytes: 512, UsedPercent: 50},
		Disk:   DiskInfo{Path: "/x"},
		Uptime: 99.5,
	}
	data, err := json.Marshal(info)
	if err != nil {
		t.Fatal(err)
	}
	body := string(data)
	for _, want := range []string{`"cpu":`, `"load_1m":0.1`, `"cores":2`, `"memory":`, `"total_bytes":1024`, `"used_percent":50`, `"disk":`, `"path":"/x"`, `"uptime_seconds":99.5`} {
		if !contains(body, want) {
			t.Errorf("JSON missing %q in %s", want, body)
		}
	}
}

func contains(s, substr string) bool {
	for i := 0; i+len(substr) <= len(s); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
