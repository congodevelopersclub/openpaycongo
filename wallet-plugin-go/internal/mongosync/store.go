// Package mongosync provides an internal-only Mongo implementation of the
// canonical analytics event and acknowledgement contract.
package mongosync

import (
	"context"
	"errors"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/mongo/writeconcern"

	"github.com/example/wallet-plugin-go/internal/analytics"
)

type Store struct{ events, acknowledgements *mongo.Collection }

func New(events, acknowledgements *mongo.Collection) *Store {
	return &Store{events: events, acknowledgements: acknowledgements}
}

func (s *Store) EnsureIndexes(ctx context.Context) error {
	if _, err := s.events.Indexes().CreateMany(ctx, []mongo.IndexModel{
		{Keys: bson.D{{Key: "event_id", Value: 1}}, Options: options.Index().SetUnique(true).SetName("event")},
		{Keys: bson.D{{Key: "tenant_id", Value: 1}, {Key: "accepted_sequence", Value: 1}}, Options: options.Index().SetUnique(true).SetName("tenant_acceptance")},
	}); err != nil {
		return err
	}
	_, err := s.acknowledgements.Indexes().CreateOne(ctx, mongo.IndexModel{Keys: bson.D{{Key: "tenant_id", Value: 1}, {Key: "replica_id", Value: 1}}, Options: options.Index().SetUnique(true).SetName("tenant_replica")})
	return err
}

func (s *Store) Append(ctx context.Context, event analytics.LedgerEvent) error {
	if err := event.Validate(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	sequence, err := s.nextSequence(ctx, event.TenantID)
	if err != nil {
		return err
	}
	doc := bson.D{{Key: "event_id", Value: event.ID}, {Key: "tenant_id", Value: event.TenantID}, {Key: "payment_id", Value: event.PaymentID}, {Key: "digest", Value: event.Digest[:]}, {Key: "accepted_sequence", Value: sequence}}
	if _, err = s.events.InsertOne(ctx, doc); err == nil {
		return nil
	}
	var existing struct {
		TenantID  string `bson:"tenant_id"`
		PaymentID string `bson:"payment_id"`
		Digest    []byte `bson:"digest"`
	}
	if findErr := s.events.FindOne(ctx, bson.D{{Key: "event_id", Value: event.ID}}).Decode(&existing); findErr == nil {
		if existing.TenantID == event.TenantID && existing.PaymentID == event.PaymentID && string(existing.Digest) == string(event.Digest[:]) {
			return nil
		}
		return analytics.ErrEventConflict
	}
	return err
}

func (s *Store) Acknowledge(ctx context.Context, tenantID, replicaID string, cursor uint64) error {
	if tenantID == "" || replicaID == "" || cursor == 0 {
		return analytics.ErrEventConflict
	}
	session, err := s.events.Database().Client().StartSession()
	if err != nil {
		return err
	}
	defer session.EndSession(ctx)
	_, err = session.WithTransaction(ctx, func(tx context.Context) (any, error) {
		var ack struct {
			Cursor uint64 `bson:"cursor"`
		}
		current := uint64(0)
		if e := s.acknowledgements.FindOne(tx, bson.D{{Key: "tenant_id", Value: tenantID}, {Key: "replica_id", Value: replicaID}}).Decode(&ack); e == nil {
			current = ack.Cursor
		} else if !errors.Is(e, mongo.ErrNoDocuments) {
			return nil, e
		}
		if cursor == current {
			return nil, nil
		}
		var next struct {
			Sequence uint64 `bson:"accepted_sequence"`
		}
		if e := s.events.FindOne(tx, bson.D{{Key: "tenant_id", Value: tenantID}, {Key: "accepted_sequence", Value: bson.D{{Key: "$gt", Value: current}}}}, options.FindOne().SetSort(bson.D{{Key: "accepted_sequence", Value: 1}})).Decode(&next); e != nil || next.Sequence != cursor {
			return nil, analytics.ErrEventConflict
		}
		_, e := s.acknowledgements.UpdateOne(tx, bson.D{{Key: "tenant_id", Value: tenantID}, {Key: "replica_id", Value: replicaID}}, bson.D{{Key: "$set", Value: bson.D{{Key: "cursor", Value: cursor}, {Key: "acknowledged_at", Value: time.Now().UTC()}}}}, options.UpdateOne().SetUpsert(true))
		return nil, e
	}, options.Transaction().SetWriteConcern(writeconcern.Majority()))
	return err
}

func (s *Store) nextSequence(ctx context.Context, tenantID string) (uint64, error) {
	var last struct {
		Sequence uint64 `bson:"accepted_sequence"`
	}
	err := s.events.FindOne(ctx, bson.D{{Key: "tenant_id", Value: tenantID}}, options.FindOne().SetSort(bson.D{{Key: "accepted_sequence", Value: -1}})).Decode(&last)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return 1, nil
	}
	return last.Sequence + 1, err
}
