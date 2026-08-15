package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/go-chi/chi/v5"
	_ "github.com/mattn/go-sqlite3"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"

	"github.com/example/wallet-plugin-go/internal/runtimeconfig"
	"github.com/example/wallet-plugin-go/internal/wallet"
)

func initTracer(ctx context.Context) (*sdktrace.TracerProvider, error) {
	exp, err := stdouttrace.New(stdouttrace.WithWriter(os.Stdout))
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName("wallet-server"),
		)),
	)
	otel.SetTracerProvider(tp)
	return tp, nil
}

func main() {
	ctx := context.Background()
	config, err := runtimeconfig.Load(operatingSystemEnvironment{})
	if err != nil {
		log.Fatal(err)
	}
	tp, err := initTracer(ctx)
	if err != nil {
		log.Fatal(err)
	}
	defer func() { _ = tp.Shutdown(ctx) }()

	store, err := wallet.NewStore(config.SQLitePath)
	if err != nil {
		log.Fatal(err)
	}

	r := chi.NewRouter()
	r.Post("/api/credits", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Phone     string    `json:"phone"`
			Amount    int64     `json:"amount"`
			Timestamp time.Time `json:"timestamp"`
			RawSMS    string    `json:"raw_sms"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		id, err := store.AddCredit(wallet.Transaction{
			Phone:     body.Phone,
			Amount:    body.Amount,
			RawSMS:    body.RawSMS,
			Timestamp: body.Timestamp,
		})
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"id": id})
	})

	r.Post("/wallet/{phone}/debit", func(w http.ResponseWriter, r *http.Request) {
		phone := chi.URLParam(r, "phone")
		var body struct {
			Amount int64  `json:"amount"`
			Ref    string `json:"ref"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		id, err := store.AddDebit(phone, body.Amount, body.Ref)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"id": id})
	})

	r.Get("/parsers", func(w http.ResponseWriter, r *http.Request) {
		ps, err := store.Parsers()
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		json.NewEncoder(w).Encode(ps)
	})

	r.Post("/parsers", func(w http.ResponseWriter, r *http.Request) {
		var p wallet.Parser
		if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		id, err := store.AddParser(p)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"id": id})
	})
	r.Get("/wallet/{phone}", func(w http.ResponseWriter, r *http.Request) {
		phone := chi.URLParam(r, "phone")
		bal, err := store.Balance(phone)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"balance": bal})
	})
	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := otelhttp.NewHandler(r, "chi-server")
	log.Printf("listening on %s", config.ListenAddress)
	if err := http.ListenAndServe(config.ListenAddress, handler); err != nil {
		log.Fatal(err)
	}
}

type operatingSystemEnvironment struct{}

func (operatingSystemEnvironment) LookupEnv(key string) (string, bool) {
	return os.LookupEnv(key)
}
