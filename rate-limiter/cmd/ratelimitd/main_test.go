package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRedisPassword(t *testing.T) {
	t.Run("environment takes precedence over file", func(t *testing.T) {
		passwordFile := filepath.Join(t.TempDir(), "password")
		if err := os.WriteFile(passwordFile, []byte("file-password\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		t.Setenv("REDIS_PASSWORD", "environment-password")
		t.Setenv("REDIS_PASSWORD_FILE", passwordFile)

		got, err := redisPasswordFromEnv()
		if err != nil {
			t.Fatal(err)
		}
		if got != "environment-password" {
			t.Fatalf("password = %q, want environment-password", got)
		}
	})

	t.Run("file fallback is trimmed", func(t *testing.T) {
		passwordFile := filepath.Join(t.TempDir(), "password")
		if err := os.WriteFile(passwordFile, []byte("  file-password\n\t"), 0o600); err != nil {
			t.Fatal(err)
		}
		t.Setenv("REDIS_PASSWORD", "")
		t.Setenv("REDIS_PASSWORD_FILE", passwordFile)

		got, err := redisPasswordFromEnv()
		if err != nil {
			t.Fatal(err)
		}
		if got != "file-password" {
			t.Fatalf("password = %q, want file-password", got)
		}
	})

	t.Run("missing or unreadable file returns an error", func(t *testing.T) {
		for _, path := range []string{filepath.Join(t.TempDir(), "missing"), t.TempDir()} {
			t.Setenv("REDIS_PASSWORD", "")
			t.Setenv("REDIS_PASSWORD_FILE", path)
			if _, err := redisPasswordFromEnv(); err == nil {
				t.Errorf("redisPasswordFromEnv() with %q returned no error", path)
			}
		}
	})

	t.Run("neither variable returns empty password", func(t *testing.T) {
		t.Setenv("REDIS_PASSWORD", "")
		t.Setenv("REDIS_PASSWORD_FILE", "")

		got, err := redisPasswordFromEnv()
		if err != nil {
			t.Fatal(err)
		}
		if got != "" {
			t.Fatalf("password = %q, want empty", got)
		}
	})
}
