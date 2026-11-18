package configkv

type Field struct {
	Type     string
	Min, Max float64
	HasRange bool
	Default  any
	Reload   string
}

var RateLimiterSchema = map[string]Field{
	"sensitive_routes": {Type: "list", Min: 1, Max: 50, HasRange: true, Default: "POST /api/v2/documents=5:10", Reload: "hot"},
	"exempt_paths":     {Type: "list", Min: 1, Max: 50, HasRange: true, Default: "/internal,/healthz,/metrics", Reload: "hot"},
}

func Defaults() map[string]any {
	out := map[string]any{}
	for k, f := range RateLimiterSchema {
		out[k] = f.Default
	}
	return out
}
