package main

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/limiter"
)

func readMetric(body, prefix string) int64 {
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, prefix) {
			fields := strings.Fields(line)
			var v int64
			if _, err := fmt.Sscan(fields[len(fields)-1], &v); err != nil {
				panic(err)
			}
			return v
		}
	}
	panic("metric not found: " + prefix)
}

func snapshotMetrics(t *testing.T) (allowed, denied, degraded, redisUp int64, ct string) {
	t.Helper()
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	handleMetrics(w, r)
	ct = w.Header().Get("Content-Type")
	body := w.Body.String()
	allowed = readMetric(body, `ratelimit_requests_total{decision="allowed"}`)
	denied = readMetric(body, `ratelimit_requests_total{decision="denied"}`)
	degraded = readMetric(body, `ratelimit_requests_total{decision="degraded"}`)
	redisUp = readMetric(body, `ratelimit_redis_up`)
	return
}

func TestMetricsAllowedIncrements(t *testing.T) {
	a0, _, g0, _, _ := snapshotMetrics(t)

	fake := &fakeChecker{decision: limiter.Decision{Allowed: true, Remaining: 5}}
	r := httptest.NewRequest(http.MethodGet, "/check?scope=api-v2", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()
	handleCheck(w, r, fake)

	a1, _, g1, ru1, _ := snapshotMetrics(t)
	if a1-a0 != 1 {
		t.Fatalf("allowed delta = %d, want 1", a1-a0)
	}
	if g1-g0 != 0 {
		t.Fatalf("degraded delta = %d, want 0", g1-g0)
	}
	if ru1 != 1 {
		t.Fatalf("redis_up = %d, want 1", ru1)
	}
}

func TestMetricsDeniedIncrements(t *testing.T) {
	_, d0, _, _, _ := snapshotMetrics(t)
	fake := &fakeChecker{decision: limiter.Decision{Allowed: false, RetryAfter: 7}}
	r := httptest.NewRequest(http.MethodGet, "/check?scope=api-v2", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()
	handleCheck(w, r, fake)

	_, d1, _, ru1, _ := snapshotMetrics(t)
	if d1-d0 != 1 {
		t.Fatalf("denied delta = %d, want 1", d1-d0)
	}
	if ru1 != 1 {
		t.Fatalf("redis_up = %d, want 1", ru1)
	}
}

func TestMetricsDegradedIncrements(t *testing.T) {
	_, _, g0, _, _ := snapshotMetrics(t)
	fake := &fakeChecker{err: errors.New("redis caído")}
	r := httptest.NewRequest(http.MethodGet, "/check?scope=api-v2", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()
	handleCheck(w, r, fake)

	_, _, g1, ru1, _ := snapshotMetrics(t)
	if g1-g0 != 1 {
		t.Fatalf("degraded delta = %d, want 1", g1-g0)
	}
	if ru1 != 0 {
		t.Fatalf("redis_up = %d, want 0", ru1)
	}
}

func TestMetricsExemptNoCounter(t *testing.T) {
	a0, d0, g0, _, _ := snapshotMetrics(t)
	fake := &fakeChecker{decision: limiter.Decision{Allowed: true, Remaining: 99}}
	r := httptest.NewRequest(http.MethodGet, "/check", nil)
	r.Header.Set("X-Forwarded-Uri", "/internal/token")
	w := httptest.NewRecorder()
	handleCheck(w, r, fake)

	a1, d1, g1, _, _ := snapshotMetrics(t)
	if a1 != a0 || d1 != d0 || g1 != g0 {
		t.Fatalf("counters changed on exempt: allowed %d->%d denied %d->%d degraded %d->%d", a0, a1, d0, d1, g0, g1)
	}
	if fake.calls != 0 {
		t.Fatalf("checker calls = %d, want 0", fake.calls)
	}
}

func TestMetricsContentType(t *testing.T) {
	_, _, _, _, ct := snapshotMetrics(t)
	want := "text/plain; version=0.0.4; charset=utf-8"
	if ct != want {
		t.Fatalf("Content-Type = %q, want %q", ct, want)
	}
}
