// Package limiter implementa el núcleo atómico de rate limiting GCRA (ADR-0005).
package limiter

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/redis/go-redis/v9"
)

//go:embed gcra.lua
var gcraScript string

// Decision es el resultado de una comprobación de rate limit.
type Decision struct {
	Allowed    bool
	Remaining  int64
	RetryAfter int64 // segundos; 0 si la petición fue admitida
}

// State es el resultado del cálculo puro (sin Redis), usado por los tests.
type State struct {
	Decision
	NewTAT     int64
	TTLSeconds int64
}

// Limiter ejecuta el script GCRA contra Redis.
type Limiter struct {
	client *redis.Client
	script *redis.Script
}

// New crea un Limiter sobre un cliente Redis ya configurado.
func New(client *redis.Client) *Limiter {
	return &Limiter{client: client, script: redis.NewScript(gcraScript)}
}

// NewClient crea el cliente Redis usado por el rate limiter.
func NewClient(addr, password string) *redis.Client {
	return redis.NewClient(&redis.Options{
		Addr:         addr,
		Password:     password,
		DB:           0,
		DialTimeout:  2 * time.Second,
		ReadTimeout:  2 * time.Second,
		WriteTimeout: 2 * time.Second,
	})
}

// Check evalúa una petición para `key` con la tasa y ráfaga indicadas.
func (l *Limiter) Check(ctx context.Context, key string, rate, burst float64) (Decision, error) {
	if rate <= 0 {
		return Decision{}, fmt.Errorf("rate debe ser > 0")
	}
	if burst < 1 {
		return Decision{}, fmt.Errorf("burst debe ser >= 1")
	}

	res, err := l.script.Run(ctx, l.client, []string{key}, rate, burst).Result()
	if err != nil {
		return Decision{}, err
	}

	values, ok := res.([]interface{})
	if !ok || len(values) != 3 {
		return Decision{}, fmt.Errorf("respuesta inesperada del script: %T", res)
	}

	allowed, err := toInt64(values[0])
	if err != nil {
		return Decision{}, err
	}
	remaining, err := toInt64(values[1])
	if err != nil {
		return Decision{}, err
	}
	retryAfter, err := toInt64(values[2])
	if err != nil {
		return Decision{}, err
	}

	return Decision{
		Allowed:    allowed == 1,
		Remaining:  remaining,
		RetryAfter: retryAfter,
	}, nil
}

// Ping comprueba la conectividad con Redis.
func (l *Limiter) Ping(ctx context.Context) error {
	return l.client.Ping(ctx).Err()
}

// Close libera el cliente Redis.
func (l *Limiter) Close() error {
	return l.client.Close()
}

func toInt64(v interface{}) (int64, error) {
	switch n := v.(type) {
	case int64:
		return n, nil
	case int:
		return int64(n), nil
	case float64:
		return int64(n), nil
	case string:
		var out int64
		if _, err := fmt.Sscan(n, &out); err != nil {
			return 0, err
		}
		return out, nil
	default:
		return 0, errors.New("tipo numérico no soportado")
	}
}

// Calculate reproduce en Go el cálculo de gcra.lua para tests unitarios.
// `nowUs` y `tatUs` están en microsegundos; `tatUs == 0` significa sin estado.
func Calculate(nowUs, tatUs int64, rate, burst float64) State {
	interval := int64(math.Floor(1000000 / rate))
	if interval < 1 {
		interval = 1
	}
	tolerance := int64(burst) * interval

	tat := nowUs
	if tatUs > 0 {
		tat = tatUs
	}

	newTat := tat
	if nowUs > newTat {
		newTat = nowUs
	}
	newTat += interval
	allowAt := newTat - tolerance

	if nowUs >= allowAt {
		ttl := int64(math.Ceil(float64(newTat-nowUs)/1000000)) + 1
		remaining := (nowUs + tolerance - newTat) / interval
		if remaining < 0 {
			remaining = 0
		}
		return State{
			Decision:   Decision{Allowed: true, Remaining: remaining},
			NewTAT:     newTat,
			TTLSeconds: ttl,
		}
	}

	retry := int64(math.Ceil(float64(allowAt-nowUs) / 1000000))
	if retry < 1 {
		retry = 1
	}
	return State{
		Decision:   Decision{Allowed: false, Remaining: 0, RetryAfter: retry},
		NewTAT:     tat,
		TTLSeconds: 0,
	}
}
