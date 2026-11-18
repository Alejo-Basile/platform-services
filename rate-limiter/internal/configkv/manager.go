package configkv

import (
	"context"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/limiter"
)

const (
	// DefaultCachePath es la caché last-known-good del servicio. Vive en un
	// volumen nombrado porque el contenedor corre con rootfs de solo lectura.
	DefaultCachePath = "/var/lib/ratelimitd/config-cache.json"

	staleAfter = 15 * time.Minute
)

// Hooks permite al proceso publicar el estado del cliente KV en sus métricas
// sin que este paquete dependa del paquete main.
type Hooks struct {
	OnReject  func(key string)
	OnApplied func(at time.Time)
}

// Manager aplica defaults de entorno, luego la caché last-known-good y después
// el estado de Consul KV, publicando la política viva de forma atómica.
type Manager struct {
	Client  *Client
	Cache   *Cache
	Pointer *atomic.Pointer[limiter.Policy]
	Base    limiter.Policy
	Hooks   Hooks

	mu        sync.Mutex
	effective map[string]string
	lastOK    time.Time
	hasValid  bool
}

// NewManager construye el manager. Base es la política de entorno; sus campos
// de webhook nunca se sobrescriben desde KV.
func NewManager(c *Client, cache *Cache, ptr *atomic.Pointer[limiter.Policy], base limiter.Policy) *Manager {
	eff := map[string]string{}
	if v, ok := RateLimiterSchema["sensitive_routes"].Default.(string); ok {
		eff["sensitive_routes"] = v
	}
	if v, ok := RateLimiterSchema["exempt_paths"].Default.(string); ok {
		eff["exempt_paths"] = v
	}
	return &Manager{
		Client:    c,
		Cache:     cache,
		Pointer:   ptr,
		Base:      base,
		effective: eff,
	}
}

// Enabled informa si el cliente KV está activo.
func (m *Manager) Enabled() bool { return m.Client != nil && !m.Client.Disabled }

// Stale informa si la última configuración válida supera el umbral o si nunca
// hubo una aplicación válida.
func (m *Manager) Stale(now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return !m.hasValid || now.Sub(m.lastOK) > staleAfter
}

// LastSuccess devuelve el instante de la última aplicación válida.
func (m *Manager) LastSuccess() (time.Time, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastOK, m.hasValid
}

func (m *Manager) snapshotEffective() map[string]string {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[string]string, len(m.effective))
	for k, v := range m.effective {
		out[k] = v
	}
	return out
}

// ApplyValues valida el conjunto completo y publica la política resultante.
// Un rechazo por clave conserva el valor vigente de ESA clave; un parseo
// fallido descarta el cambio entero y deja la política anterior publicada.
func (m *Manager) ApplyValues(values map[string]string) error {
	accepted, rejections := ValidateRaw(values)
	for _, r := range rejections {
		log.Printf("configkv rejected key=%q reason=%s", r.Key, r.Reason)
		if m.Hooks.OnReject != nil {
			m.Hooks.OnReject(r.Key)
		}
	}

	candidate := m.snapshotEffective()
	for k, v := range accepted {
		candidate[k] = v
	}

	policy, err := limiter.ParsePolicyFromKV(candidate, m.Base)
	if err != nil {
		log.Printf("configkv: politica invalida, se conserva la anterior: %v", err)
		// El descarte es del conjunto: se atribuye a las claves que entraron en
		// este lote, para que el rechazo sea visible en las metricas.
		for key := range accepted {
			if m.Hooks.OnReject != nil {
				m.Hooks.OnReject(key)
			}
		}
		return err
	}

	m.Pointer.Store(&policy)

	m.mu.Lock()
	m.effective = candidate
	m.lastOK = time.Now()
	m.hasValid = true
	appliedAt := m.lastOK
	m.mu.Unlock()

	if m.Hooks.OnApplied != nil {
		m.Hooks.OnApplied(appliedAt)
	}
	if m.Cache != nil {
		if err := m.Cache.Save(candidate); err != nil {
			log.Printf("configkv: no se pudo guardar la cache: %v", err)
		}
	}
	return nil
}

// Init arranca con defaults, superpone la caché y hace una lectura acotada a
// 2 s para que un Consul caído no retrase el arranque.
func (m *Manager) Init() {
	if m.Pointer.Load() == nil {
		base := m.Base
		m.Pointer.Store(&base)
	}
	if !m.Enabled() {
		log.Printf("configkv deshabilitado: defaults de entorno")
		return
	}
	if m.Cache != nil {
		if cached, err := m.Cache.Load(); err == nil && cached != nil {
			if err := m.ApplyValues(cached); err != nil {
				log.Printf("configkv: cache descartada: %v", err)
			}
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	vals, _, _, err := m.Client.Get(ctx, 0, 0)
	if err != nil {
		log.Printf("configkv: lectura inicial fallida, se sigue con defaults/cache: %v", err)
		return
	}
	if vals != nil {
		if err := m.ApplyValues(vals); err != nil {
			log.Printf("configkv: estado inicial descartado: %v", err)
		}
	}
}

// Watch mantiene el blocking query activo hasta que se cancele el contexto.
func (m *Manager) Watch(ctx context.Context) {
	if !m.Enabled() {
		return
	}
	m.Client.Watch(ctx, func(values map[string]string) error {
		return m.ApplyValues(values)
	})
}
