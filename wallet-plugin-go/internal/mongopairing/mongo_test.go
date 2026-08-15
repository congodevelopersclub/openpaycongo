package mongopairing

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

func TestMongoIdentityRuntime(t *testing.T) {
	uri := os.Getenv("MONGO_PAIRING_URI")
	if uri == "" {
		t.Skip("MONGO_PAIRING_URI is required for authenticated replica-set integration")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client, err := mongo.Connect(options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Disconnect(context.Background())
	collection := client.Database("pairing").Collection("identities")
	reuse := os.Getenv("MONGO_PAIRING_REUSE") != ""
	if !reuse {
		if err := collection.Drop(ctx); err != nil {
			t.Fatal(err)
		}
	}
	repo := New(collection)
	if err := repo.EnsureIndexes(ctx); err != nil {
		t.Fatal(err)
	}
	identity := Identity{TenantID: "tenant-a", InstallID: "install-a", DeviceID: "device-a", IntentID: "intent-a", Status: "pending_confirmation"}
	if reuse {
		var stored Identity
		if err := collection.FindOne(ctx, bson.D{{Key: "tenant_id", Value: identity.TenantID}, {Key: "device_id", Value: identity.DeviceID}}).Decode(&stored); err != nil || stored.InstallID != identity.InstallID || stored.IntentID != identity.IntentID || stored.Status != "active" {
			t.Fatalf("restart durability: %#v %v", stored, err)
		}
		return
	}
	if got, err := repo.Store(ctx, identity); err != nil || got != identity {
		t.Fatalf("first insert: %#v %v", got, err)
	}
	if got, err := repo.Store(ctx, identity); err != nil || got != identity {
		t.Fatalf("exact replay: %#v %v", got, err)
	}
	if _, err := repo.Store(ctx, Identity{TenantID: identity.TenantID, InstallID: identity.InstallID, DeviceID: "device-b", IntentID: "intent-b", Status: identity.Status}); !errors.Is(err, ErrConflict) {
		t.Fatalf("changed replay = %v", err)
	}
	if count, err := collection.CountDocuments(ctx, bson.D{{Key: "tenant_id", Value: "tenant-a"}}); err != nil || count != 1 {
		t.Fatalf("conflict mutated store: %d %v", count, err)
	}
	if err := repo.RotateStatus(ctx, identity.TenantID, identity.DeviceID, "pending_confirmation", "active"); err != nil {
		t.Fatalf("active rotation: %v", err)
	}
	if err := repo.RotateStatus(ctx, identity.TenantID, identity.DeviceID, "pending_confirmation", "revoked"); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale rotation = %v", err)
	}
	var stored Identity
	if err := collection.FindOne(ctx, bson.D{{Key: "tenant_id", Value: identity.TenantID}, {Key: "device_id", Value: identity.DeviceID}}).Decode(&stored); err != nil || stored.Status != "active" || stored.InstallID != identity.InstallID || stored.IntentID != identity.IntentID {
		t.Fatalf("immutable active identity: %#v %v", stored, err)
	}
}
