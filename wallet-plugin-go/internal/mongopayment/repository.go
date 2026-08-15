package mongopayment

import (
	"context"
	"errors"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/mongo/writeconcern"
)

var ErrConflict = errors.New("conflicting payment replay")

// Payment is canonical immutable payment evidence; it is internal-only.
type Payment struct {
	TenantID       string `bson:"tenant_id"`
	DeviceID       string `bson:"device_id"`
	IdempotencyKey string `bson:"idempotency_key"`
	Canonical      string `bson:"canonical"`
}
type Result struct{ TenantID, DeviceID, IdempotencyKey, Canonical string }

// ReplayResult applies exact-replay and conflicting-replay semantics independent of transport.
func ReplayResult(stored, attempted Payment) (Result, error) {
	if stored.TenantID != attempted.TenantID || stored.DeviceID != attempted.DeviceID || stored.IdempotencyKey != attempted.IdempotencyKey || stored.Canonical != attempted.Canonical {
		return Result{}, ErrConflict
	}
	return Result{stored.TenantID, stored.DeviceID, stored.IdempotencyKey, stored.Canonical}, nil
}

type MongoRepository struct{ events *mongo.Collection }

func NewMongo(events *mongo.Collection) *MongoRepository { return &MongoRepository{events: events} }

func (r *MongoRepository) EnsureIndexes(ctx context.Context) error {
	_, err := r.events.Indexes().CreateOne(ctx, mongo.IndexModel{Keys: bson.D{{Key: "tenant_id", Value: 1}, {Key: "device_id", Value: 1}, {Key: "idempotency_key", Value: 1}}, Options: options.Index().SetUnique(true).SetName("tenant_device_idempotency")})
	return err
}

func (r *MongoRepository) Store(ctx context.Context, p Payment) (Result, error) {
	if p.TenantID == "" || p.DeviceID == "" || p.IdempotencyKey == "" || p.Canonical == "" {
		return Result{}, errors.New("invalid canonical payment")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	s, err := r.events.Database().Client().StartSession()
	if err != nil {
		return Result{}, err
	}
	defer s.EndSession(ctx)
	_, err = s.WithTransaction(ctx, func(tx context.Context) (any, error) {
		_, e := r.events.InsertOne(tx, bson.D{{Key: "tenant_id", Value: p.TenantID}, {Key: "device_id", Value: p.DeviceID}, {Key: "idempotency_key", Value: p.IdempotencyKey}, {Key: "canonical", Value: p.Canonical}})
		return nil, e
	}, options.Transaction().SetWriteConcern(writeconcern.Majority()))
	if err == nil {
		return Result{p.TenantID, p.DeviceID, p.IdempotencyKey, p.Canonical}, nil
	}
	var old Payment
	if e := r.events.FindOne(ctx, bson.D{{Key: "tenant_id", Value: p.TenantID}, {Key: "device_id", Value: p.DeviceID}, {Key: "idempotency_key", Value: p.IdempotencyKey}}).Decode(&old); e == nil {
		return ReplayResult(old, p)
	}
	return Result{}, err
}
