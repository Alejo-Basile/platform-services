package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestClientIdentity(t *testing.T) {
	cases := []struct {
		name       string
		xff        string
		remoteAddr string
		want       string
	}{
		{name: "single XFF", xff: "203.0.113.7", remoteAddr: "10.0.0.9:1234", want: "203.0.113.7"},
		{name: "multiple XFF rightmost wins", xff: "1.2.3.4, 203.0.113.7", remoteAddr: "10.0.0.9:1234", want: "203.0.113.7"},
		{name: "invalid rightmost falls back to left valid", xff: "1.2.3.4, not-an-ip", remoteAddr: "10.0.0.9:1234", want: "1.2.3.4"},
		{name: "whitespace", xff: " 203.0.113.7 , 10.0.0.1 ", remoteAddr: "10.0.0.9:1234", want: "10.0.0.1"},
		{name: "IPv6 XFF", xff: "2001:db8::1", remoteAddr: "10.0.0.9:1234", want: "2001:db8::1"},
		{name: "XFF precedence over RemoteAddr", xff: "203.0.113.7", remoteAddr: "192.0.2.5:443", want: "203.0.113.7"},
		{name: "no XFF RemoteAddr with port", xff: "", remoteAddr: "192.0.2.5:12345", want: "192.0.2.5"},
		{name: "bare IPv6 RemoteAddr", xff: "", remoteAddr: "2001:db8::2", want: "2001:db8::2"},
		{name: "IPv6 RemoteAddr with port", xff: "", remoteAddr: "[2001:db8::3]:443", want: "2001:db8::3"},
		{name: "invalid RemoteAddr yields unknown", xff: "", remoteAddr: "not-an-ip", want: "unknown"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/check", nil)
			r.RemoteAddr = tc.remoteAddr
			if tc.xff != "" {
				r.Header.Set("X-Forwarded-For", tc.xff)
			}
			if got := clientIdentity(r); got != tc.want {
				t.Fatalf("clientIdentity() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestResolveScope(t *testing.T) {
	long := strings.Repeat("a", 100)
	cases := []struct {
		name  string
		query string
		want  string
		ok    bool
	}{
		{name: "scope wins over key", query: "scope=api-v2&key=legacy", want: "api-v2", ok: true},
		{name: "key fallback", query: "key=legacy", want: "legacy", ok: true},
		{name: "invalid chars sanitized", query: "scope=api%20v2%21", want: "api_v2_", ok: true},
		{name: "max length", query: "scope=" + long, want: strings.Repeat("a", maxScopeLen), ok: true},
		{name: "missing both", query: "", want: "", ok: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/check?"+tc.query, nil)
			got, ok := resolveScope(r)
			if ok != tc.ok {
				t.Fatalf("resolveScope() ok = %v, want %v", ok, tc.ok)
			}
			if got != tc.want {
				t.Fatalf("resolveScope() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestSanitizeScopeEmptyUsesDefault(t *testing.T) {
	if got := sanitizeScope(""); got != "default" {
		t.Fatalf("sanitizeScope(\"\") = %q, want default", got)
	}
}

func TestExemptPath(t *testing.T) {
	cases := []struct {
		name string
		uri  string
		set  bool
		want bool
	}{
		{name: "exact internal", uri: "/internal", set: true, want: true},
		{name: "nested internal", uri: "/internal/token", set: true, want: true},
		{name: "exact healthz", uri: "/healthz", set: true, want: true},
		{name: "nested healthz", uri: "/healthz/ready", set: true, want: true},
		{name: "exact metrics", uri: "/metrics", set: true, want: true},
		{name: "nested metrics", uri: "/metrics/foo", set: true, want: true},
		{name: "with query", uri: "/healthz?probe=1", set: true, want: true},
		{name: "non exempt api", uri: "/api/v2/documents", set: true, want: false},
		{name: "healthzz is not exempt", uri: "/healthzz", set: true, want: false},
		{name: "dotdot escapes internal", uri: "/internal/../api/v2/documents", set: true, want: false},
		{name: "dotdot resolves to healthz", uri: "/internal/../healthz", set: true, want: true},
		{name: "double slash healthz", uri: "//healthz", set: true, want: true},
		{name: "missing header", uri: "", set: false, want: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/check", nil)
			if tc.set {
				r.Header.Set("X-Forwarded-Uri", tc.uri)
			}
			if got := exemptPath(r); got != tc.want {
				t.Fatalf("exemptPath() = %v, want %v", got, tc.want)
			}
		})
	}
}
