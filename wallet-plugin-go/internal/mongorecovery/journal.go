// Package mongorecovery persists only recovery-plan metadata. It deliberately
// carries no export payload, credentials, or enrollment secrets.
package mongorecovery

import (
	"context"
	"errors"
	"time"

	"github.com/example/wallet-plugin-go/internal/recovery"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/mongo/writeconcern"
)

var ErrTransition = errors.New("invalid persistent recovery journal transition")

type entry struct {
	Digest             string                `bson:"digest"`
	TenantID           string                `bson:"tenant_id"`
	ProjectionRevision string                `bson:"projection_revision"`
	PayloadDigest      []byte                `bson:"payload_digest"`
	State              recovery.JournalState `bson:"state"`
}

// Journal records the durable recovery state for a tenant-scoped restore plan.
// It is intentionally separate from the target mutation authority.
type Journal struct{ entries *mongo.Collection }

func New(entries *mongo.Collection) *Journal { return &Journal{entries: entries} }

func (j *Journal) EnsureIndexes(ctx context.Context) error {
	_, err := j.entries.Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys:    bson.D{{Key: "tenant_id", Value: 1}, {Key: "digest", Value: 1}},
		Options: options.Index().SetUnique(true).SetName("tenant_recovery_plan"),
	})
	return err
}

// Prepare records one immutable recovery plan. An exact prepared replay is
// idempotent; applied and aborted plans remain terminal across process restart.
func (j *Journal) Prepare(ctx context.Context, plan recovery.RestorePlan) (string, error) {
	if j == nil || j.entries == nil || plan.TenantID == "" || plan.ProjectionRevision == "" {
		return "", ErrTransition
	}
	digest := recovery.PlanDigest(plan)
	attempt := entry{Digest: digest, TenantID: plan.TenantID, ProjectionRevision: plan.ProjectionRevision, PayloadDigest: plan.PayloadDigest[:], State: recovery.JournalPrepared}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	session, err := j.entries.Database().Client().StartSession()
	if err != nil {
		return "", err
	}
	defer session.EndSession(ctx)
	_, err = session.WithTransaction(ctx, func(tx context.Context) (any, error) {
		_, insertErr := j.entries.InsertOne(tx, attempt)
		return nil, insertErr
	}, options.Transaction().SetWriteConcern(writeconcern.Majority()))
	if err == nil {
		return digest, nil
	}
	var stored entry
	if findErr := j.entries.FindOne(ctx, bson.D{{Key: "tenant_id", Value: plan.TenantID}, {Key: "digest", Value: digest}}).Decode(&stored); findErr != nil {
		return "", err
	}
	if stored.ProjectionRevision == attempt.ProjectionRevision && string(stored.PayloadDigest) == string(attempt.PayloadDigest) && stored.State == recovery.JournalPrepared {
		return digest, nil
	}
	return "", ErrTransition
}

// Transition changes a prepared plan once. It never reopens a terminal plan.
func (j *Journal) Transition(ctx context.Context, tenantID, digest string, state recovery.JournalState) error {
	if j == nil || j.entries == nil || tenantID == "" || digest == "" || (state != recovery.JournalApplied && state != recovery.JournalAborted) {
		return ErrTransition
	}
	result, err := j.entries.UpdateOne(ctx,
		bson.D{{Key: "tenant_id", Value: tenantID}, {Key: "digest", Value: digest}, {Key: "state", Value: recovery.JournalPrepared}},
		bson.D{{Key: "$set", Value: bson.D{{Key: "state", Value: state}}}},
	)
	if err != nil {
		return err
	}
	if result.MatchedCount != 1 {
		return ErrTransition
	}
	return nil
}

// State is tenant-scoped so a plan digest cannot disclose recovery state across tenants.
func (j *Journal) State(ctx context.Context, tenantID, digest string) (recovery.JournalState, error) {
	if j == nil || j.entries == nil || tenantID == "" || digest == "" {
		return "", ErrTransition
	}
	var stored entry
	if err := j.entries.FindOne(ctx, bson.D{{Key: "tenant_id", Value: tenantID}, {Key: "digest", Value: digest}}).Decode(&stored); err != nil {
		return "", err
	}
	return stored.State, nil
}
