// Package consulreg registra y desregistra cada réplica de ratelimitd en el
// agente local de Consul (S11-P1-C17).
package consulreg

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/Alejo-Basile/platform-services/rate-limiter/internal/configkv"
)

const (
	defaultAgentAddr  = "https://consul-agent:8501"
	defaultServiceName = "ratelimitd"
	healthPath        = "/healthz"

	checkInterval = "10s"
	checkTimeout  = "3s"
	checkDeregister = "1m"

	agentProbePort = "8501"

	retryInitialDelay = 5 * time.Second
	retryMaxDelay     = 60 * time.Second
	registerAttempt   = 5 * time.Second
)

type Config struct {
	ServiceName     string
	AgentAddr       string
	HTTPPort        int
	Disabled        bool
	AddressProbe    func(target string) (string, error)
	RetryInitial    time.Duration
	RetryMax        time.Duration
	OnRegisterFailure func()
}

type Registrar struct {
	cfg              Config
	client           *configkv.Client
	id               string
	OnRegisterFailure func()

	mu      sync.Mutex
	address string
}

func New(cfg Config, client *configkv.Client) *Registrar {
	if cfg.ServiceName == "" {
		cfg.ServiceName = defaultServiceName
	}
	if cfg.AgentAddr == "" {
		cfg.AgentAddr = defaultAgentAddr
	}
	if cfg.AddressProbe == nil {
		cfg.AddressProbe = deriveLocalAddress
	}
	if cfg.RetryInitial <= 0 {
		cfg.RetryInitial = retryInitialDelay
	}
	if cfg.RetryMax <= 0 {
		cfg.RetryMax = retryMaxDelay
	}
	return &Registrar{cfg: cfg, client: client, id: defaultServiceName + "-" + hostname(), OnRegisterFailure: cfg.OnRegisterFailure}
}

func NewFromEnv(httpPort int) *Registrar {
	agentAddr := os.Getenv("CONSUL_REGISTRATION_ADDR")
	if agentAddr == "" {
		agentAddr = defaultAgentAddr
	}
	serviceName := os.Getenv("SERVICE_NAME")
	if serviceName == "" {
		serviceName = defaultServiceName
	}
	client := configkv.NewClientWithAddr(agentAddr)
	return New(Config{
		ServiceName: serviceName,
		AgentAddr:   agentAddr,
		HTTPPort:    httpPort,
		Disabled:    os.Getenv("CONSUL_REGISTRATION_DISABLED") == "true",
	}, client)
}

func (r *Registrar) ID() string { return r.id }

func (r *Registrar) Enabled() bool { return !r.cfg.Disabled }

func (r *Registrar) Address() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.address == "" {
		addr, err := r.cfg.AddressProbe(r.cfg.AgentAddr)
		if err != nil || addr == "" {
			addr = hostname()
		}
		r.address = addr
	}
	return r.address
}

type registerPayload struct {
	ID      string   `json:"ID"`
	Name    string   `json:"Name"`
	Address string   `json:"Address"`
	Port    int      `json:"Port"`
	Tags    []string `json:"Tags"`
	Check   check    `json:"Check"`
}

type check struct {
	HTTP                           string `json:"HTTP"`
	Interval                       string `json:"Interval"`
	Timeout                        string `json:"Timeout"`
	DeregisterCriticalServiceAfter string `json:"DeregisterCriticalServiceAfter"`
}

func (r *Registrar) payload() registerPayload {
	addr := r.Address()
	return registerPayload{
		ID:      r.id,
		Name:    "svc-" + r.cfg.ServiceName,
		Address: addr,
		Port:    r.cfg.HTTPPort,
		Tags:    []string{"http", "s11", "ratelimitd", "metrics_path=/metrics"},
		Check: check{
			HTTP:                           fmt.Sprintf("http://%s:%d%s", addr, r.cfg.HTTPPort, healthPath),
			Interval:                       checkInterval,
			Timeout:                        checkTimeout,
			DeregisterCriticalServiceAfter: checkDeregister,
		},
	}
}

func (r *Registrar) Register(ctx context.Context) error {
	if !r.Enabled() {
		return nil
	}
	body, err := json.Marshal(r.payload())
	if err != nil {
		return fmt.Errorf("consul register: marshal payload: %w", err)
	}
	status, err := r.client.Put(ctx, "/v1/agent/service/register", body)
	if err != nil {
		if r.OnRegisterFailure != nil {
			r.OnRegisterFailure()
		}
		return fmt.Errorf("consul register: %w", err)
	}
	if status < 200 || status >= 300 {
		if r.OnRegisterFailure != nil {
			r.OnRegisterFailure()
		}
		return fmt.Errorf("consul register: status %d", status)
	}
	return nil
}

func (r *Registrar) RegisterWithRetry(ctx context.Context) {
	if !r.Enabled() {
		return
	}
	backoff := r.cfg.RetryInitial
	for {
		attemptCtx, cancel := context.WithTimeout(ctx, registerAttempt)
		err := r.Register(attemptCtx)
		cancel()
		if err == nil {
			slog.Info("registrado en Consul",
				"id", r.ID(), "address", r.Address(), "port", r.cfg.HTTPPort)
			return
		}
		slog.Warn("registro en Consul fallido, el servicio sigue operando y se reintentará",
			"id", r.ID(), "address", r.Address(), "error", err.Error(), "retry_in", backoff.String())
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < r.cfg.RetryMax {
			backoff *= 2
			if backoff > r.cfg.RetryMax {
				backoff = r.cfg.RetryMax
			}
		}
	}
}

func (r *Registrar) Deregister(ctx context.Context) error {
	if !r.Enabled() {
		return nil
	}
	status, err := r.client.Put(ctx, "/v1/agent/service/deregister/"+url.PathEscape(r.id), nil)
	if err != nil {
		return fmt.Errorf("consul deregister: %w", err)
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("consul deregister: status %d", status)
	}
	return nil
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "unknown"
	}
	return h
}

func deriveLocalAddress(target string) (string, error) {
	host := hostFromAddr(target)
	conn, err := net.Dial("udp", net.JoinHostPort(host, agentProbePort))
	if err == nil {
		defer conn.Close()
		if udpAddr, ok := conn.LocalAddr().(*net.UDPAddr); ok &&
			udpAddr.IP != nil && !udpAddr.IP.IsLoopback() {
			return udpAddr.IP.String(), nil
		}
	}
	return firstGlobalIPv4()
}

func hostFromAddr(raw string) string {
	if raw == "" {
		raw = defaultAgentAddr
	}
	if u, err := url.Parse(raw); err == nil && u.Hostname() != "" {
		return u.Hostname()
	}
	if i := strings.Index(raw, ":"); i >= 0 {
		return raw[:i]
	}
	return raw
}

func firstGlobalIPv4() (string, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return "", err
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipNet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipNet.IP
			if ip.To4() != nil && !ip.IsLoopback() && ip.IsGlobalUnicast() {
				return ip.String(), nil
			}
		}
	}
	return "", fmt.Errorf("consul register: ninguna IPv4 utilizable")
}
