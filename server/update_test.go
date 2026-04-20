package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTemp(t *testing.T, name, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(body), 0644); err != nil {
		t.Fatalf("write: %v", err)
	}
	return p
}

func TestLoadManifest_Valid(t *testing.T) {
	path := writeTemp(t, "update.json", `{
        "version":        "00024",
        "macos_url":      "https://example.com/mac.zip",
        "macos_sha256":   "0101010101010101010101010101010101010101010101010101010101010101",
        "windows_url":    "https://example.com/win.zip",
        "windows_sha256": "0202020202020202020202020202020202020202020202020202020202020202"
    }`)
	m, err := LoadManifest(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if m.Version != "00024" {
		t.Errorf("version: %q", m.Version)
	}
	if m.MacOSSHA256[0] != 0x01 || m.MacOSSHA256[31] != 0x01 {
		t.Errorf("macos sha not decoded from hex")
	}
	if m.WindowsSHA256[0] != 0x02 {
		t.Errorf("windows sha not decoded from hex")
	}
}

func TestLoadManifest_Missing(t *testing.T) {
	_, err := LoadManifest("/nonexistent/update.json")
	if err == nil {
		t.Fatal("expected error on missing file")
	}
}

func TestLoadManifest_Malformed(t *testing.T) {
	path := writeTemp(t, "update.json", `not json`)
	_, err := LoadManifest(path)
	if err == nil {
		t.Fatal("expected error on malformed json")
	}
}

func TestLoadManifest_BadSHALength(t *testing.T) {
	path := writeTemp(t, "update.json", `{
        "version":"00024",
        "macos_url":"x","macos_sha256":"aa",
        "windows_url":"y","windows_sha256":"bb"
    }`)
	_, err := LoadManifest(path)
	if err == nil {
		t.Fatal("expected error on short sha")
	}
}
