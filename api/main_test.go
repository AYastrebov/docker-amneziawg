package main

import (
	"os"
	"testing"
)

func TestSwaggerEnabled(t *testing.T) {
	cases := []struct {
		env  string
		set  bool
		want bool
	}{
		{set: false, want: false},         // unset → opt-in, so off
		{env: "", set: true, want: false}, // empty → off
		{env: "true", set: true, want: true},
		{env: "TRUE", set: true, want: true},
		{env: "1", set: true, want: true},
		{env: "yes", set: true, want: true},
		{env: "on", set: true, want: true},
		{env: "false", set: true, want: false},
		{env: "0", set: true, want: false},
		{env: "no", set: true, want: false},
		{env: "off", set: true, want: false},
		{env: "bogus", set: true, want: false}, // fail-safe: unknown value → off
	}
	for _, tc := range cases {
		// t.Setenv registers cleanup that restores the prior value, so
		// unsetting afterwards is still cleaned up correctly.
		t.Setenv("API_SWAGGER", tc.env)
		if !tc.set {
			os.Unsetenv("API_SWAGGER")
		}
		if got := swaggerEnabled(); got != tc.want {
			t.Errorf("API_SWAGGER=%q (set=%v): got %v, want %v", tc.env, tc.set, got, tc.want)
		}
	}
}
