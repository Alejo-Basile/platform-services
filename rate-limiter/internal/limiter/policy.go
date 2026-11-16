package limiter

import (
	"crypto/subtle"
	"fmt"
	"path"
	"strconv"
	"strings"
)

// LimitSpec describe un límite GCRA (tasa sostenida y ráfaga).
type LimitSpec struct {
	Rate  float64
	Burst float64
}

// Limit es una clave de límite concreta a evaluar de forma atómica.
type Limit struct {
	Key   string
	Rate  float64
	Burst float64
}

// RouteLimit aplica un límite extra a un path exacto y, opcionalmente, a un
// método. Method vacío o "ANY" aplica a cualquier método.
type RouteLimit struct {
	Method string
	Path   string
	Limit  LimitSpec
}

// Policy es la configuración explícita de exenciones y rutas sensibles. El
// límite global llega por petición (rate/burst) y vive en el handler.
type Policy struct {
	SensitiveRoutes []RouteLimit
	ExemptPaths     []string
	WebhookPath     string
	WebhookToken    string
}

// Request es la petición original tal como la reenvía Traefik en ForwardAuth.
type Request struct {
	Method        string
	Path          string
	Authorization string
}

// Plan es la decisión previa a consultar Redis.
//
// Exempt indica que la petición no consume cuota. Routes contiene las rutas
// sensibles que coinciden y que el llamante debe convertir en límites extra
// (el límite global siempre se evalúa aparte).
type Plan struct {
	Exempt bool
	Routes []RouteLimit
}

// Decide aplica la precedencia de la política:
//
//  1. El path del webhook es terminal: con token válido queda exento; sin token
//     válido NO cae en la lista genérica de exenciones y se limita normalmente.
//     Así un cliente no puede eludir el límite suplantando una ruta interna.
//  2. Las rutas de la lista explícita de exenciones quedan exentas sin cuota.
//  3. Cualquier otra ruta devuelve las rutas sensibles que coincidan para que
//     el handler evalúe el límite global más los límites por ruta en un único
//     EVAL atómico.
//
// El matching se resuelve SIEMPRE contra la forma limpia del path. Un path no
// canónico (traversal, "//", "." / "..") nunca gana una exención: es una
// regresión de seguridad (bypass /internal/../api/...).
func (p Policy) Decide(req Request) Plan {
	normalized := normalizePath(req.Path)

	if isCanonicalPath(req.Path) {
		if p.WebhookPath != "" && pathHasPrefix(normalized, p.WebhookPath) {
			if p.validWebhookToken(req.Authorization) {
				return Plan{Exempt: true}
			}
		} else if p.isExempt(normalized) {
			return Plan{Exempt: true}
		}
	}

	routes := make([]RouteLimit, 0, len(p.SensitiveRoutes))
	for _, route := range p.SensitiveRoutes {
		if route.Path != normalized {
			continue
		}
		if route.Method != "" && !strings.EqualFold(route.Method, "ANY") && !strings.EqualFold(route.Method, req.Method) {
			continue
		}
		routes = append(routes, route)
	}
	return Plan{Routes: routes}
}

func (p Policy) isExempt(path string) bool {
	for _, entry := range p.ExemptPaths {
		if pathHasPrefix(path, entry) {
			return true
		}
	}
	return false
}

func (p Policy) validWebhookToken(authorization string) bool {
	if p.WebhookToken == "" {
		return false
	}
	const prefix = "Bearer "
	if !strings.HasPrefix(authorization, prefix) {
		return false
	}
	got := strings.TrimSpace(strings.TrimPrefix(authorization, prefix))
	return subtle.ConstantTimeCompare([]byte(got), []byte(p.WebhookToken)) == 1
}

// pathHasPrefix respeta límites de segmento: `/internal` cubre `/internal` y
// `/internal/x`, pero no `/internalx`. La lista de entradas es explícita.
func pathHasPrefix(path, entry string) bool {
	entry = strings.TrimRight(strings.TrimSpace(entry), "/")
	if entry == "" {
		return false
	}
	return path == entry || strings.HasPrefix(path, entry+"/")
}

// normalizePath devuelve la forma limpia del path: sin query/fragment, con
// barra inicial y con segmentos resueltos (path.Clean colapsa "//", "." y
// ".."), para que límites y exenciones se evalúen contra la ruta real que
// verá el servicio de destino.
func normalizePath(raw string) string {
	raw = strings.TrimSpace(raw)
	if i := strings.IndexAny(raw, "?#"); i >= 0 {
		raw = raw[:i]
	}
	if raw == "" {
		return "/"
	}
	if !strings.HasPrefix(raw, "/") {
		raw = "/" + raw
	}
	return path.Clean(raw)
}

// isCanonicalPath indica si el path llega en forma canónica: sin segmentos
// vacíos ("//") ni "." / "..". Un path no canónico es sospechoso y no gana
// exenciones aunque su forma limpia coincida con una ruta exenta.
func isCanonicalPath(raw string) bool {
	raw = strings.TrimSpace(raw)
	if i := strings.IndexAny(raw, "?#"); i >= 0 {
		raw = raw[:i]
	}
	if strings.Contains(raw, "//") {
		return false
	}
	for _, seg := range strings.Split(raw, "/") {
		if seg == "." || seg == ".." {
			return false
		}
	}
	return true
}

// ParseLimitSpec parsea "rate:burst".
func ParseLimitSpec(raw string) (LimitSpec, error) {
	parts := strings.Split(strings.TrimSpace(raw), ":")
	if len(parts) != 2 {
		return LimitSpec{}, fmt.Errorf("limite invalido %q: se esperaba rate:burst", raw)
	}
	rate, err := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
	if err != nil {
		return LimitSpec{}, fmt.Errorf("rate invalido %q: %w", parts[0], err)
	}
	burst, err := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64)
	if err != nil {
		return LimitSpec{}, fmt.Errorf("burst invalido %q: %w", parts[1], err)
	}
	spec := LimitSpec{Rate: rate, Burst: burst}
	if err := validateLimitSpec(spec); err != nil {
		return LimitSpec{}, err
	}
	return spec, nil
}

func validateLimitSpec(spec LimitSpec) error {
	if spec.Rate <= 0 {
		return fmt.Errorf("rate debe ser > 0")
	}
	if spec.Burst < 1 {
		return fmt.Errorf("burst debe ser >= 1")
	}
	return nil
}

// ParseSensitiveRoutes parsea "[METHOD ]path=rate:burst" separadas por comas.
func ParseSensitiveRoutes(raw string) ([]RouteLimit, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	entries := strings.Split(raw, ",")
	routes := make([]RouteLimit, 0, len(entries))
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		route, err := parseRouteLimit(entry)
		if err != nil {
			return nil, err
		}
		routes = append(routes, route)
	}
	return routes, nil
}

func parseRouteLimit(entry string) (RouteLimit, error) {
	left, rawLimit, ok := strings.Cut(entry, "=")
	if !ok {
		return RouteLimit{}, fmt.Errorf("ruta sensible invalida %q: falta =rate:burst", entry)
	}
	spec, err := ParseLimitSpec(rawLimit)
	if err != nil {
		return RouteLimit{}, err
	}
	fields := strings.Fields(strings.TrimSpace(left))
	var method, routePath string
	switch len(fields) {
	case 1:
		routePath = fields[0]
	case 2:
		method = strings.ToUpper(fields[0])
		routePath = fields[1]
	default:
		return RouteLimit{}, fmt.Errorf("ruta sensible invalida %q: se esperaba [METHOD] path=rate:burst", entry)
	}
	if !strings.HasPrefix(routePath, "/") {
		return RouteLimit{}, fmt.Errorf("ruta sensible invalida %q: el path debe empezar con /", entry)
	}
	return RouteLimit{Method: method, Path: routePath, Limit: spec}, nil
}

// ParseExemptPaths parsea la lista explícita de paths exentos.
func ParseExemptPaths(raw string) ([]string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	paths := make([]string, 0)
	for _, entry := range strings.Split(raw, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		if !strings.HasPrefix(entry, "/") {
			return nil, fmt.Errorf("exencion invalida %q: debe empezar con /", entry)
		}
		paths = append(paths, entry)
	}
	return paths, nil
}

// ParsePolicy valida y construye la política completa.
func ParsePolicy(routesRaw, exemptRaw, webhookPath, webhookToken string) (Policy, error) {
	routes, err := ParseSensitiveRoutes(routesRaw)
	if err != nil {
		return Policy{}, fmt.Errorf("rutas sensibles: %w", err)
	}
	exempt, err := ParseExemptPaths(exemptRaw)
	if err != nil {
		return Policy{}, fmt.Errorf("exenciones: %w", err)
	}
	webhookPath = strings.TrimSpace(webhookPath)
	if webhookPath != "" && !strings.HasPrefix(webhookPath, "/") {
		return Policy{}, fmt.Errorf("webhook: el path debe empezar con /")
	}
	return Policy{
		SensitiveRoutes: routes,
		ExemptPaths:     exempt,
		WebhookPath:     webhookPath,
		WebhookToken:    strings.TrimSpace(webhookToken),
	}, nil
}
