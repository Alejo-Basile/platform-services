package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/limiter"
)

// fakeChecker captura los parámetros recibidos y devuelve una decisión fija.
type fakeChecker struct {
	decision   limiter.Decision
	err        error
	gotKey     string
	gotRate    float64
	gotBurst   float64
	checkCalls int
}

func (f *fakeChecker) Check(_ context.Context, key string, rate, burst float64) (limiter.Decision, error) {
	f.checkCalls++
	f.gotKey, f.gotRate, f.gotBurst = key, rate, burst
	return f.decision, f.err
}

func (f *fakeChecker) Ping(context.Context) error { return nil }

func TestClientKey(t *testing.T) {
	casos := []struct {
		nombre     string
		xff        string
		realIP     string
		remoteAddr string
		esperada   string
	}{
		{
			nombre:     "XFF con varios saltos toma el primero",
			xff:        "203.0.113.7, 10.0.0.1, 10.0.0.2",
			remoteAddr: "10.0.0.9:1234",
			esperada:   "203.0.113.7",
		},
		{
			nombre:     "XFF con espacios se recorta",
			xff:        " 203.0.113.7 , 10.0.0.1",
			remoteAddr: "10.0.0.9:1234",
			esperada:   "203.0.113.7",
		},
		{
			nombre:     "sin XFF usa X-Real-Ip",
			realIP:     "203.0.113.8",
			remoteAddr: "10.0.0.9:1234",
			esperada:   "203.0.113.8",
		},
		{
			nombre:     "sin cabeceras usa el host de RemoteAddr",
			remoteAddr: "10.0.0.9:1234",
			esperada:   "10.0.0.9",
		},
	}
	for _, tc := range casos {
		t.Run(tc.nombre, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/forwardauth", nil)
			if tc.xff != "" {
				r.Header.Set("X-Forwarded-For", tc.xff)
			}
			if tc.realIP != "" {
				r.Header.Set("X-Real-Ip", tc.realIP)
			}
			r.RemoteAddr = tc.remoteAddr
			if got := clientKey(r); got != tc.esperada {
				t.Fatalf("clientKey = %q, se esperaba %q", got, tc.esperada)
			}
		})
	}
}

func TestHandleForwardAuthPermiteYReportaRemaining(t *testing.T) {
	fake := &fakeChecker{decision: limiter.Decision{Allowed: true, Remaining: 4}}
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/forwardauth", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")

	handleForwardAuth(w, r, fake)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, se esperaba 200", w.Code)
	}
	if got := w.Header().Get("X-RateLimit-Remaining"); got != "4" {
		t.Fatalf("X-RateLimit-Remaining = %q, se esperaba 4", got)
	}
	if fake.gotKey != "rl:fwd:203.0.113.7" {
		t.Fatalf("key = %q, se esperaba rl:fwd:203.0.113.7", fake.gotKey)
	}
}

func TestHandleForwardAuthUsaRateYBurstDeEnv(t *testing.T) {
	t.Setenv("RATE", "2.5")
	t.Setenv("BURST", "7")
	fake := &fakeChecker{decision: limiter.Decision{Allowed: true, Remaining: 1}}
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/forwardauth", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")

	handleForwardAuth(w, r, fake)

	if fake.gotRate != 2.5 {
		t.Fatalf("rate = %v, se esperaba 2.5", fake.gotRate)
	}
	if fake.gotBurst != 7 {
		t.Fatalf("burst = %v, se esperaba 7", fake.gotBurst)
	}
}

func TestHandleForwardAuthDenegadoDevuelve429(t *testing.T) {
	fake := &fakeChecker{decision: limiter.Decision{Allowed: false, RetryAfter: 9}}
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/forwardauth", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")

	handleForwardAuth(w, r, fake)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, se esperaba 429", w.Code)
	}
	if got := w.Header().Get("Retry-After"); got != "9" {
		t.Fatalf("Retry-After = %q, se esperaba 9", got)
	}
}

func TestHandleForwardAuthFailOpenConRedisRoto(t *testing.T) {
	fake := &fakeChecker{err: errors.New("redis caído")}
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/forwardauth", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")

	handleForwardAuth(w, r, fake)

	// ADR-0005: degradar la protección, no la API.
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, se esperaba 200 (fail-open)", w.Code)
	}
	if got := w.Header().Get("X-RateLimit-Degraded"); got != "true" {
		t.Fatalf("X-RateLimit-Degraded = %q, se esperaba true", got)
	}
}

func TestHandleCheckMantieneContratoPrevio(t *testing.T) {
	t.Run("sin key devuelve 400", func(t *testing.T) {
		fake := &fakeChecker{}
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodGet, "/check", nil)
		handleCheck(w, r, fake)
		if w.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, se esperaba 400", w.Code)
		}
		if fake.checkCalls != 0 {
			t.Fatalf("no debe consultar el limitador sin key")
		}
	})

	t.Run("key válida consulta con rate y burst del query", func(t *testing.T) {
		fake := &fakeChecker{decision: limiter.Decision{Allowed: true, Remaining: 2}}
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodGet, "/check?key=abc&rate=3&burst=4", nil)
		handleCheck(w, r, fake)
		if w.Code != http.StatusOK {
			t.Fatalf("status = %d, se esperaba 200", w.Code)
		}
		if fake.gotKey != "rl:abc" || fake.gotRate != 3 || fake.gotBurst != 4 {
			t.Fatalf("parámetros = (%q, %v, %v), se esperaba (\"rl:abc\", 3, 4)", fake.gotKey, fake.gotRate, fake.gotBurst)
		}
	})
}
