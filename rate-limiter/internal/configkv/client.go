package configkv

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strings"
	"time"
)

// KVPrefix es el prefijo que este servicio puede leer (ACL de solo lectura).
const KVPrefix = "config/rate-limiter"

const defaultWait = 5 * time.Minute

// Client habla con Consul por HTTPS con CA propia y token por archivo.
type Client struct {
	Addr     string
	CACert   string
	Token    string
	Disabled bool
	HTTP     *http.Client
}

// NewClient construye el cliente desde el entorno. Nunca falla: sin CA o sin
// token degrada con un warning.
func NewClient() *Client {
	c := &Client{
		Addr:     strings.TrimRight(envOr("CONSUL_HTTP_ADDR", "https://consul-agent:8501"), "/"),
		CACert:   envOr("CONSUL_CACERT", "/etc/ssl/certs/consul-ca.pem"),
		Disabled: os.Getenv("CONSUL_KV_DISABLED") == "true",
		HTTP:     &http.Client{Timeout: 10 * time.Second},
	}

	if tf := envOr("CONSUL_TOKEN_FILE", "/run/secrets/consul_ratelimitd_token"); tf != "" {
		if data, err := os.ReadFile(tf); err == nil {
			c.Token = strings.TrimSpace(string(data))
		} else {
			log.Printf("configkv: token de Consul no disponible (%s): %v", tf, err)
		}
	}

	tlsCfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if data, err := os.ReadFile(c.CACert); err == nil {
		pool := x509.NewCertPool()
		if pool.AppendCertsFromPEM(data) {
			tlsCfg.RootCAs = pool
		} else {
			log.Printf("configkv: CA de Consul ilegible (%s): se usan raices del sistema", c.CACert)
		}
	} else {
		log.Printf("configkv: CONSUL_CACERT ausente (%s): se usan raices del sistema", c.CACert)
	}
	c.HTTP.Transport = &http.Transport{TLSClientConfig: tlsCfg}
	return c
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// Get ejecuta una lectura (posiblemente blocking query) del prefijo propio.
func (c *Client) Get(ctx context.Context, idx uint64, wait time.Duration) (map[string]string, uint64, int, error) {
	if c.Disabled {
		return nil, idx, http.StatusOK, nil
	}
	if wait <= 0 {
		wait = defaultWait
	}
	url := fmt.Sprintf("%s/v1/kv/%s?recurse&index=%d&wait=%s", c.Addr, KVPrefix, idx, wait.String())
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, idx, 0, err
	}
	if c.Token != "" {
		req.Header.Set("X-Consul-Token", c.Token)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, idx, 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotModified {
		return nil, idx, resp.StatusCode, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, idx, resp.StatusCode, fmt.Errorf("consul kv %s: status %d", KVPrefix, resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, idx, resp.StatusCode, err
	}
	var entries []struct {
		Key   string `json:"Key"`
		Value string `json:"Value"`
	}
	if err := json.Unmarshal(body, &entries); err != nil {
		return nil, idx, resp.StatusCode, err
	}
	out := map[string]string{}
	for _, e := range entries {
		key := strings.TrimPrefix(e.Key, KVPrefix+"/")
		if key == "" || key == KVPrefix {
			continue
		}
		dec, err := base64.StdEncoding.DecodeString(e.Value)
		if err != nil {
			continue
		}
		out[key] = string(dec)
	}
	newIdx := idx
	if v := resp.Header.Get("X-Consul-Index"); v != "" {
		fmt.Sscan(v, &newIdx)
	}
	return out, newIdx, resp.StatusCode, nil
}

// Watch mantiene el blocking query con backoff 1s→30s y jitter hasta cancelar.
func (c *Client) Watch(ctx context.Context, onChange func(map[string]string) error) {
	idx := uint64(0)
	backoff := time.Second
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		values, newIdx, status, err := c.Get(ctx, idx, defaultWait)
		if err != nil || status >= http.StatusInternalServerError {
			log.Printf("configkv: error de Consul: %v (status %d)", err, status)
			jitter := time.Duration(rand.Int63n(int64(backoff/4) + 1))
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff + jitter):
			}
			backoff *= 2
			if backoff > 30*time.Second {
				backoff = 30 * time.Second
			}
			continue
		}
		backoff = time.Second
		if status == http.StatusNotModified {
			continue
		}
		if idx != 0 && newIdx < idx {
			idx = 0
			continue
		}
		if idx != 0 && newIdx == idx {
			continue
		}
		idx = newIdx
		if values != nil {
			if err := onChange(values); err != nil {
				log.Printf("configkv: apply error: %v", err)
			}
		}
	}
}
