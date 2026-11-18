package configkv

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixturesDir devuelve el directorio con los fixtures de C10 vendorizados en
// el paquete. El CI clona solo este repositorio, por lo que el test no puede
// depender de un checkout hermano de infra/.
func fixturesDir(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, "testdata")
}

// sharedOracleDir busca el oracle compartido de C10 en un checkout hermano de
// infra/. Devuelve "" cuando no existe, como ocurre en CI.
func sharedOracleDir(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		candidate := filepath.Join(dir, "infra", "compose", "consul", "testdata")
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

type manifest struct {
	Fixtures []struct {
		File    string  `json:"file"`
		Verdict string  `json:"verdict"`
		Key     *string `json:"key"`
		Reason  *string `json:"reason"`
	} `json:"fixtures"`
}

// TestFixtureParity es el oracle de paridad de C10: cada fixture
// rate-limiter.*.json vendorizado debe producir exactamente el veredicto del
// manifest.
func TestFixtureParity(t *testing.T) {
	td := fixturesDir(t)

	raw, err := os.ReadFile(filepath.Join(td, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var man manifest
	if err := json.Unmarshal(raw, &man); err != nil {
		t.Fatal(err)
	}

	seen := 0
	for _, f := range man.Fixtures {
		if !strings.HasPrefix(f.File, "rate-limiter.") {
			continue
		}
		seen++
		t.Run(f.File, func(t *testing.T) {
			body, err := os.ReadFile(filepath.Join(td, f.File))
			if err != nil {
				t.Fatal(err)
			}
			values, rejections := DecodeFixture(body)
			if values != nil {
				accepted, rej := ValidateJSON(values)
				rejections = rej
				if f.Verdict == "accepted" && len(accepted) != 2 {
					t.Fatalf("accepted = %v, want both keys", accepted)
				}
			}

			if f.Verdict == "accepted" {
				if len(rejections) != 0 {
					t.Fatalf("rejections = %v, want none", rejections)
				}
				return
			}
			if len(rejections) != 1 {
				t.Fatalf("rejections = %v, want exactly 1", rejections)
			}
			got := rejections[0]
			if f.Key != nil && got.Key != *f.Key {
				t.Fatalf("key = %q, want %q", got.Key, *f.Key)
			}
			if f.Reason != nil && got.Reason != *f.Reason {
				t.Fatalf("reason = %q, want %q", got.Reason, *f.Reason)
			}
		})
	}
	if seen != 6 {
		t.Fatalf("fixtures rate-limiter encontrados = %d, want 6", seen)
	}
}

// TestVendoredFixturesMatchSharedOracle detecta deriva entre la copia
// vendorizada y el oracle de infra/ cuando ambos repositorios estan presentes
// en el workspace. En CI el oracle no existe y la copia vendorizada es la
// referencia.
func TestVendoredFixturesMatchSharedOracle(t *testing.T) {
	oracle := sharedOracleDir(t)
	if oracle == "" {
		t.Log("oracle compartido infra/compose/consul/testdata ausente: se usan los fixtures vendorizados")
		return
	}

	raw, err := os.ReadFile(filepath.Join(oracle, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var man manifest
	if err := json.Unmarshal(raw, &man); err != nil {
		t.Fatal(err)
	}
	names := []string{"manifest.json"}
	for _, f := range man.Fixtures {
		if strings.HasPrefix(f.File, "rate-limiter.") {
			names = append(names, f.File)
		}
	}

	local := fixturesDir(t)
	for _, name := range names {
		got, err := os.ReadFile(filepath.Join(local, name))
		if err != nil {
			t.Fatalf("%s falta en la copia vendorizada: %v", name, err)
		}
		want, err := os.ReadFile(filepath.Join(oracle, name))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("%s difiere del oracle compartido %s; actualizar la copia vendorizada", name, oracle)
		}
	}
}

func TestValidateRawAcceptsDefaults(t *testing.T) {
	accepted, rejections := ValidateRaw(map[string]string{
		"sensitive_routes": "POST /api/v2/documents=5:10",
		"exempt_paths":     "/internal,/healthz,/metrics",
	})
	if len(rejections) != 0 {
		t.Fatalf("rejections = %v, want none", rejections)
	}
	if len(accepted) != 2 {
		t.Fatalf("accepted = %v, want 2 keys", accepted)
	}
}

func TestValidateRawRejectsByKey(t *testing.T) {
	cases := []struct {
		name   string
		values map[string]string
		key    string
		reason string
	}{
		{
			name:   "entry count above maximum",
			values: map[string]string{"exempt_paths": strings.TrimSuffix(strings.Repeat("/p,", 60), ",")},
			key:    "exempt_paths",
			reason: "range",
		},
		{
			name:   "empty list is below minimum",
			values: map[string]string{"exempt_paths": " , "},
			key:    "exempt_paths",
			reason: "range",
		},
		{
			name:   "unknown key",
			values: map[string]string{"shadow_paths": "/admin"},
			key:    "shadow_paths",
			reason: "unknown_key",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, rejections := ValidateRaw(tc.values)
			if len(rejections) != 1 {
				t.Fatalf("rejections = %v, want 1", rejections)
			}
			if rejections[0].Key != tc.key || rejections[0].Reason != tc.reason {
				t.Fatalf("got %+v, want key=%s reason=%s", rejections[0], tc.key, tc.reason)
			}
		})
	}
}

func TestValidateRawRejectsCoherence(t *testing.T) {
	_, rejections := ValidateRaw(map[string]string{
		"sensitive_routes": "POST /api/v2/documents=5:10",
		"exempt_paths":     "/internal,/api/v2",
	})
	if len(rejections) != 1 || rejections[0].Key != "sensitive_routes" || rejections[0].Reason != "coherence" {
		t.Fatalf("rejections = %+v, want sensitive_routes/coherence", rejections)
	}
}

func TestValidateJSONRejectsWrongType(t *testing.T) {
	_, rejections := ValidateJSON(map[string]any{
		"sensitive_routes": "POST /api/v2/documents=5:10",
		"exempt_paths":     123,
	})
	if len(rejections) != 1 || rejections[0].Key != "exempt_paths" || rejections[0].Reason != "type" {
		t.Fatalf("rejections = %+v, want exempt_paths/type", rejections)
	}
}
