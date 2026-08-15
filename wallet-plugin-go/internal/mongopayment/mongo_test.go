package mongopayment

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

func TestMongoRepositoryRuntime(t *testing.T) {
	uri := os.Getenv("MONGO_PAYMENT_URI")
	if uri == "" {
		t.Skip("MONGO_PAYMENT_URI is required for the authenticated replica-set integration")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client, err := mongo.Connect(options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Disconnect(context.Background()) }()

	db := client.Database("payments")
	events := db.Collection("payment_events")
	credits := db.Collection("payment_credits")
	if os.Getenv("MONGO_PAYMENT_REUSE") == "" {
		if err := events.Drop(ctx); err != nil && !errors.Is(err, mongo.ErrNilDocument) {
			t.Fatal(err)
		}
		if err := credits.Drop(ctx); err != nil && !errors.Is(err, mongo.ErrNilDocument) {
			t.Fatal(err)
		}
	}
	repo := NewMongo(events)
	if err := repo.EnsureIndexes(ctx); err != nil {
		t.Fatal(err)
	}

	payment := Payment{TenantID: "tenant-a", DeviceID: "device-a", IdempotencyKey: "payment-a", Canonical: "v1:100:XAF:2026-08-16T00:00:00Z"}
	if got, err := repo.Store(ctx, payment); err != nil || got.Canonical != payment.Canonical {
		t.Fatalf("committed payment: %#v %v", got, err)
	}
	if got, err := repo.Store(ctx, payment); err != nil || got != (Result{TenantID: payment.TenantID, DeviceID: payment.DeviceID, IdempotencyKey: payment.IdempotencyKey, Canonical: payment.Canonical}) {
		t.Fatalf("exact replay: %#v %v", got, err)
	}
	if _, err := repo.Store(ctx, Payment{TenantID: payment.TenantID, DeviceID: payment.DeviceID, IdempotencyKey: payment.IdempotencyKey, Canonical: "v1:101:XAF:2026-08-16T00:00:00Z"}); !errors.Is(err, ErrConflict) {
		t.Fatalf("conflicting replay error = %v, want ErrConflict", err)
	}
	if count, err := events.CountDocuments(ctx, bson.D{{Key: "tenant_id", Value: payment.TenantID}}); err != nil || count != 1 {
		t.Fatalf("durable event count = %d, %v; want one", count, err)
	}

	session, err := client.StartSession()
	if err != nil {
		t.Fatal(err)
	}
	defer session.EndSession(ctx)
	_, err = session.WithTransaction(ctx, func(tx context.Context) (any, error) {
		if _, err := events.InsertOne(tx, bson.D{{Key: "tenant_id", Value: "tenant-a"}, {Key: "device_id", Value: "device-a"}, {Key: "idempotency_key", Value: "abort-payment"}, {Key: "canonical", Value: "abort"}}); err != nil {
			return nil, err
		}
		if _, err := credits.InsertOne(tx, bson.D{{Key: "tenant_id", Value: "tenant-a"}, {Key: "payment_key", Value: "abort-payment"}, {Key: "credit", Value: "100"}}); err != nil {
			return nil, err
		}
		return nil, errors.New("forced abort")
	})
	if err == nil {
		t.Fatal("forced transaction abort unexpectedly committed")
	}
	for name, assertion := range map[string]bson.D{
		"events":  {{Key: "idempotency_key", Value: "abort-payment"}},
		"credits": {{Key: "payment_key", Value: "abort-payment"}},
	} {
		collection := events
		if name == "credits" {
			collection = credits
		}
		if count, err := collection.CountDocuments(ctx, assertion); err != nil || count != 0 {
			t.Fatalf("aborted %s count = %d, %v; want zero", name, count, err)
		}
	}
}
