package mongosync

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"

	"github.com/example/wallet-plugin-go/internal/analytics"
)

func TestMongoSyncRuntime(t *testing.T) {
	uri := os.Getenv("MONGO_SYNC_URI")
	if uri == "" {
		t.Skip("MONGO_SYNC_URI is required for authenticated replica-set integration")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client, err := mongo.Connect(options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect(context.Background())
	db := client.Database("sync")
	events, acknowledgements := db.Collection("events"), db.Collection("acknowledgements")
	if os.Getenv("MONGO_SYNC_REUSE") == "" {
		if err := events.Drop(ctx); err != nil {
			t.Fatal(err)
		}
		if err := acknowledgements.Drop(ctx); err != nil {
			t.Fatal(err)
		}
	}
	store := New(events, acknowledgements)
	if err := store.EnsureIndexes(ctx); err != nil {
		t.Fatal(err)
	}
	first, second := syncEvent(t, "018f0000-0000-7000-8000-000000000001", "4000"), syncEvent(t, "018f0000-0000-7000-8000-000000000002", "5000")
	if os.Getenv("MONGO_SYNC_REUSE") != "" {
		if err := store.Acknowledge(ctx, first.TenantID, "device-a", 2); err != nil {
			t.Fatalf("restart durable acknowledgement: %v", err)
		}
		return
	}
	if err := store.Append(ctx, first); err != nil {
		t.Fatal(err)
	}
	if err := store.Append(ctx, first); err != nil {
		t.Fatalf("exact replay: %v", err)
	}
	changed := syncEvent(t, first.ID, "6000")
	if err := store.Append(ctx, changed); !errors.Is(err, analytics.ErrEventConflict) {
		t.Fatalf("changed replay: %v", err)
	}
	if count, err := events.CountDocuments(ctx, bson.D{{Key: "event_id", Value: first.ID}}); err != nil || count != 1 {
		t.Fatalf("conflict mutated event: %d %v", count, err)
	}
	if err := store.Append(ctx, second); err != nil {
		t.Fatal(err)
	}
	if err := store.Acknowledge(ctx, first.TenantID, "device-a", 2); !errors.Is(err, analytics.ErrEventConflict) {
		t.Fatalf("gap ack: %v", err)
	}
	if err := store.Acknowledge(ctx, first.TenantID, "device-a", 1); err != nil {
		t.Fatal(err)
	}
	if err := store.Acknowledge(ctx, first.TenantID, "device-a", 1); err != nil {
		t.Fatalf("ack replay: %v", err)
	}
	if err := store.Acknowledge(ctx, first.TenantID, "device-a", 2); err != nil {
		t.Fatal(err)
	}
	if err := store.Acknowledge(ctx, first.TenantID, "device-b", 2); !errors.Is(err, analytics.ErrEventConflict) {
		t.Fatalf("replica isolation: %v", err)
	}
	if err := store.Acknowledge(ctx, "tenant-other", "device-a", 1); !errors.Is(err, analytics.ErrEventConflict) {
		t.Fatalf("tenant isolation: %v", err)
	}
}

func syncEvent(t *testing.T, id, amount string) analytics.LedgerEvent {
	t.Helper()
	input := analytics.EventInput{ID: id, TenantID: "tenant-demo", Kind: analytics.KindCapture, Amount: amount, Currency: "CDF", Provider: "orange-money", PaymentID: "payment-demo", OccurredAt: time.Date(2026, time.November, 1, 12, 0, 0, 0, time.UTC), ReceivedAt: time.Date(2026, time.November, 1, 12, 0, 1, 0, time.UTC)}
	digest, err := analytics.CanonicalEventDigest(input)
	if err != nil {
		t.Fatal(err)
	}
	input.Digest = digest
	event, err := analytics.NewLedgerEvent(input)
	if err != nil {
		t.Fatal(err)
	}
	return event
}
