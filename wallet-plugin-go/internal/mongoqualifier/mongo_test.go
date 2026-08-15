package mongoqualifier

import (
	"context"
	"os"
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

func TestReplicaSetRuntime(t *testing.T) {
	uri := os.Getenv("MONGO_QUALIFIER_URI")
	if uri == "" {
		t.Skip("set MONGO_QUALIFIER_URI for task-owned replica-set integration")
	}
	c, err := mongo.Connect(options.Client().ApplyURI(uri))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Disconnect(context.Background())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err = c.Ping(ctx, nil); err != nil {
		t.Fatal(err)
	}
	var hello struct {
		IsWritablePrimary bool   `bson:"isWritablePrimary"`
		SetName           string `bson:"setName"`
	}
	if err = c.Database("admin").RunCommand(ctx, bson.D{{Key: "hello", Value: 1}}).Decode(&hello); err != nil {
		t.Fatal(err)
	}
	if !hello.IsWritablePrimary || hello.SetName == "" {
		t.Fatalf("expected writable replica-set primary, got primary=%t set=%q", hello.IsWritablePrimary, hello.SetName)
	}
	if _, err = c.Database("qualifier").Collection("events").DeleteMany(ctx, bson.D{}); err != nil {
		t.Fatalf("clean task fixture: %v", err)
	}
	result, err := c.Database("qualifier").RunCommand(ctx, bson.D{{Key: "insert", Value: "events"}, {Key: "documents", Value: bson.A{bson.D{{Key: "tenant_id", Value: "tenant-a"}, {Key: "event_id", Value: "runtime-check"}}}}, {Key: "ordered", Value: true}, {Key: "writeConcern", Value: bson.D{{Key: "w", Value: "majority"}}}}).Raw()
	if err != nil || result.Lookup("ok").Double() != 1 {
		t.Fatalf("majority write failed: %v", err)
	}
	session, err := c.StartSession()
	if err != nil {
		t.Fatal(err)
	}
	defer session.EndSession(context.Background())
	_, err = session.WithTransaction(ctx, func(tx context.Context) (any, error) {
		return c.Database("qualifier").Collection("events").InsertOne(tx, bson.D{{Key: "tenant_id", Value: "tenant-a"}, {Key: "event_id", Value: "transaction-check"}})
	})
	if err != nil {
		t.Fatalf("majority transaction failed: %v", err)
	}
}
