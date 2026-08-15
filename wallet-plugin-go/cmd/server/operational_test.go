package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"

	"github.com/example/wallet-plugin-go/internal/runtimeconfig"
)

func TestOperationalEndpointsAreTruthfulForLegacyRuntime(t *testing.T) {
	t.Parallel()

	router := chi.NewRouter()
	registerOperationalRoutes(router, runtimeconfig.Config{BuildVersion: "build-123", ContractVersion: "sales-analytics-v1"}, operationalState{MigrationRevision: "0001"})

	health := httptest.NewRecorder()
	router.ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if health.Code != http.StatusOK || health.Header().Get("Cache-Control") != "no-store" || health.Body.Len() != 0 {
		t.Fatalf("health response = status %d, headers %#v, body %q", health.Code, health.Header(), health.Body.String())
	}

	ready := httptest.NewRecorder()
	router.ServeHTTP(ready, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if ready.Code != http.StatusServiceUnavailable || ready.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("ready response = status %d, headers %#v", ready.Code, ready.Header())
	}
	var readiness map[string]any
	if err := json.Unmarshal(ready.Body.Bytes(), &readiness); err != nil {
		t.Fatal(err)
	}
	wantReadiness := map[string]any{
		"datastore":          "sqlite",
		"migration_revision": "0001",
		"topology":           "sqlite",
		"projection":         "unimplemented",
		"write_admission":    false,
	}
	if !mapsEqual(readiness, wantReadiness) {
		t.Fatalf("readiness = %#v, want %#v", readiness, wantReadiness)
	}

	version := httptest.NewRecorder()
	router.ServeHTTP(version, httptest.NewRequest(http.MethodGet, "/version", nil))
	if version.Code != http.StatusOK || version.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("version response = status %d, headers %#v", version.Code, version.Header())
	}
	var identity map[string]any
	if err := json.Unmarshal(version.Body.Bytes(), &identity); err != nil {
		t.Fatal(err)
	}
	wantIdentity := map[string]any{
		"implementation":     "go",
		"adapter":            "sqlite",
		"build_version":      "build-123",
		"contract_version":   "sales-analytics-v1",
		"migration_revision": "0001",
	}
	if !mapsEqual(identity, wantIdentity) {
		t.Fatalf("version = %#v, want %#v", identity, wantIdentity)
	}
}

func mapsEqual(got, want map[string]any) bool {
	if len(got) != len(want) {
		return false
	}
	for key, value := range want {
		if got[key] != value {
			return false
		}
	}
	return true
}
