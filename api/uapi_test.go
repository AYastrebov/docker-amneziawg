package main

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

// A representative amneziawg-go `get=1` response for a 3.0 server interface
// with two peers. Keys are hex on the wire. Secrets (private_key,
// preshared_key, header_protection_key) are present so the test can prove they
// never reach the output.
const uapiGetTranscript = "" +
	"private_key=a01b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00\n" +
	"listen_port=51820\n" +
	"fwmark=51820\n" +
	"jc=8\n" +
	"s1=53\n" +
	"header_protection_key=1122334455667788990011223344556677889900112233445566778899001122\n" +
	"content_padding_addition=0-64\n" +
	"keepalive_timeout=12-26\n" +
	"public_key=2222222222222222222222222222222222222222222222222222222222222222\n" +
	"preshared_key=3333333333333333333333333333333333333333333333333333333333333333\n" +
	"protocol_version=1\n" +
	"endpoint=203.0.113.7:41414\n" +
	"last_handshake_time_sec=1700000000\n" +
	"last_handshake_time_nsec=123456\n" +
	"tx_bytes=2670\n" +
	"rx_bytes=605\n" +
	"persistent_keepalive_interval=25\n" +
	"allowed_ip=10.13.13.2/32\n" +
	"allowed_ip=fd00::2/128\n" +
	"public_key=4444444444444444444444444444444444444444444444444444444444444444\n" +
	"preshared_key=5555555555555555555555555555555555555555555555555555555555555555\n" +
	"protocol_version=1\n" +
	"last_handshake_time_sec=0\n" +
	"tx_bytes=0\n" +
	"rx_bytes=0\n" +
	"allowed_ip=10.13.13.3/32\n" +
	"errno=0\n\n"

func hexToB64(t *testing.T, h string) string {
	t.Helper()
	raw, err := hex.DecodeString(h)
	if err != nil {
		t.Fatalf("bad hex %q: %v", h, err)
	}
	return base64.StdEncoding.EncodeToString(raw)
}

func TestParseUAPIGet(t *testing.T) {
	tun, err := ParseUAPIGet("wg0", strings.NewReader(uapiGetTranscript))
	if err != nil {
		t.Fatalf("ParseUAPIGet: %v", err)
	}

	if tun.Name != "wg0" {
		t.Errorf("Name = %q, want wg0", tun.Name)
	}
	if tun.Interface.ListenPort != 51820 {
		t.Errorf("ListenPort = %d, want 51820", tun.Interface.ListenPort)
	}
	// Public key is derived from the private key; just assert it's a valid,
	// non-empty base64 key and not the private key material.
	if tun.Interface.PublicKey == "" {
		t.Error("Interface.PublicKey is empty, want derived key")
	}
	if raw, err := base64.StdEncoding.DecodeString(tun.Interface.PublicKey); err != nil || len(raw) != 32 {
		t.Errorf("Interface.PublicKey not a 32-byte base64 key: %q", tun.Interface.PublicKey)
	}

	if len(tun.Peers) != 2 {
		t.Fatalf("peer count = %d, want 2", len(tun.Peers))
	}

	p0 := tun.Peers[0]
	if want := hexToB64(t, "2222222222222222222222222222222222222222222222222222222222222222"); p0.PublicKey != want {
		t.Errorf("peer0 PublicKey = %q, want base64 %q", p0.PublicKey, want)
	}
	if p0.Endpoint != "203.0.113.7:41414" {
		t.Errorf("peer0 Endpoint = %q", p0.Endpoint)
	}
	if p0.AllowedIPs != "10.13.13.2/32,fd00::2/128" {
		t.Errorf("peer0 AllowedIPs = %q", p0.AllowedIPs)
	}
	if p0.TransferTx != 2670 || p0.TransferRx != 605 {
		t.Errorf("peer0 transfer tx=%d rx=%d, want 2670/605", p0.TransferTx, p0.TransferRx)
	}
	if p0.LatestHandshake == "" {
		t.Error("peer0 LatestHandshake empty, want RFC3339 timestamp")
	}

	// peer1 never handshook: handshake stays empty.
	if tun.Peers[1].LatestHandshake != "" {
		t.Errorf("peer1 LatestHandshake = %q, want empty (sec=0)", tun.Peers[1].LatestHandshake)
	}
}

// TestParseUAPIGet_NoSecretLeak asserts that no secret from the transcript
// (private key, preshared keys, header protection key) appears anywhere in the
// parsed output.
func TestParseUAPIGet_NoSecretLeak(t *testing.T) {
	tun, err := ParseUAPIGet("wg0", strings.NewReader(uapiGetTranscript))
	if err != nil {
		t.Fatalf("ParseUAPIGet: %v", err)
	}

	secretsHex := []string{
		"a01b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00", // private_key
		"1122334455667788990011223344556677889900112233445566778899001122", // header_protection_key
		"3333333333333333333333333333333333333333333333333333333333333333", // preshared_key 0
		"5555555555555555555555555555555555555555555555555555555555555555", // preshared_key 1
	}

	// Marshal the whole struct (mirrors TestParseAWGDump_NeverExposesDeviceSecrets)
	// so any future field is covered automatically, then scan for the secrets in
	// both their hex and base64 forms.
	blob, err := json.Marshal(tun)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	out := string(blob)

	for _, h := range secretsHex {
		if strings.Contains(strings.ToLower(out), h) {
			t.Errorf("secret (hex) leaked into output: %s", h)
		}
		raw, _ := hex.DecodeString(h)
		if b64 := base64.StdEncoding.EncodeToString(raw); strings.Contains(out, b64) {
			t.Errorf("secret (base64) leaked into output: %s", b64)
		}
	}
}

func TestParseUAPIGet_Errno(t *testing.T) {
	if _, err := ParseUAPIGet("wg0", strings.NewReader("errno=1\n\n")); err == nil {
		t.Error("expected error for errno=1, got nil")
	}
}

func TestParseUAPIGet_Empty(t *testing.T) {
	// A device with no peers (interface up, nothing connected).
	tun, err := ParseUAPIGet("wg0", strings.NewReader("private_key=a01b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00\nlisten_port=51820\nerrno=0\n\n"))
	if err != nil {
		t.Fatalf("ParseUAPIGet: %v", err)
	}
	if len(tun.Peers) != 0 {
		t.Errorf("peer count = %d, want 0", len(tun.Peers))
	}
}

// TestUAPIInterfaces_Empty confirms a missing/empty socket dir yields no
// interfaces and no error, so getTunnelStatsReal falls back to the CLI.
func TestUAPIInterfaces_Empty(t *testing.T) {
	ifaces, err := (UAPIClient{dir: t.TempDir()}).interfaces()
	if err != nil {
		t.Fatalf("interfaces: %v", err)
	}
	if len(ifaces) != 0 {
		t.Errorf("interfaces = %v, want none", ifaces)
	}
}
