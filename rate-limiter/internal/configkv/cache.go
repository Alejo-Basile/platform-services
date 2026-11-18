package configkv

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Cache guarda el último conjunto efectivo de valores aplicados. Vive en un
// volumen nombrado porque el proceso corre con rootfs de solo lectura.
type Cache struct {
	Path string
}

// NewCache construye la caché en la ruta indicada. Ruta vacía usa el default.
func NewCache(path string) *Cache {
	if path == "" {
		path = envOr("CONFIG_CACHE_PATH", DefaultCachePath)
	}
	return &Cache{Path: path}
}

// Load devuelve la caché. Ausente o corrupta se trata como inexistente por el
// llamante (nunca aborta el arranque); corrupta se reporta como error.
func (c *Cache) Load() (map[string]string, error) {
	data, err := os.ReadFile(c.Path)
	if err != nil {
		return nil, err
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("cache corrupta: %w", err)
	}
	return m, nil
}

// Save escribe de forma atómica (tmp + fsync + rename) con modo 0600.
func (c *Cache) Save(values map[string]string) error {
	dir := filepath.Dir(c.Path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp := c.Path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	payload, err := json.Marshal(values)
	if err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if _, err := f.Write(payload); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Chmod(tmp, 0o600); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, c.Path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
