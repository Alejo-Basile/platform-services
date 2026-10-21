// Comando ratelimitd: wrapper HTTP mínimo sobre el núcleo GCRA.
// En S1 sirve para probar el script con k6; el ForwardAuth completo es S7.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/limiter"
)

func main() {
	addr := env("LISTEN_ADDR", ":8090")
	redisAddr := env("REDIS_ADDR", "redis-ratelimit:6379")
	redisPassword := os.Getenv("REDIS_PASSWORD")

	client := limiter.NewClient(redisAddr, redisPassword)
	defer client.Close()
	lim := limiter.New(client)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := lim.Ping(ctx); err != nil {
			http.Error(w, `{"status":"degraded"}`, http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("/check", func(w http.ResponseWriter, r *http.Request) {
		handleCheck(w, r, lim)
	})

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 3 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	go func() {
		log.Printf("ratelimitd escuchando en %s (redis=%s)", addr, redisAddr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("servidor: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

func handleCheck(w http.ResponseWriter, r *http.Request, lim *limiter.Limiter) {
	key := r.URL.Query().Get("key")
	if key == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "key requerida"})
		return
	}
	rate, err := floatParam(r, "rate", 10)
	if err != nil || rate <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "rate inválido"})
		return
	}
	burst, err := floatParam(r, "burst", 5)
	if err != nil || burst < 1 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "burst inválido"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	decision, err := lim.Check(ctx, "rl:"+key, rate, burst)
	if err != nil {
		// Fail-open controlado (ADR-0005): degradar la protección, no la API.
		w.Header().Set("X-RateLimit-Degraded", "true")
		writeJSON(w, http.StatusOK, map[string]any{
			"allowed":  true,
			"degraded": true,
		})
		return
	}

	w.Header().Set("X-RateLimit-Remaining", strconv.FormatInt(decision.Remaining, 10))
	if decision.Allowed {
		writeJSON(w, http.StatusOK, map[string]any{
			"allowed":   true,
			"remaining": decision.Remaining,
		})
		return
	}

	w.Header().Set("Retry-After", strconv.FormatInt(decision.RetryAfter, 10))
	w.Header().Set("X-RateLimit-Retry-After", strconv.FormatInt(decision.RetryAfter, 10))
	writeJSON(w, http.StatusTooManyRequests, map[string]any{
		"allowed":     false,
		"remaining":   0,
		"retry_after": decision.RetryAfter,
	})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func floatParam(r *http.Request, name string, def float64) (float64, error) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return def, nil
	}
	return strconv.ParseFloat(raw, 64)
}

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}
