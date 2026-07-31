package main

import "testing"

func TestSwaggerEnabled(t *testing.T) {
	cases := []struct {
		env  string
		want bool
	}{
		{"", true}, // default-on
		{"true", true},
		{"TRUE", true},
		{"1", true},
		{"yes", true},
		{"on", true},
		{"false", false},
		{"0", false},
		{"no", false},
		{"off", false},
		{"bogus", false}, // fail-safe: unknown value → off
	}
	for _, tc := range cases {
		t.Setenv("API_SWAGGER", tc.env)
		if got := swaggerEnabled(); got != tc.want {
			t.Errorf("API_SWAGGER=%q: got %v, want %v", tc.env, got, tc.want)
		}
	}
}
