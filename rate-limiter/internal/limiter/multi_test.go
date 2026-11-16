package limiter

import (
	"context"
	"testing"

	"github.com/redis/go-redis/v9"
)

func TestCheckAllRejectsInvalidLimitSetsBeforeRedis(t *testing.T) {
	cases := []struct {
		name   string
		limits []Limit
	}{
		{name: "empty set"},
		{name: "zero rate", limits: []Limit{{Key: "rl:a", Rate: 0, Burst: 1}}},
		{name: "burst below one", limits: []Limit{{Key: "rl:a", Rate: 1, Burst: 0}}},
		{name: "missing key", limits: []Limit{{Key: "", Rate: 1, Burst: 1}}},
		{name: "invalid later limit", limits: []Limit{{Key: "rl:a", Rate: 1, Burst: 1}, {Key: "rl:b", Rate: -1, Burst: 1}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
			t.Cleanup(func() { _ = client.Close() })
			limiter := New(client)

			if _, err := limiter.CheckAll(context.Background(), tc.limits); err == nil {
				t.Fatal("CheckAll returned no validation error")
			}
		})
	}
}
