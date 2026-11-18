package configkv

import (
	"encoding/json"
	"strings"
)

// Rejection describe una clave rechazada y el motivo. Los motivos son parte
// del contrato C10 y deben coincidir con el oracle de
// infra/compose/consul/testdata/manifest.json: malformed_json, type, range,
// unknown_key y coherence.
type Rejection struct {
	Key    string
	Reason string
}

// entryCount cuenta entradas no vacías de una lista separada por comas.
func entryCount(raw string) int {
	n := 0
	for _, entry := range strings.Split(raw, ",") {
		if strings.TrimSpace(entry) != "" {
			n++
		}
	}
	return n
}

// routePath extrae el path de una entrada "[METHOD ]path=rate:burst".
func routePath(entry string) string {
	left, _, ok := strings.Cut(strings.TrimSpace(entry), "=")
	if !ok {
		left = entry
	}
	fields := strings.Fields(left)
	switch len(fields) {
	case 1:
		return fields[0]
	case 2:
		return fields[1]
	}
	return ""
}

// coherence rechaza sensitive_routes cuando una exención la deja sin efecto:
// una ruta exenta que cubre el path de una ruta sensible hace que el límite
// específico nunca se aplique.
func coherence(accepted map[string]string) (map[string]string, []Rejection) {
	sr, hasRoutes := accepted["sensitive_routes"]
	ep, hasExempt := accepted["exempt_paths"]
	if !hasRoutes || !hasExempt {
		return accepted, nil
	}
	for _, exempt := range strings.Split(ep, ",") {
		exempt = strings.TrimRight(strings.TrimSpace(exempt), "/")
		if exempt == "" {
			continue
		}
		for _, route := range strings.Split(sr, ",") {
			p := routePath(route)
			if p == "" {
				continue
			}
			if p == exempt || strings.HasPrefix(p, exempt+"/") {
				out := make(map[string]string, len(accepted))
				for k, v := range accepted {
					if k == "sensitive_routes" {
						continue
					}
					out[k] = v
				}
				return out, []Rejection{{Key: "sensitive_routes", Reason: "coherence"}}
			}
		}
	}
	return accepted, nil
}

// validateEntry valida una clave ya tipada como string.
func validateEntry(key, value string) Rejection {
	f, ok := RateLimiterSchema[key]
	if !ok {
		return Rejection{Key: key, Reason: "unknown_key"}
	}
	if f.Type == "list" {
		n := entryCount(value)
		if float64(n) < f.Min || float64(n) > f.Max {
			return Rejection{Key: key, Reason: "range"}
		}
	}
	return Rejection{}
}

// ValidateRaw valida el mapa tal como llega desde Consul KV (valores crudos).
func ValidateRaw(values map[string]string) (map[string]string, []Rejection) {
	accepted := map[string]string{}
	var rejections []Rejection
	for k, v := range values {
		if strings.HasPrefix(k, "_") {
			continue
		}
		if r := validateEntry(k, v); r.Reason != "" {
			rejections = append(rejections, r)
			continue
		}
		accepted[k] = v
	}
	accepted, crej := coherence(accepted)
	return accepted, append(rejections, crej...)
}

// DecodeFixture decodifica un fixture JSON del oracle C10. Un JSON inválido
// produce el rechazo malformed_json sin clave asociada.
func DecodeFixture(raw []byte) (map[string]any, []Rejection) {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, []Rejection{{Reason: "malformed_json"}}
	}
	return m, nil
}

// ValidateJSON valida un fixture JSON aplicando la misma semántica que
// ValidateRaw, incluida la comprobación de tipo que el KV crudo no puede
// expresar.
func ValidateJSON(values map[string]any) (map[string]string, []Rejection) {
	accepted := map[string]string{}
	var rejections []Rejection
	for k, v := range values {
		if strings.HasPrefix(k, "_") {
			continue
		}
		s, ok := v.(string)
		if !ok {
			rejections = append(rejections, Rejection{Key: k, Reason: "type"})
			continue
		}
		if r := validateEntry(k, s); r.Reason != "" {
			rejections = append(rejections, r)
			continue
		}
		accepted[k] = s
	}
	accepted, crej := coherence(accepted)
	return accepted, append(rejections, crej...)
}
