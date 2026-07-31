package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseAWGDump_SingleInterfaceTwoPeers(t *testing.T) {
	dump := "wg0\tPRIVATE_KEY_BASE64=\tSERVER_PUB_KEY_BASE64=\t51820\toff\n" +
		"wg0\tPEER1_PUB_KEY_BASE64==\t(none)\t1.2.3.4:51820\t10.13.13.2/32\t1716000000\t123456\t789012\toff\n" +
		"wg0\tPEER2_PUB_KEY_BASE64==\t(none)\t5.6.7.8:12345\t10.13.13.3/32\t1716000100\t5000\t10000\toff\n"

	tunnels, err := ParseAWGDump(dump)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tunnels) != 1 {
		t.Fatalf("expected 1 tunnel, got %d", len(tunnels))
	}

	tun := tunnels[0]
	if tun.Name != "wg0" {
		t.Errorf("expected name wg0, got %s", tun.Name)
	}
	if tun.Interface.PublicKey != "SERVER_PUB_KEY_BASE64=" {
		t.Errorf("unexpected public key: %s", tun.Interface.PublicKey)
	}
	if tun.Interface.ListenPort != 51820 {
		t.Errorf("expected port 51820, got %d", tun.Interface.ListenPort)
	}
	if len(tun.Peers) != 2 {
		t.Fatalf("expected 2 peers, got %d", len(tun.Peers))
	}

	// Peer 1
	p1 := tun.Peers[0]
	if p1.PublicKey != "PEER1_PUB_KEY_BASE64==" {
		t.Errorf("peer1 public key: %s", p1.PublicKey)
	}
	if p1.Endpoint != "1.2.3.4:51820" {
		t.Errorf("peer1 endpoint: %s", p1.Endpoint)
	}
	if p1.AllowedIPs != "10.13.13.2/32" {
		t.Errorf("peer1 allowed IPs: %s", p1.AllowedIPs)
	}
	if p1.TransferRx != 123456 {
		t.Errorf("peer1 rx: %d", p1.TransferRx)
	}
	if p1.TransferTx != 789012 {
		t.Errorf("peer1 tx: %d", p1.TransferTx)
	}
	// 1716000000 = 2024-05-18T02:40:00Z
	if p1.LatestHandshake != "2024-05-18T02:40:00Z" {
		t.Errorf("peer1 handshake: %s", p1.LatestHandshake)
	}

	// Peer 2
	p2 := tun.Peers[1]
	if p2.Endpoint != "5.6.7.8:12345" {
		t.Errorf("peer2 endpoint: %s", p2.Endpoint)
	}
}

func TestParseAWGDump_MultipleTunnels(t *testing.T) {
	dump := "wg0\tKEY1=\tPUB1=\t51820\toff\n" +
		"wg0\tPEER_A=\t(none)\t1.1.1.1:1234\t10.0.0.2/32\t0\t100\t200\toff\n" +
		"wg1\tKEY2=\tPUB2=\t51821\toff\n" +
		"wg1\tPEER_B=\t(none)\t2.2.2.2:5678\t10.0.1.2/32\t0\t300\t400\toff\n"

	tunnels, err := ParseAWGDump(dump)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tunnels) != 2 {
		t.Fatalf("expected 2 tunnels, got %d", len(tunnels))
	}
	if tunnels[0].Name != "wg0" || tunnels[1].Name != "wg1" {
		t.Errorf("tunnel order: %s, %s", tunnels[0].Name, tunnels[1].Name)
	}
	if tunnels[1].Interface.ListenPort != 51821 {
		t.Errorf("wg1 port: %d", tunnels[1].Interface.ListenPort)
	}
}

func TestParseAWGDump_EmptyOutput(t *testing.T) {
	tunnels, err := ParseAWGDump("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tunnels) != 0 {
		t.Errorf("expected 0 tunnels, got %d", len(tunnels))
	}
}

func TestParseAWGDump_NoneEndpoint(t *testing.T) {
	dump := "wg0\tKEY=\tPUB=\t51820\toff\n" +
		"wg0\tPEER=\t(none)\t(none)\t10.13.13.2/32\t0\t0\t0\toff\n"

	tunnels, err := ParseAWGDump(dump)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tunnels[0].Peers[0].Endpoint != "" {
		t.Errorf("expected empty endpoint for (none), got %q", tunnels[0].Peers[0].Endpoint)
	}
}

func TestParseAWGDump_ZeroHandshake(t *testing.T) {
	dump := "wg0\tKEY=\tPUB=\t51820\toff\n" +
		"wg0\tPEER=\t(none)\t1.2.3.4:1234\t10.0.0.2/32\t0\t100\t200\toff\n"

	tunnels, err := ParseAWGDump(dump)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if tunnels[0].Peers[0].LatestHandshake != "" {
		t.Errorf("expected empty handshake for ts=0, got %q", tunnels[0].Peers[0].LatestHandshake)
	}
}

func TestParseAWGDump_PeerWithoutInterface(t *testing.T) {
	// Peer line referencing unknown interface — should be skipped
	dump := "wg0\tPEER=\t(none)\t1.2.3.4:1234\t10.0.0.2/32\t0\t100\t200\toff\n"

	tunnels, err := ParseAWGDump(dump)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tunnels) != 0 {
		t.Errorf("expected 0 tunnels, got %d", len(tunnels))
	}
}

func TestParseAWGDump_TruncatedLine(t *testing.T) {
	// Line with fewer than 5 fields — should be skipped
	dump := "wg0\tKEY=\tPUB=\n"

	tunnels, err := ParseAWGDump(dump)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tunnels) != 0 {
		t.Errorf("expected 0 tunnels for truncated line, got %d", len(tunnels))
	}
}

func TestParseAWGDump_NonNumericTransfer(t *testing.T) {
	// Non-numeric rx/tx should parse as 0
	dump := "wg0\tKEY=\tPUB=\t51820\toff\n" +
		"wg0\tPEER=\t(none)\t1.2.3.4:1234\t10.0.0.2/32\t0\tnotanumber\tbad\toff\n"

	tunnels, err := ParseAWGDump(dump)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tunnels) != 1 || len(tunnels[0].Peers) != 1 {
		t.Fatalf("expected 1 tunnel with 1 peer")
	}
	if tunnels[0].Peers[0].TransferRx != 0 {
		t.Errorf("expected 0 for non-numeric rx, got %d", tunnels[0].Peers[0].TransferRx)
	}
	if tunnels[0].Peers[0].TransferTx != 0 {
		t.Errorf("expected 0 for non-numeric tx, got %d", tunnels[0].Peers[0].TransferTx)
	}
}

// Real `awg show all dump` output. AmneziaWG always emits a 28-field device
// line (Jc/Jmin/Jmax, S1-S4, H1-H4, I1-I5, then the AWG 3.0 header protection
// key and timers), unlike plain WireGuard's 5-field line. Captured from a live
// container; keys replaced with placeholders.
const (
	realAWG30Dump = "wg0\tPRIV_BASE64_KEY_PLACEHOLDER_AAAAAAAAAAAAAAAA=\tSRVPUB_BASE64_KEY_PLACEHOLDER_AAAAAAAAAAAA=\t51820\t5\t40\t159\t99\t25\t32\t23\t430591201-480591201\t804776269-854776269\t1265869246-1315869246\t2017171383-2067171383\t<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>\t(null)\t(null)\t(null)\t(null)\tHPKEY_BASE64_KEY_PLACEHOLDER_AAAAAAAAAAAAA=\t68-127\t107-125\t6-9\t170-195\t11-15\t14-20\toff\n" +
		"wg0\tPEER1PUB_BASE64_KEY_PLACEHOLDER_AAAAAAAAAA=\tPSK1_BASE64_KEY_PLACEHOLDER_AAAAAAAAAAAAAA=\t(none)\t10.13.13.2/32\t0\t0\t0\toff\n" +
		"wg0\tPEER2PUB_BASE64_KEY_PLACEHOLDER_AAAAAAAAAA=\tPSK2_BASE64_KEY_PLACEHOLDER_AAAAAAAAAAAAAA=\t1.2.3.4:51820\t10.13.13.3/32\t1716000000\t123456\t789012\toff\n"

	realAWG20Dump = "wg0\tPRIV_BASE64_KEY_PLACEHOLDER_AAAAAAAAAAAAAAAA=\tSRVPUB_BASE64_KEY_PLACEHOLDER_AAAAAAAAAAAA=\t51820\t3\t44\t80\t18\t117\t46\t14\t189005014-239005014\t925715606-975715606\t1521067930-1571067930\t1621023317-1671023317\t<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>\t(null)\t(null)\t(null)\t(null)\t(none)\t0\t0\t0\t0\t0\t0\toff\n" +
		"wg0\tPEER1PUB_BASE64_KEY_PLACEHOLDER_AAAAAAAAAA=\tPSK1_BASE64_KEY_PLACEHOLDER_AAAAAAAAAAAAAA=\t(none)\t10.13.13.2/32\t0\t0\t0\toff\n"
)

func TestParseAWGDump_RealAmneziaWGOutput(t *testing.T) {
	for _, tc := range []struct {
		name  string
		dump  string
		peers int
	}{
		{"awg 3.0", realAWG30Dump, 2},
		{"awg 2.0", realAWG20Dump, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tunnels, err := ParseAWGDump(tc.dump)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(tunnels) != 1 {
				t.Fatalf("expected 1 tunnel, got %d", len(tunnels))
			}
			tun := tunnels[0]
			if tun.Name != "wg0" {
				t.Errorf("name = %q, want wg0", tun.Name)
			}
			if tun.Interface.ListenPort != 51820 {
				t.Errorf("listen_port = %d, want 51820", tun.Interface.ListenPort)
			}
			// Field 2 is the public key; field 1 is the private key and must
			// never be surfaced.
			if tun.Interface.PublicKey != "SRVPUB_BASE64_KEY_PLACEHOLDER_AAAAAAAAAAAA=" {
				t.Errorf("public_key = %q, want the device public key", tun.Interface.PublicKey)
			}
			if strings.Contains(tun.Interface.PublicKey, "PRIV") {
				t.Errorf("private key surfaced as public key: %q", tun.Interface.PublicKey)
			}
			if len(tun.Peers) != tc.peers {
				t.Fatalf("expected %d peers, got %d", tc.peers, len(tun.Peers))
			}
			if tun.Peers[0].AllowedIPs != "10.13.13.2/32" {
				t.Errorf("peer0 allowed_ips = %q", tun.Peers[0].AllowedIPs)
			}
		})
	}
}

func TestParseAWGDump_NeverExposesDeviceSecrets(t *testing.T) {
	tunnels, err := ParseAWGDump(realAWG30Dump)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	blob, err := json.Marshal(tunnels)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, secret := range []string{"PRIV_BASE64", "HPKEY_BASE64", "PSK1_BASE64", "PSK2_BASE64"} {
		if strings.Contains(string(blob), secret) {
			t.Errorf("device secret %q leaked into tunnel JSON: %s", secret, blob)
		}
	}
}

func TestParseAWGDump_PeerTransferAndHandshake(t *testing.T) {
	tunnels, err := ParseAWGDump(realAWG30Dump)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	p := tunnels[0].Peers[1]
	if p.Endpoint != "1.2.3.4:51820" {
		t.Errorf("endpoint = %q, want 1.2.3.4:51820", p.Endpoint)
	}
	if p.TransferRx != 123456 || p.TransferTx != 789012 {
		t.Errorf("transfer rx/tx = %d/%d, want 123456/789012", p.TransferRx, p.TransferTx)
	}
	if p.LatestHandshake == "" {
		t.Error("latest_handshake empty, want an RFC3339 timestamp")
	}
}
