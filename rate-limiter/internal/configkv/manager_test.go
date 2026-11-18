package configkv

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/limiter"
)

const testWebhookToken = "test-webhook-secret"

func basePolicy(t *testing.T) limiter.Policy {
	t.Helper()
	p, err := limiter.ParsePolicy(
		"POST /api/v2/documents=5:10",
		"/internal,/healthz,/metrics",
		"/internal/storage/events",
		testWebhookToken,
	)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func newManagerForTest(t *testing.T, c *Client, cache *Cache) (*Manager, *atomic.Pointer[limiter.Policy]) {
	t.Helper()
	base := basePolicy(t)
	ptr := &atomic.Pointer[limiter.Policy]{}
	ptr.Store(&base)
	return NewManager(c, cache, ptr, base), ptr
}

func sensitiveRate(p *limiter.Policy) float64 {
	if p == nil || len(p.SensitiveRoutes) == 0 {
		return 0
	}
	return p.SensitiveRoutes[0].Limit.Rate
}

func TestManagerInitDisabledUsesEnvironmentDefaults(t *testing.T) {
	cache := NewCache(filepath.Join(t.TempDir(), "config-cache.json"))
	if err := cache.Save(map[string]string{"sensitive_routes": "POST /x=1:1"}); err != nil {
		t.Fatal(err)
	}

	m, ptr := newManagerForTest(t, &Client{Disabled: true}, cache)
	m.Init()

	if got := sensitiveRate(ptr.Load()); got != 5 {
		t.Fatalf("rate = %v, want the env default 5", got)
	}
	if m.Enabled() {
		t.Fatal("manager should report disabled")
	}
}

func TestManagerInitAppliesCache(t *testing.T) {
	cache := NewCache(filepath.Join(t.TempDir(), "config-cache.json"))
	if err := cache.Save(map[string]string{
		"sensitive_routes": "POST /api/v2/documents=1:2",
		"exempt_paths":     "/healthz",
	}); err != nil {
		t.Fatal(err)
	}

	m, ptr := newManagerForTest(t, &Client{Disabled: true}, cache)
	// Cache load is skipped when disabled by design; enable the client but keep
	// KV unreachable so only the cache can apply.
	m.Client = &Client{Addr: "https://127.0.0.1:1", HTTP: &http.Client{Timeout: 50 * time.Millisecond}}
	m.Init()

	if got := sensitiveRate(ptr.Load()); got != 1 {
		t.Fatalf("rate = %v, want 1 from cache", got)
	}
}

func TestManagerStartupIsBoundedWhenConsulHangs(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer srv.Close()

	m, ptr := newManagerForTest(t, &Client{Addr: srv.URL, HTTP: srv.Client()}, nil)

	start := time.Now()
	m.Init()
	elapsed := time.Since(start)

	if elapsed > 3*time.Second {
		t.Fatalf("Init took %s, want < 3s with a hanging Consul", elapsed)
	}
	if ptr.Load() == nil {
		t.Fatal("policy must remain published after a failed KV read")
	}
	if !m.Stale(time.Now()) {
		t.Fatal("manager should report stale when KV never answered")
	}
}

func TestRejectedKeyKeepsPreviousValue(t *testing.T) {
	m, ptr := newManagerForTest(t, &Client{Disabled: true}, nil)

	if err := m.ApplyValues(map[string]string{
		"sensitive_routes": "POST /api/v2/documents=5:10",
		"exempt_paths":     "/healthz",
	}); err != nil {
		t.Fatal(err)
	}

	many := strings.TrimSuffix(strings.Repeat("/p,", 60), ",")
	if err := m.ApplyValues(map[string]string{
		"sensitive_routes": "POST /api/v2/documents=1:2",
		"exempt_paths":     many,
	}); err != nil {
		t.Fatal(err)
	}

	p := ptr.Load()
	if got := sensitiveRate(p); got != 1 {
		t.Fatalf("rate = %v, want the accepted 1", got)
	}
	if len(p.ExemptPaths) != 1 || p.ExemptPaths[0] != "/healthz" {
		t.Fatalf("exempt paths = %v, want the previous [/healthz]", p.ExemptPaths)
	}
}

func TestRejectionHookReportsKey(t *testing.T) {
	m, _ := newManagerForTest(t, &Client{Disabled: true}, nil)
	var rejected []string
	m.Hooks.OnReject = func(key string) { rejected = append(rejected, key) }

	if err := m.ApplyValues(map[string]string{"shadow_paths": "/admin"}); err != nil {
		t.Fatal(err)
	}
	if len(rejected) != 1 || rejected[0] != "shadow_paths" {
		t.Fatalf("rejected = %v", rejected)
	}
}

func TestInvalidPolicyDiscardsWholeSwap(t *testing.T) {
	cache := NewCache(filepath.Join(t.TempDir(), "config-cache.json"))
	m, ptr := newManagerForTest(t, &Client{Disabled: true}, cache)

	if err := m.ApplyValues(map[string]string{"sensitive_routes": "POST /x=1:2"}); err != nil {
		t.Fatal(err)
	}
	before := ptr.Load()

	if err := m.ApplyValues(map[string]string{"sensitive_routes": "not-a-route"}); err == nil {
		t.Fatal("expected a parse error for a malformed route")
	}
	if ptr.Load() != before {
		t.Fatal("a failed swap must keep the previous policy pointer")
	}
	if got := sensitiveRate(ptr.Load()); got != 1 {
		t.Fatalf("rate = %v, want the previous 1", got)
	}

	loaded, err := cache.Load()
	if err != nil {
		t.Fatal(err)
	}
	if loaded["sensitive_routes"] != "POST /x=1:2" {
		t.Fatalf("cache = %v, want the last valid value", loaded)
	}
}

func TestCachePersistsFullEffectiveSet(t *testing.T) {
	cache := NewCache(filepath.Join(t.TempDir(), "config-cache.json"))
	m, _ := newManagerForTest(t, &Client{Disabled: true}, cache)

	if err := m.ApplyValues(map[string]string{
		"sensitive_routes": "POST /api/v2/documents=1:2",
		"exempt_paths":     "/healthz",
	}); err != nil {
		t.Fatal(err)
	}
	raw, err := readCacheFile(cache.Path)
	if err != nil {
		t.Fatal(err)
	}
	if raw["sensitive_routes"] != "POST /api/v2/documents=1:2" || raw["exempt_paths"] != "/healthz" {
		t.Fatalf("cache = %v, want both effective keys", raw)
	}
}

func TestWebhookSecretNeverComesFromKV(t *testing.T) {
	m, ptr := newManagerForTest(t, &Client{Disabled: true}, nil)

	if err := m.ApplyValues(map[string]string{
		"sensitive_routes": "POST /api/v2/documents=1:2",
		"exempt_paths":     "/healthz",
		"webhook_token":    "attacker",
	}); err != nil {
		t.Fatal(err)
	}

	p := ptr.Load()
	if p.WebhookToken != testWebhookToken {
		t.Fatalf("webhook token = %q, want the environment secret", p.WebhookToken)
	}
	for _, path := range p.ExemptPaths {
		if path == "/api/v2" {
			t.Fatal("KV must never widen exemptions it was not allowed to set")
		}
	}
}

func TestWatchAppliesKVChanges(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Consul-Index", "3")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(kvBody(t, map[string]string{
			"sensitive_routes": "POST /api/v2/documents=2:4",
			"exempt_paths":     "/healthz",
		}))
	}))
	defer srv.Close()

	m, ptr := newManagerForTest(t, &Client{Addr: srv.URL, HTTP: srv.Client()}, nil)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go m.Watch(ctx)

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if sensitiveRate(ptr.Load()) == 2 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("rate = %v, want the KV value 2", sensitiveRate(ptr.Load()))
}

func TestStaleTransitions(t *testing.T) {
	m, _ := newManagerForTest(t, &Client{Disabled: true}, nil)
	now := time.Now()
	if !m.Stale(now) {
		t.Fatal("a manager with no valid read is stale")
	}
	if err := m.ApplyValues(map[string]string{"exempt_paths": "/healthz"}); err != nil {
		t.Fatal(err)
	}
	if m.Stale(now) {
		t.Fatal("a fresh apply is not stale")
	}
	if !m.Stale(now.Add(staleAfter + time.Minute)) {
		t.Fatal("an old apply must become stale")
	}
}

func readCacheFile(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	return m, nil
}

func TestInvalidPolicyReportsRejectedKey(t *testing.T) {
	cache := NewCache(filepath.Join(t.TempDir(), "config-cache.json"))
	m, _ := newManagerForTest(t, &Client{Disabled: true}, cache)

	var rejected []string
	m.Hooks.OnReject = func(key string) { rejected = append(rejected, key) }

	if err := m.ApplyValues(map[string]string{"sensitive_routes": "not-a-route"}); err == nil {
		t.Fatal("expected a parse error for a malformed route")
	}
	if len(rejected) != 1 || rejected[0] != "sensitive_routes" {
		t.Fatalf("rejected = %v, want [sensitive_routes]", rejected)
	}
}
