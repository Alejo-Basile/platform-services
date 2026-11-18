package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMetricsExposeConsulKVState(t *testing.T) {
	recordKVRejection("exempt_paths")
	recordKVApplied(time.Unix(1700000000, 0))

	w := httptest.NewRecorder()
	handleMetrics(w, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := w.Body.String()

	for _, want := range []string{
		`ratelimitd_config_kv_rejected_total{key="exempt_paths"}`,
		"ratelimitd_config_kv_last_success_timestamp_seconds 1700000000",
		"ratelimitd_config_kv_stale 0",
		"ratelimitd_consul_registration_failed_total 0",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing metric %q in:\n%s", want, body)
		}
	}
}
