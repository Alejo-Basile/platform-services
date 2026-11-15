package main

import (
	"fmt"
	"net/http"
	"sync/atomic"
)

// metrics state: counters and redis up gauge.
var (
	metricAllowed  atomic.Int64
	metricDenied   atomic.Int64
	metricDegraded atomic.Int64
	metricRedisUp  atomic.Int64
)

func incMetric(decision string) {
	switch decision {
	case "allowed":
		metricAllowed.Add(1)
	case "denied":
		metricDenied.Add(1)
	case "degraded":
		metricDegraded.Add(1)
	}
}

func setRedisUp(v bool) {
	if v {
		metricRedisUp.Store(1)
	} else {
		metricRedisUp.Store(0)
	}
}

func handleMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, "# HELP ratelimit_requests_total Rate limit decisions issued by the ForwardAuth wrapper.\n")
	fmt.Fprintf(w, "# TYPE ratelimit_requests_total counter\n")
	fmt.Fprintf(w, "ratelimit_requests_total{decision=\"allowed\"} %d\n", metricAllowed.Load())
	fmt.Fprintf(w, "ratelimit_requests_total{decision=\"denied\"} %d\n", metricDenied.Load())
	fmt.Fprintf(w, "ratelimit_requests_total{decision=\"degraded\"} %d\n", metricDegraded.Load())
	fmt.Fprintf(w, "# HELP ratelimit_redis_up 1 when the last Redis check succeeded, 0 when the wrapper served fail-open.\n")
	fmt.Fprintf(w, "# TYPE ratelimit_redis_up gauge\n")
	fmt.Fprintf(w, "ratelimit_redis_up %d\n", metricRedisUp.Load())
}
