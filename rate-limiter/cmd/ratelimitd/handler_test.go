package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/limiter"
)

func TestHandleCheckAllowed(t *testing.T) {
	fake := &fakeChecker{decision: limiter.Decision{Allowed: true, Remaining: 5}}
	r := httptest.NewRequest(http.MethodGet, "/check?scope=api-v2", nil)
	r.Header.Set("X-Forwarded-For", "198.51.100.1, 203.0.113.7")
	w := httptest.NewRecorder()

	handleCheck(w, r, fake)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if got := w.Header().Get("X-RateLimit-Remaining"); got != "5" {
		t.Fatalf("X-RateLimit-Remaining = %q, want 5", got)
	}
	if fake.calls != 1 {
		t.Fatalf("checker calls = %d, want 1", fake.calls)
	}
	if fake.key != "rl:api-v2:203.0.113.7" {
		t.Fatalf("key = %q, want rl:api-v2:203.0.113.7", fake.key)
	}
	body := decodeBody(t, w.Body.Bytes())
	if body["allowed"] != true {
		t.Fatalf("allowed = %v, want true", body["allowed"])
	}
}

func TestHandleCheckKeyFallback(t *testing.T) {
	fake := &fakeChecker{decision: limiter.Decision{Allowed: true, Remaining: 1}}
	r := httptest.NewRequest(http.MethodGet, "/check?key=api-v2&rate=10&burst=20", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()

	handleCheck(w, r, fake)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if fake.key != "rl:api-v2:203.0.113.7" {
		t.Fatalf("key = %q, want rl:api-v2:203.0.113.7", fake.key)
	}
}

func TestHandleCheckTooManyRequests(t *testing.T) {
	fake := &fakeChecker{decision: limiter.Decision{Allowed: false, RetryAfter: 7}}
	r := httptest.NewRequest(http.MethodGet, "/check?scope=api-v2", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()

	handleCheck(w, r, fake)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", w.Code)
	}
	if got := w.Header().Get("Retry-After"); got != "7" {
		t.Fatalf("Retry-After = %q, want 7", got)
	}
	if got := w.Header().Get("X-RateLimit-Retry-After"); got != "7" {
		t.Fatalf("X-RateLimit-Retry-After = %q, want 7", got)
	}
	body := decodeBody(t, w.Body.Bytes())
	if body["allowed"] != false {
		t.Fatalf("allowed = %v, want false", body["allowed"])
	}
}

func TestHandleCheckFailOpen(t *testing.T) {
	fake := &fakeChecker{err: errors.New("redis caído")}
	r := httptest.NewRequest(http.MethodGet, "/check?scope=api-v2", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()

	handleCheck(w, r, fake)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if got := w.Header().Get("X-RateLimit-Degraded"); got != "true" {
		t.Fatalf("X-RateLimit-Degraded = %q, want true", got)
	}
	body := decodeBody(t, w.Body.Bytes())
	if body["degraded"] != true {
		t.Fatalf("degraded = %v, want true", body["degraded"])
	}
}

func TestHandleCheckExemptDoesNotCallChecker(t *testing.T) {
	for _, uri := range []string{"/internal/token", "/healthz", "/metrics/custom"} {
		t.Run(uri, func(t *testing.T) {
			fake := &fakeChecker{decision: limiter.Decision{Allowed: true, Remaining: 99}}
			r := httptest.NewRequest(http.MethodGet, "/check", nil)
			r.Header.Set("X-Forwarded-Uri", uri)
			w := httptest.NewRecorder()

			handleCheck(w, r, fake)

			if w.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200", w.Code)
			}
			if fake.calls != 0 {
				t.Fatalf("checker calls = %d, want 0", fake.calls)
			}
			body := decodeBody(t, w.Body.Bytes())
			if body["exempted"] != true {
				t.Fatalf("exempted = %v, want true", body["exempted"])
			}
		})
	}
}

func TestHandleCheckMissingScope(t *testing.T) {
	fake := &fakeChecker{}
	r := httptest.NewRequest(http.MethodGet, "/check", nil)
	w := httptest.NewRecorder()

	handleCheck(w, r, fake)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", w.Code)
	}
	if fake.calls != 0 {
		t.Fatalf("checker calls = %d, want 0", fake.calls)
	}
}

func TestHandleCheckValidationPreserved(t *testing.T) {
	cases := []struct {
		name  string
		query string
	}{
		{name: "invalid rate", query: "scope=api-v2&rate=0"},
		{name: "invalid burst", query: "scope=api-v2&burst=0"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fake := &fakeChecker{}
			r := httptest.NewRequest(http.MethodGet, "/check?"+tc.query, nil)
			w := httptest.NewRecorder()

			handleCheck(w, r, fake)

			if w.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", w.Code)
			}
			if fake.calls != 0 {
				t.Fatalf("checker calls = %d, want 0", fake.calls)
			}
		})
	}
}

type fakeChecker struct {
	decision limiter.Decision
	err      error
	calls    int
	key      string
	rate     float64
	burst    float64
}

func (f *fakeChecker) Check(_ context.Context, key string, rate, burst float64) (limiter.Decision, error) {
	f.calls++
	f.key = key
	f.rate = rate
	f.burst = burst
	return f.decision, f.err
}

func decodeBody(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("JSON inválido: %v (%s)", err, body)
	}
	return out
}
