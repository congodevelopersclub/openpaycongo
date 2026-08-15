package main

import (
	"encoding/json"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/example/wallet-plugin-go/internal/runtimeconfig"
)

type readinessResponse struct {
	Datastore         string `json:"datastore"`
	MigrationRevision string `json:"migration_revision"`
	Topology          string `json:"topology"`
	Projection        string `json:"projection"`
	WriteAdmission    bool   `json:"write_admission"`
}

type versionResponse struct {
	Implementation    string `json:"implementation"`
	Adapter           string `json:"adapter"`
	BuildVersion      string `json:"build_version"`
	ContractVersion   string `json:"contract_version"`
	MigrationRevision string `json:"migration_revision"`
}

type operationalState struct{ MigrationRevision string }

func registerOperationalRoutes(router chi.Router, config runtimeconfig.Config, state operationalState) {
	router.Get("/healthz", func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Cache-Control", "no-store")
		writer.WriteHeader(http.StatusOK)
	})
	router.Get("/readyz", func(writer http.ResponseWriter, _ *http.Request) {
		writeOperationalJSON(writer, http.StatusServiceUnavailable, readinessResponse{
			Datastore:         "sqlite",
			MigrationRevision: state.MigrationRevision,
			Topology:          "sqlite",
			Projection:        "unimplemented",
			WriteAdmission:    false,
		})
	})
	router.Get("/version", func(writer http.ResponseWriter, _ *http.Request) {
		writeOperationalJSON(writer, http.StatusOK, versionResponse{
			Implementation:    "go",
			Adapter:           "sqlite",
			BuildVersion:      config.BuildVersion,
			ContractVersion:   config.ContractVersion,
			MigrationRevision: state.MigrationRevision,
		})
	})
}

func writeOperationalJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}
