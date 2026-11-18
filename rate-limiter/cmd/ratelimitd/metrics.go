package main

import (
	"fmt"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// metrics state: counters, gauges y estado del cliente KV.
var (
	metricAllowed         atomic.Int64
	metricDenied          atomic.Int64
	metricDegraded        atomic.Int64
	metricRedisUp         atomic.Int64
	metricKVLastSuccess   atomic.Int64
	metricKVStale         atomic.Int64
	metricConsulRegFailed atomic.Int64

	kvRejectedMu      sync.Mutex
	kvRejectedByKey   = map[string]int64{}
	kvRejectedUnknown int64
)

// recordKVRejection acumula rechazos por clave para
// ratelimitd_config_kv_rejected_total{key}.
func recordKVRejection(key string) {
	kvRejectedMu.Lock()
	defer kvRejectedMu.Unlock()
	if key == "" {
		kvRejectedUnknown++
		return
	}
	kvRejectedByKey[key]++
}

// recordKVApplied publica el instante de la última aplicación válida.
func recordKVApplied(at time.Time) {
	metricKVLastSuccess.Store(at.Unix())
}

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
		return
	}
	metricRedisUp.Store(0)
}

// exportKVState publica el estado del cliente KV. Sin manager (tests) reporta
// stale=0 y timestamp=0 para no inventar degradación.
func exportKVState(w http.ResponseWriter) {
	stale := int64(0)
	if mgr := kvManager.Load(); mgr != nil {
		metricKVStale.Store(boolToInt64(mgr.Stale(time.Now())))
		if at, ok := mgr.LastSuccess(); ok {
			metricKVLastSuccess.Store(at.Unix())
		}
		stale = metricKVStale.Load()
	}

	fmt.Fprintf(w, "# HELP ratelimitd_config_kv_last_success_timestamp_seconds Ultima lectura valida de Consul KV.\n")
	fmt.Fprintf(w, "# TYPE ratelimitd_config_kv_last_success_timestamp_seconds gauge\n")
	fmt.Fprintf(w, "ratelimitd_config_kv_last_success_timestamp_seconds %d\n", metricKVLastSuccess.Load())

	fmt.Fprintf(w, "# HELP ratelimitd_config_kv_rejected_total Claves rechazadas por la validacion KV.\n")
	fmt.Fprintf(w, "# TYPE ratelimitd_config_kv_rejected_total counter\n")
	kvRejectedMu.Lock()
	keys := make([]string, 0, len(kvRejectedByKey))
	for k := range kvRejectedByKey {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(w, "ratelimitd_config_kv_rejected_total{key=%q} %d\n", k, kvRejectedByKey[k])
	}
	if kvRejectedUnknown > 0 {
		fmt.Fprintf(w, "ratelimitd_config_kv_rejected_total{key=\"unknown\"} %d\n", kvRejectedUnknown)
	}
	kvRejectedMu.Unlock()

	fmt.Fprintf(w, "# HELP ratelimitd_config_kv_stale 1 cuando la ultima configuracion valida supera 15 min.\n")
	fmt.Fprintf(w, "# TYPE ratelimitd_config_kv_stale gauge\n")
	fmt.Fprintf(w, "ratelimitd_config_kv_stale %d\n", stale)

	fmt.Fprintf(w, "# HELP ratelimitd_consul_registration_failed_total Fallos del registro en Consul.\n")
	fmt.Fprintf(w, "# TYPE ratelimitd_consul_registration_failed_total counter\n")
	fmt.Fprintf(w, "ratelimitd_consul_registration_failed_total %d\n", metricConsulRegFailed.Load())
}

func boolToInt64(v bool) int64 {
	if v {
		return 1
	}
	return 0
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
	exportKVState(w)
}
