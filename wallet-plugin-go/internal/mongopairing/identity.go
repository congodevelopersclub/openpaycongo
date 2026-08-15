// Package mongopairing provides internal Mongo persistence primitives for the canonical pairing lifecycle.
package mongopairing

import (
	"context"
	"errors"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/mongo/writeconcern"
)

var (
	ErrConflict = errors.New("conflicting pairing identity replay")
	ErrInvalid  = errors.New("invalid pairing identity")
)

// Identity persists no pairing secret or short authentication code.
type Identity struct {
	TenantID  string `bson:"tenant_id"`
	InstallID string `bson:"install_id"`
	DeviceID  string `bson:"device_id"`
	IntentID  string `bson:"intent_id"`
	Status    string `bson:"status"`
}

type Repository struct{ identities *mongo.Collection }

func New(identities *mongo.Collection) *Repository { return &Repository{identities: identities} }

func Validate(identity Identity) error {
	if identity.TenantID == "" || identity.InstallID == "" || identity.DeviceID == "" || identity.IntentID == "" || identity.Status == "" {
		return ErrInvalid
	}
	return nil
}

func (r *Repository) EnsureIndexes(ctx context.Context) error {
	_, err := r.identities.Indexes().CreateMany(ctx, []mongo.IndexModel{
		{Keys: bson.D{{Key: "tenant_id", Value: 1}, {Key: "install_id", Value: 1}}, Options: options.Index().SetUnique(true).SetName("tenant_install")},
		{Keys: bson.D{{Key: "tenant_id", Value: 1}, {Key: "device_id", Value: 1}}, Options: options.Index().SetUnique(true).SetName("tenant_device")},
		{Keys: bson.D{{Key: "intent_id", Value: 1}}, Options: options.Index().SetUnique(true).SetName("intent")},
	})
	return err
}

// Store makes one immutable identity winner. Exact replay returns stored state; changed scope fails closed.
func (r *Repository) Store(ctx context.Context, identity Identity) (Identity, error) {
	if err := Validate(identity); err != nil {
		return Identity{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	session, err := r.identities.Database().Client().StartSession()
	if err != nil {
		return Identity{}, err
	}
	defer session.EndSession(ctx)
	_, err = session.WithTransaction(ctx, func(tx context.Context) (any, error) { _, e := r.identities.InsertOne(tx, identity); return nil, e }, options.Transaction().SetWriteConcern(writeconcern.Majority()))
	if err == nil {
		return identity, nil
	}
	var existing Identity
	if e := r.identities.FindOne(ctx, bson.D{{Key: "tenant_id", Value: identity.TenantID}, {Key: "install_id", Value: identity.InstallID}}).Decode(&existing); e == nil {
		if existing == identity {
			return existing, nil
		}
		return Identity{}, ErrConflict
	}
	return Identity{}, err
}

// RotateStatus atomically transitions exactly one tenant/device without changing enrollment identity.
func (r *Repository) RotateStatus(ctx context.Context, tenantID, deviceID, from, to string) error {
	if tenantID == "" || deviceID == "" || from == "" || to == "" || from == to {
		return ErrInvalid
	}
	result, err := r.identities.UpdateOne(ctx, bson.D{{Key: "tenant_id", Value: tenantID}, {Key: "device_id", Value: deviceID}, {Key: "status", Value: from}}, bson.D{{Key: "$set", Value: bson.D{{Key: "status", Value: to}}}})
	if err != nil {
		return err
	}
	if result.MatchedCount != 1 {
		return ErrConflict
	}
	return nil
}
