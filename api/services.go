package main

import (
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

// ServiceStatus is the runtime state of a single s6-overlay service.
type ServiceStatus struct {
	Name          string `json:"name"`
	Status        string `json:"status"` // "up", "down", or "unknown"
	UptimeSeconds int64  `json:"uptime_seconds"`
}

// s6 service directory layout — overridable for tests.
var (
	s6ServiceDir   = "/run/service"
	s6SvstatBinary = "s6-svstat"
	knownServices  = []string{
		"svc-amneziawg",
		"svc-coredns",
		"svc-awg-api",
	}
)

// serviceQueryFunc is the unit under mock in tests.
var serviceQueryFunc = serviceQueryReal

// GetServiceStatuses returns the runtime status for each known s6 service.
// Services whose directory isn't reachable come back as "unknown" — that's
// the expected outcome when the API runs outside the container (e.g. unit
// tests, local dev).
func GetServiceStatuses() ([]ServiceStatus, error) {
	out := make([]ServiceStatus, 0, len(knownServices))
	for _, name := range knownServices {
		out = append(out, serviceQueryFunc(name))
	}
	return out, nil
}

// svstatLineRe matches the default s6-svstat output:
//
//	up (pid 123) 3601 seconds
//	down 14 seconds, normally up, want up, ready 14 seconds
//
// We capture the first token (up/down) and the integer just before "seconds".
// The lazy `.*?` skips past parenthesized pid info on the up-form so we don't
// accidentally capture the pid as the uptime.
var svstatLineRe = regexp.MustCompile(`^(up|down).*?(\d+)\s+seconds`)

func serviceQueryReal(name string) ServiceStatus {
	svc := ServiceStatus{Name: name, Status: "unknown"}

	svcDir := s6ServiceDir + "/" + name
	rawOut, err := exec.Command(s6SvstatBinary, svcDir).Output()
	if err != nil {
		return svc
	}

	m := svstatLineRe.FindStringSubmatch(strings.TrimSpace(string(rawOut)))
	if len(m) != 3 {
		return svc
	}
	svc.Status = m[1]
	if n, err := strconv.ParseInt(m[2], 10, 64); err == nil {
		svc.UptimeSeconds = n
	}
	return svc
}
