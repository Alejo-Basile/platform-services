package limiter

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"
)

// TestCheckAllIsAtomicAgainstRedis verifies that rejection by one limit leaves
// every involved Redis counter unchanged. It skips when REDIS_ADDR is unset.
func TestCheckAllIsAtomicAgainstRedis(t *testing.T) {
	addr := os.Getenv("REDIS_ADDR")
	if addr == "" {
		t.Skip("REDIS_ADDR not defined: integration test skipped")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client := NewClient(addr, os.Getenv("REDIS_PASSWORD"))
	defer client.Close()
	if err := client.Ping(ctx).Err(); err != nil {
		t.Fatalf("ping Redis: %v", err)
	}

	globalKey := fmt.Sprintf("rl:test:multi:global:%d", time.Now().UnixNano())
	routeKey := globalKey + ":route"
	defer client.Del(ctx, globalKey, routeKey)
	limiter := New(client)

	if decision, err := limiter.Check(ctx, globalKey, 10, 10); err != nil || !decision.Allowed {
		t.Fatalf("seed global counter: allowed=%v err=%v", decision.Allowed, err)
	}
	if decision, err := limiter.Check(ctx, routeKey, 0.1, 1); err != nil || !decision.Allowed {
		t.Fatalf("seed route counter: allowed=%v err=%v", decision.Allowed, err)
	}

	before := make([]string, 0, 2)
	for _, key := range []string{globalKey, routeKey} {
		value, err := client.Get(ctx, key).Result()
		if err != nil {
			t.Fatalf("read seeded counter %q: %v", key, err)
		}
		before = append(before, value)
	}

	decision, err := limiter.CheckAll(ctx, []Limit{
		{Key: globalKey, Rate: 10, Burst: 10},
		{Key: routeKey, Rate: 0.1, Burst: 1},
	})
	if err != nil {
		t.Fatalf("CheckAll: %v", err)
	}
	if decision.Allowed {
		t.Fatal("a saturated limit must reject the request")
	}
	if decision.RetryAfter < 1 {
		t.Fatalf("RetryAfter = %d, want at least 1 second", decision.RetryAfter)
	}

	for i, key := range []string{globalKey, routeKey} {
		after, err := client.Get(ctx, key).Result()
		if err != nil {
			t.Fatalf("read counter after rejection %q: %v", key, err)
		}
		if after != before[i] {
			t.Fatalf("counter %q changed on rejection: before=%q after=%q", key, before[i], after)
		}
	}
}
