package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/limiter"
)

// TestHandleCheckSeesHotReloadedPolicy es el test de PRESERVE del hot-reload:
// si handleCheck capturara la política por valor, el segundo request seguiría
// viendo el límite viejo y este test fallaría.
func TestHandleCheckSeesHotReloadedPolicy(t *testing.T) {
	fake := &fakeChecker{decision: limiter.Decision{Allowed: true, Remaining: 1}}
	ptr := testPolicy(t)

	request := func() []limiter.Limit {
		r := httptest.NewRequest(http.MethodGet, "/check?scope=api-v2", nil)
		r.Header.Set("X-Forwarded-Method", http.MethodPost)
		r.Header.Set("X-Forwarded-Uri", "/api/v2/documents")
		r.Header.Set("X-Forwarded-For", "203.0.113.9")
		w := httptest.NewRecorder()
		handleCheck(w, r, fake, ptr)
		if w.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", w.Code)
		}
		return fake.limits
	}

	first := request()
	if len(first) != 2 || first[1].Rate != 1 {
		t.Fatalf("limits iniciales = %+v, want la ruta sensible con rate 1", first)
	}

	next, err := limiter.ParsePolicy("POST /api/v2/documents=7:9", defaultExemptPaths, defaultWebhookPath, "test-secret")
	if err != nil {
		t.Fatal(err)
	}
	ptr.Store(&next)

	second := request()
	if len(second) != 2 || second[1].Rate != 7 {
		t.Fatalf("limits tras el swap = %+v, want la ruta sensible con rate 7", second)
	}
}
