package configkv

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCacheRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nested", "config-cache.json")
	c := NewCache(path)

	values := map[string]string{
		"sensitive_routes": "POST /api/v2/documents=5:10",
		"exempt_paths":     "/healthz",
	}
	if err := c.Save(values); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("mode = %o, want 600", perm)
	}

	loaded, err := c.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded) != len(values) || loaded["exempt_paths"] != "/healthz" {
		t.Fatalf("loaded = %v", loaded)
	}
}

func TestCacheMissingIsReportedAsError(t *testing.T) {
	c := NewCache(filepath.Join(t.TempDir(), "absent.json"))
	if _, err := c.Load(); err == nil {
		t.Fatal("expected error for missing cache")
	}
}

func TestCacheCorruptIsReportedAsError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config-cache.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewCache(path).Load(); err == nil {
		t.Fatal("expected error for corrupt cache")
	}
}

func TestCacheDefaultsPathFromEnv(t *testing.T) {
	t.Setenv("CONFIG_CACHE_PATH", "/tmp/ratelimitd-test/cache.json")
	if got := NewCache("").Path; got != "/tmp/ratelimitd-test/cache.json" {
		t.Fatalf("path = %q", got)
	}
	t.Setenv("CONFIG_CACHE_PATH", "")
	if got := NewCache("").Path; got != DefaultCachePath {
		t.Fatalf("path = %q, want %q", got, DefaultCachePath)
	}
}
