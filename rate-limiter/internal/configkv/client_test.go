package configkv

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func testClient(t *testing.T, srv *httptest.Server) *Client {
	t.Helper()
	return &Client{Addr: srv.URL, HTTP: srv.Client()}
}

func kvBody(t *testing.T, pairs map[string]string) []byte {
	t.Helper()
	type entry struct {
		Key   string `json:"Key"`
		Value string `json:"Value"`
	}
	out := make([]entry, 0, len(pairs))
	for k, v := range pairs {
		out = append(out, entry{Key: "config/rate-limiter/" + k, Value: base64.StdEncoding.EncodeToString([]byte(v))})
	}
	body, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func TestGetDecodesValuesAndIndex(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("recurse"); got != "" && got != "true" {
			t.Errorf("recurse = %q", got)
		}
		w.Header().Set("X-Consul-Index", "42")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(kvBody(t, map[string]string{
			"sensitive_routes": "POST /api/v2/documents=5:10",
			"exempt_paths":     "/healthz",
		}))
	}))
	defer srv.Close()

	values, idx, status, err := testClient(t, srv).Get(context.Background(), 0, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d", status)
	}
	if idx != 42 {
		t.Fatalf("index = %d, want 42", idx)
	}
	if values["sensitive_routes"] != "POST /api/v2/documents=5:10" || values["exempt_paths"] != "/healthz" {
		t.Fatalf("values = %v", values)
	}
}

func TestGetPassesIndexAndHonorsNotModified(t *testing.T) {
	var gotIndex string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotIndex = r.URL.Query().Get("index")
		w.WriteHeader(http.StatusNotModified)
	}))
	defer srv.Close()

	_, _, status, err := testClient(t, srv).Get(context.Background(), 77, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if gotIndex != "77" {
		t.Fatalf("index enviado = %q, want 77", gotIndex)
	}
	if status != http.StatusNotModified {
		t.Fatalf("status = %d, want 304", status)
	}
}

func TestGetServerErrorReturnsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	_, _, status, err := testClient(t, srv).Get(context.Background(), 0, time.Second)
	if err == nil {
		t.Fatal("expected error on 500")
	}
	if status != http.StatusInternalServerError {
		t.Fatalf("status = %d", status)
	}
}

func TestWatchRecoversAfterError(t *testing.T) {
	var calls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.Header().Set("X-Consul-Index", "9")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(kvBody(t, map[string]string{"exempt_paths": "/healthz"}))
	}))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	got := make(chan map[string]string, 1)
	go testClient(t, srv).Watch(ctx, func(values map[string]string) error {
		select {
		case got <- values:
		default:
		}
		return nil
	})

	select {
	case values := <-got:
		if values["exempt_paths"] != "/healthz" {
			t.Fatalf("values = %v", values)
		}
	case <-ctx.Done():
		t.Fatal("watch did not recover after a 500")
	}
}

func TestWatchStopsWhenContextCanceled(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		testClient(t, srv).Watch(ctx, func(map[string]string) error { return nil })
		close(done)
	}()
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("watch did not stop on cancel")
	}
}

func TestDisabledClientNeverCallsConsul(t *testing.T) {
	c := &Client{Addr: "https://127.0.0.1:1", Disabled: true}
	values, _, status, err := c.Get(context.Background(), 0, time.Second)
	if err != nil || values != nil || status != http.StatusOK {
		t.Fatalf("disabled Get = (%v, %d, %v)", values, status, err)
	}
}

func TestNewClientMissingCADegrades(t *testing.T) {
	t.Setenv("CONSUL_HTTP_ADDR", "https://consul:8501")
	t.Setenv("CONSUL_CACERT", filepath.Join(t.TempDir(), "missing.pem"))
	t.Setenv("CONSUL_TOKEN_FILE", filepath.Join(t.TempDir(), "missing.token"))

	c := NewClient()
	if c.HTTP == nil || c.HTTP.Transport == nil {
		t.Fatal("transport not configured")
	}
	if c.Addr != "https://consul:8501" {
		t.Fatalf("addr = %q", c.Addr)
	}
	if c.Disabled {
		t.Fatal("client should be enabled without CONSUL_KV_DISABLED")
	}
}
