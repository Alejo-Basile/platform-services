// Comando ratelimitd: endpoint ForwardAuth `/check` sobre el núcleo GCRA.
//
// Contrato de `/check` (query params): `scope` (preferido) o el legado `key`,
// `rate` (default 10) y `burst` (default 5). Un error de Redis degrada a
// fail-open con `X-RateLimit-Degraded: true` (ADR-0005); parámetros inválidos
// devuelven 400.
//
// Precedencia sobre el path normalizado de `X-Forwarded-Uri` (sin query y con
// segmentos resueltos):
//  1. Webhook interno: exento solo con `Bearer` de token válido (compara en
//     tiempo constante). Sin token válido se limita; nunca cae en la lista
//     genérica de exenciones (anti-spoofing).
//  2. Lista explícita de exenciones: exenta sin consumir cuota.
//  3. Cualquier otra ruta exige identidad y evalúa, en un único EVAL atómico,
//     el límite global más un límite extra por cada ruta sensible exacta.
//
// Variables de entorno:
//   - LISTEN_ADDR (default ":8090"), REDIS_ADDR, REDIS_PASSWORD,
//     REDIS_PASSWORD_FILE.
//   - RL_EXEMPT_PATHS (default "/internal,/healthz,/metrics"): lista explícita
//     de exenciones segment-aware.
//   - RL_SENSITIVE_ROUTES (default "POST /api/v2/documents=5:10"): formato
//     "[METHOD ]path=rate:burst,...", p. ej. "POST /api/v2/documents=5:10".
//   - RL_WEBHOOK_PATH (default "/internal/storage/events").
//   - RL_WEBHOOK_TOKEN / RL_WEBHOOK_TOKEN_FILE: el token se toma primero de la
//     variable de entorno y, si está vacía, del archivo (con trim).
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
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/configkv"
	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/consulreg"
	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/limiter"
)

// kvManager guarda el manager del cliente KV para que /metrics publique su
// estado sin acoplar el paquete configkv al paquete main.
var kvManager atomic.Pointer[configkv.Manager]

func main() {
	addr := env("LISTEN_ADDR", ":8090")
	redisAddr := env("REDIS_ADDR", "redis-ratelimit:6379")
	redisPassword, err := redisPasswordFromEnv()
	if err != nil {
		log.Fatalf("redis password: %v", err)
	}

	policy, err := loadPolicyFromEnv()
	if err != nil {
		log.Fatalf("política de rate limit: %v", err)
	}

	client := limiter.NewClient(redisAddr, redisPassword)
	defer client.Close()
	lim := limiter.New(client)

	// Política viva: el swap es atómico y handleCheck la lee en cada request.
	policyPtr := &atomic.Pointer[limiter.Policy]{}
	policyPtr.Store(&policy)

	kvCtx, kvCancel := context.WithCancel(context.Background())
	defer kvCancel()

	mgr := configkv.NewManager(configkv.NewClient(), configkv.NewCache(""), policyPtr, policy)
	mgr.Hooks = configkv.Hooks{
		OnReject:  recordKVRejection,
		OnApplied: recordKVApplied,
	}
	kvManager.Store(mgr)
	// Init está acotado a 2 s: Consul caído no retrasa el arranque.
	mgr.Init()
	go mgr.Watch(kvCtx)
	// Registro en Consul: no bloqueante, tolera fallos.
	reg := consulreg.NewFromEnv(httpPortFromAddr(addr))
	reg.OnRegisterFailure = func() { metricConsulRegFailed.Add(1) }
	regCtx, regCancel := context.WithCancel(context.Background())
	go func() {
		reg.RegisterWithRetry(regCtx)
	}()

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
		handleCheck(w, r, lim, policyPtr)
	})
	mux.HandleFunc("/metrics", handleMetrics)

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

	// Detiene el watcher KV y el registro antes de cerrar el servidor.
	kvCancel()
	regCancel()

	deregCtx, deregCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer deregCancel()
	if err := reg.Deregister(deregCtx); err != nil {
		log.Printf("consul deregistration failed: %v", err)
		metricConsulRegFailed.Add(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

// httpPortFromAddr extrae el puerto de LISTEN_ADDR para publicarlo en el
// registro de Consul. Un valor sin puerto usable cae al default del servicio.
func httpPortFromAddr(addr string) int {
	const defaultPort = 8090
	i := strings.LastIndex(addr, ":")
	if i < 0 {
		return defaultPort
	}
	p, err := strconv.Atoi(addr[i+1:])
	if err != nil || p <= 0 {
		return defaultPort
	}
	return p
}

func redisPasswordFromEnv() (string, error) {
	if password := os.Getenv("REDIS_PASSWORD"); password != "" {
		return password, nil
	}
	passwordFile := os.Getenv("REDIS_PASSWORD_FILE")
	if passwordFile == "" {
		return "", nil
	}
	data, err := os.ReadFile(passwordFile)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

const (
	// El límite global conserva los valores por defecto actuales de `/check`.
	defaultRate  = 10
	defaultBurst = 5
	// La creación de documentos es la ruta sensible: dispara upload y
	// procesamiento asíncrono, por eso su límite es más estricto.
	defaultSensitiveRoutes = "POST /api/v2/documents=5:10"
	// Lista explícita de exenciones (nunca heurística de prefijo suelta).
	defaultExemptPaths = "/internal,/healthz,/metrics"
	// Endpoint interno que MinIO invoca; exento solo con el token compartido.
	defaultWebhookPath = "/internal/storage/events"
)

// rateChecker abstrae el núcleo GCRA multi-clave para testear el handler sin
// Redis. CheckAll evalúa todos los límites en un único EVAL atómico.
type rateChecker interface {
	CheckAll(context.Context, []limiter.Limit) (limiter.Decision, error)
}

func handleCheck(w http.ResponseWriter, r *http.Request, lim rateChecker, policy *atomic.Pointer[limiter.Policy]) {
	p := policy.Load()
	if p == nil {
		pp := limiter.Policy{}
		p = &pp
	}
	plan := p.Decide(limiter.Request{
		Method:        forwardedMethod(r),
		Path:          forwardedPath(r),
		Authorization: r.Header.Get("Authorization"),
	})
	if plan.Exempt {
		w.Header().Set("X-RateLimit-Exempt", "true")
		writeJSON(w, http.StatusOK, map[string]any{"allowed": true, "exempted": true})
		return
	}

	scope, ok := resolveScope(r)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "scope requerido (scope o key)"})

		return
	}
	rate, err := floatParam(r, "rate", defaultRate)
	if err != nil || rate <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "rate inválido"})
		return
	}
	burst, err := floatParam(r, "burst", defaultBurst)
	if err != nil || burst < 1 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "burst inválido"})
		return
	}

	limits := requestLimits(scope, clientIdentity(r), rate, burst, plan.Routes)

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	decision, err := lim.CheckAll(ctx, limits)
	if err != nil {
		// Fail-open controlado (ADR-0005): degradar la protección, no la API.
		setRedisUp(false)
		incMetric("degraded")
		w.Header().Set("X-RateLimit-Degraded", "true")
		writeJSON(w, http.StatusOK, map[string]any{
			"allowed":  true,
			"degraded": true,
		})
		return
	}

	setRedisUp(true)

	w.Header().Set("X-RateLimit-Remaining", strconv.FormatInt(decision.Remaining, 10))
	if decision.Allowed {
		incMetric("allowed")
		writeJSON(w, http.StatusOK, map[string]any{
			"allowed":   true,
			"remaining": decision.Remaining,
		})
		return
	}
	incMetric("denied")

	w.Header().Set("Retry-After", strconv.FormatInt(decision.RetryAfter, 10))
	w.Header().Set("X-RateLimit-Retry-After", strconv.FormatInt(decision.RetryAfter, 10))
	writeJSON(w, http.StatusTooManyRequests, map[string]any{
		"allowed":     false,
		"remaining":   0,
		"retry_after": decision.RetryAfter,
	})
}

// requestLimits arma el límite global más un límite por ruta sensible. Las
// claves reutilizan rateLimitKey para mantener el formato estable:
// `rl:{scope}:{identity}` y `rl:route:{METHOD}:{path}:{identity}`.
func requestLimits(scope, identity string, rate, burst float64, routes []limiter.RouteLimit) []limiter.Limit {
	limits := make([]limiter.Limit, 0, 1+len(routes))
	limits = append(limits, limiter.Limit{
		Key:   rateLimitKey(scope, identity),
		Rate:  rate,
		Burst: burst,
	})
	for _, route := range routes {
		method := route.Method
		if method == "" {
			method = "ANY"
		}
		limits = append(limits, limiter.Limit{
			Key:   rateLimitKey("route:"+method+":"+route.Path, identity),
			Rate:  route.Limit.Rate,
			Burst: route.Limit.Burst,
		})
	}
	return limits
}

// forwardedPath usa el URI original que Traefik envía en ForwardAuth.
func forwardedPath(r *http.Request) string {
	if uri := r.Header.Get("X-Forwarded-Uri"); uri != "" {
		return uri
	}
	return r.URL.RequestURI()
}

func forwardedMethod(r *http.Request) string {
	if method := r.Header.Get("X-Forwarded-Method"); method != "" {
		return method
	}
	return r.Method
}

// loadPolicyFromEnv lee la política explícita desde variables de entorno.
func loadPolicyFromEnv() (limiter.Policy, error) {
	token, err := webhookTokenFromEnv()
	if err != nil {
		return limiter.Policy{}, err
	}
	return limiter.ParsePolicy(
		env("RL_SENSITIVE_ROUTES", defaultSensitiveRoutes),
		env("RL_EXEMPT_PATHS", defaultExemptPaths),
		env("RL_WEBHOOK_PATH", defaultWebhookPath),
		token,
	)
}

// webhookTokenFromEnv prefiere RL_WEBHOOK_TOKEN y cae a RL_WEBHOOK_TOKEN_FILE.
func webhookTokenFromEnv() (string, error) {
	if token := os.Getenv("RL_WEBHOOK_TOKEN"); token != "" {
		return token, nil
	}
	file := os.Getenv("RL_WEBHOOK_TOKEN_FILE")
	if file == "" {
		return "", nil
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
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
