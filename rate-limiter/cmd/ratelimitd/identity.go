package main

import (
	"net"
	"net/http"
	"path"
	"strings"
)

const (
	maxScopeLen  = 64
	unknownID    = "unknown"
	defaultScope = "default"
)

// exemptPrefixes son las rutas internas que no consumen cuota.
var exemptPrefixes = []string{"/internal", "/healthz", "/metrics"}

// resolveScope obtiene el scope desde `scope` (preferido) o el legado `key`.
// Devuelve false cuando ninguno está presente.
func resolveScope(r *http.Request) (string, bool) {
	q := r.URL.Query()
	raw := q.Get("scope")
	if raw == "" {
		raw = q.Get("key")
	}
	if raw == "" {
		return "", false
	}
	return sanitizeScope(raw), true
}

// sanitizeScope limita a maxScopeLen caracteres y conserva sólo [A-Za-z0-9_-];
// el resto se reemplaza por `_`. Si queda vacío, usa el scope por defecto.
func sanitizeScope(raw string) string {
	var b strings.Builder
	n := 0
	for _, c := range raw {
		if n >= maxScopeLen {
			break
		}
		if validScopeRune(c) {
			b.WriteRune(c)
		} else {
			b.WriteByte('_')
		}
		n++
	}
	out := b.String()
	if out == "" {
		return defaultScope
	}
	return out
}

func validScopeRune(c rune) bool {
	switch {
	case c >= 'a' && c <= 'z':
		return true
	case c >= 'A' && c <= 'Z':
		return true
	case c >= '0' && c <= '9':
		return true
	case c == '_' || c == '-':
		return true
	default:
		return false
	}
}

// clientIdentity deriva la IP del llamante. En X-Forwarded-For recorre de
// derecha a izquierda (Traefik normaliza el header) y usa la primera IP válida;
// nunca confía en el valor izquierdo más externo. Sin XFF usa RemoteAddr.
func clientIdentity(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		for i := len(parts) - 1; i >= 0; i-- {
			if ip := net.ParseIP(strings.TrimSpace(parts[i])); ip != nil {
				return ip.String()
			}
		}
	}
	if ip := remoteIP(r.RemoteAddr); ip != nil {
		return ip.String()
	}
	return unknownID
}

// remoteIP acepta `host:port` y también IPv4/IPv6 sin puerto.
func remoteIP(addr string) net.IP {
	if addr == "" {
		return nil
	}
	if host, _, err := net.SplitHostPort(addr); err == nil {
		return net.ParseIP(host)
	}
	return net.ParseIP(addr)
}

// rateLimitKey arma la clave Redis exacta `rl:{scope}:{identity}`.
func rateLimitKey(scope, identity string) string {
	return "rl:" + scope + ":" + identity
}

// exemptPath indica si X-Forwarded-Uri apunta a una ruta interna. Sin el
// header no hay exención.
func exemptPath(r *http.Request) bool {
	uri := r.Header.Get("X-Forwarded-Uri")
	if uri == "" {
		return false
	}
	if i := strings.IndexAny(uri, "?#"); i >= 0 {
		uri = uri[:i]
	}
	if uri == "" {
		return false
	}
	if !strings.HasPrefix(uri, "/") {
		uri = "/" + uri
	}
	uri = path.Clean(uri)
	for _, prefix := range exemptPrefixes {
		if uri == prefix || strings.HasPrefix(uri, prefix+"/") {
			return true
		}
	}
	return false
}
