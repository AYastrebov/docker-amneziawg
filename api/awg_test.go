package main

import (
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
