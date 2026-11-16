package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/limiter"
)

func TestHandleCheckAllowed(t *testing.T) {
	fake := &fakeChecker{decision: limiter.Decision{Allowed: true, Remaining: 5}}
	r := httptest.NewRequest(http.MethodGet, "/check?scope=api-v2", nil)
	r.Header.Set("X-Forwarded-For", "198.51.100.1, 203.0.113.7")
	w := httptest.NewRecorder()

	handleCheck(w, r, fake, testPolicy(t))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if got := w.Header().Get("X-RateLimit-Remaining"); got != "5" {
		t.Fatalf("X-RateLimit-Remaining = %q, want 5", got)
	}
	if fake.calls != 1 {
		t.Fatalf("checker calls = %d, want 1", fake.calls)
	}
	if len(fake.limits) != 1 || fake.limits[0].Key != "rl:api-v2:203.0.113.7" {
		t.Fatalf("limits = %+v, want global key rl:api-v2:203.0.113.7", fake.limits)
	}
	if fake.limits[0].Rate != defaultRate || fake.limits[0].Burst != defaultBurst {
		t.Fatalf("global rate/burst = %v/%v, want %v/%v", fake.limits[0].Rate, fake.limits[0].Burst, defaultRate, defaultBurst)
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

	handleCheck(w, r, fake, testPolicy(t))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if len(fake.limits) != 1 || fake.limits[0].Key != "rl:api-v2:203.0.113.7" {
		t.Fatalf("limits = %+v, want global key rl:api-v2:203.0.113.7", fake.limits)
	}
}

func TestHandleCheckTooManyRequests(t *testing.T) {
	fake := &fakeChecker{decision: limiter.Decision{Allowed: false, RetryAfter: 7}}
	r := httptest.NewRequest(http.MethodGet, "/check?scope=api-v2", nil)
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()

	handleCheck(w, r, fake, testPolicy(t))

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

	handleCheck(w, r, fake, testPolicy(t))

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

			handleCheck(w, r, fake, testPolicy(t))

			if w.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200", w.Code)
			}
			if fake.calls != 0 {
				t.Fatalf("checker calls = %d, want 0", fake.calls)
			}
			if got := w.Header().Get("X-RateLimit-Exempt"); got != "true" {
				t.Fatalf("X-RateLimit-Exempt = %q, want true", got)
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

	handleCheck(w, r, fake, testPolicy(t))

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

			handleCheck(w, r, fake, testPolicy(t))

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
	limits   []limiter.Limit
}

func (f *fakeChecker) CheckAll(_ context.Context, limits []limiter.Limit) (limiter.Decision, error) {
	f.calls++
	f.limits = append([]limiter.Limit(nil), limits...)
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

func TestWebhookWithoutValidTokenIsLimited(t *testing.T) {
	for _, uri := range []string{"/internal/storage/events", "/internal/../internal/storage/events"} {
		for _, authorization := range []string{"", "Bearer wrong"} {
			t.Run(uri+"/"+authorization, func(t *testing.T) {
				fake := &fakeChecker{decision: limiter.Decision{Allowed: false, RetryAfter: 3}}
				r := httptest.NewRequest(http.MethodPost, "/check?scope=api-v2", nil)
				r.Header.Set("X-Forwarded-Uri", uri)
				r.Header.Set("X-Forwarded-For", "203.0.113.7")
				r.Header.Set("Authorization", authorization)
				w := httptest.NewRecorder()

				handleCheck(w, r, fake, testPolicy(t))

				if w.Code != http.StatusTooManyRequests {
					t.Fatalf("status = %d, want 429 for unauthenticated webhook", w.Code)
				}
				if fake.calls != 1 || len(fake.limits) != 1 {
					t.Fatalf("checker calls/limits = %d/%d, want 1/1", fake.calls, len(fake.limits))
				}
			})
		}
	}
}

func TestWebhookWithValidTokenIsExempt(t *testing.T) {
	fake := &fakeChecker{}
	r := httptest.NewRequest(http.MethodPost, "/check?scope=api-v2", nil)
	r.Header.Set("X-Forwarded-Uri", "/internal/storage/events")
	r.Header.Set("Authorization", "Bearer test-secret")
	w := httptest.NewRecorder()

	handleCheck(w, r, fake, testPolicy(t))

	if w.Code != http.StatusOK || fake.calls != 0 {
		t.Fatalf("status/checker calls = %d/%d, want 200/0", w.Code, fake.calls)
	}
	if got := decodeBody(t, w.Body.Bytes()); got["exempted"] != true {
		t.Fatalf("response = %v, want exempted true", got)
	}
}

func TestNormalizedSensitiveRouteSaturationReturns429(t *testing.T) {
	fake := &fakeChecker{decision: limiter.Decision{Allowed: false, RetryAfter: 6}}
	r := httptest.NewRequest(http.MethodPost, "/check?scope=api-v2&rate=10&burst=20", nil)
	r.Header.Set("X-Forwarded-Uri", "/internal/../api/v2/documents?from=forwardauth")
	r.Header.Set("X-Forwarded-Method", "post")
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()

	handleCheck(w, r, fake, testPolicy(t))

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", w.Code)
	}
	if w.Header().Get("Retry-After") != "6" || w.Header().Get("X-RateLimit-Retry-After") != "6" {
		t.Fatalf("retry headers = %q/%q, want 6/6", w.Header().Get("Retry-After"), w.Header().Get("X-RateLimit-Retry-After"))
	}
	if len(fake.limits) != 2 {
		t.Fatalf("limits count = %d, want global and sensitive route", len(fake.limits))
	}
	if fake.limits[0].Key != "rl:api-v2:203.0.113.7" {
		t.Fatalf("global key = %q", fake.limits[0].Key)
	}
	if fake.limits[1].Key != "rl:route:POST:/api/v2/documents:203.0.113.7" {
		t.Fatalf("route key = %q", fake.limits[1].Key)
	}
	if fake.limits[1].Rate != 1 || fake.limits[1].Burst != 1 {
		t.Fatalf("route rate/burst = %v/%v, want 1/1", fake.limits[1].Rate, fake.limits[1].Burst)
	}
}

func TestWebhookPathDoesNotFallThroughToGenericExempt(t *testing.T) {
	fake := &fakeChecker{decision: limiter.Decision{Allowed: false, RetryAfter: 1}}
	r := httptest.NewRequest(http.MethodPost, "/check?scope=api-v2", nil)
	r.Header.Set("X-Forwarded-Uri", "/internal/storage/events/child")
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()

	handleCheck(w, r, fake, testPolicy(t))

	if w.Code != http.StatusTooManyRequests || fake.calls != 1 {
		t.Fatalf("status/checker calls = %d/%d, want 429/1", w.Code, fake.calls)
	}
}

func TestNonCanonicalExemptPathIsLimited(t *testing.T) {
	for _, uri := range []string{"//healthz", "/internal/../healthz"} {
		t.Run(uri, func(t *testing.T) {
			fake := &fakeChecker{decision: limiter.Decision{Allowed: false, RetryAfter: 2}}
			r := httptest.NewRequest(http.MethodGet, "/check?scope=api-v2", nil)
			r.Header.Set("X-Forwarded-Uri", uri)
			r.Header.Set("X-Forwarded-For", "203.0.113.7")
			w := httptest.NewRecorder()

			handleCheck(w, r, fake, testPolicy(t))

			if w.Code != http.StatusTooManyRequests {
				t.Fatalf("status = %d, want 429 for a non-canonical path", w.Code)
			}
			if fake.calls != 1 {
				t.Fatalf("checker calls = %d, want 1", fake.calls)
			}
		})
	}
}

func testPolicy(t *testing.T) limiter.Policy {
	t.Helper()
	policy, err := limiter.ParsePolicy("POST /api/v2/documents=1:1", defaultExemptPaths, defaultWebhookPath, "test-secret")
	if err != nil {
		t.Fatal(err)
	}
	return policy
}

func TestWebhookTokenEnvironmentPrecedenceAndFileFallback(t *testing.T) {
	t.Run("environment takes precedence", func(t *testing.T) {
		tokenFile := filepath.Join(t.TempDir(), "webhook-token")
		if err := os.WriteFile(tokenFile, []byte("file-token\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		t.Setenv("RL_WEBHOOK_TOKEN", "environment-token")
		t.Setenv("RL_WEBHOOK_TOKEN_FILE", tokenFile)

		got, err := webhookTokenFromEnv()
		if err != nil {
			t.Fatal(err)
		}
		if got != "environment-token" {
			t.Fatalf("token = %q, want environment-token", got)
		}
	})

	t.Run("file fallback is trimmed", func(t *testing.T) {
		tokenFile := filepath.Join(t.TempDir(), "webhook-token")
		if err := os.WriteFile(tokenFile, []byte("  file-token\n\t"), 0o600); err != nil {
			t.Fatal(err)
		}
		t.Setenv("RL_WEBHOOK_TOKEN", "")
		t.Setenv("RL_WEBHOOK_TOKEN_FILE", tokenFile)

		got, err := webhookTokenFromEnv()
		if err != nil {
			t.Fatal(err)
		}
		if got != "file-token" {
			t.Fatalf("token = %q, want file-token", got)
		}
	})
}

func TestLoadPolicyFromEnvironment(t *testing.T) {
	t.Setenv("RL_SENSITIVE_ROUTES", "GET /private=2:4")
	t.Setenv("RL_EXEMPT_PATHS", "/healthz")
	t.Setenv("RL_WEBHOOK_PATH", "/private/events")
	t.Setenv("RL_WEBHOOK_TOKEN", "environment-token")
	t.Setenv("RL_WEBHOOK_TOKEN_FILE", "")

	policy, err := loadPolicyFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if policy.WebhookPath != "/private/events" || policy.WebhookToken != "environment-token" {
		t.Fatalf("webhook configuration = %q/%q", policy.WebhookPath, policy.WebhookToken)
	}
	if len(policy.ExemptPaths) != 1 || policy.ExemptPaths[0] != "/healthz" {
		t.Fatalf("exempt paths = %v, want [/healthz]", policy.ExemptPaths)
	}
	plan := policy.Decide(limiter.Request{Method: "GET", Path: "/private"})
	if len(plan.Routes) != 1 || plan.Routes[0].Limit != (limiter.LimitSpec{Rate: 2, Burst: 4}) {
		t.Fatalf("sensitive route = %+v, want GET /private at 2:4", plan.Routes)
	}
}
