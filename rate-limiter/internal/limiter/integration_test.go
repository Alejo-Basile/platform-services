package limiter

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"
)

// TestGCRAAgainstRedis valida el script Lua real. Se salta si REDIS_ADDR no
// está definido (CI sin Redis); la evidencia de S1 se genera contra
// `redis-ratelimit` del Compose.
func TestGCRAAgainstRedis(t *testing.T) {
	addr := os.Getenv("REDIS_ADDR")
	if addr == "" {
		t.Skip("REDIS_ADDR no definido: test de integración omitido")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client := NewClient(addr, os.Getenv("REDIS_PASSWORD"))
	defer client.Close()
	if err := client.Ping(ctx).Err(); err != nil {
		t.Fatalf("ping Redis: %v", err)
	}

	key := fmt.Sprintf("rl:test:%d", time.Now().UnixNano())
	defer client.Del(ctx, key)

	lim := New(client)

	first, err := lim.Check(ctx, key, 0.1, 1)
	if err != nil {
		t.Fatalf("primer check: %v", err)
	}
	if !first.Allowed {
		t.Fatalf("la primera petición debe permitirse")
	}
	if first.Remaining != 0 {
		t.Fatalf("remaining = %d, se esperaba 0", first.Remaining)
	}

	second, err := lim.Check(ctx, key, 0.1, 1)
	if err != nil {
		t.Fatalf("segundo check: %v", err)
	}
	if second.Allowed {
		t.Fatalf("la segunda petición debe rechazarse")
	}
	if second.RetryAfter < 1 {
		t.Fatalf("retry_after = %d, se esperaba >= 1", second.RetryAfter)
	}

	ttl, err := client.TTL(ctx, key).Result()
	if err != nil {
		t.Fatalf("ttl: %v", err)
	}
	if ttl <= 0 {
		t.Fatalf("la clave debe tener TTL, ttl=%s", ttl)
	}
}
