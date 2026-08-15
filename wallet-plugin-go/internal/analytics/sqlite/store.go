package sqlite

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/example/wallet-plugin-go/internal/analytics"
	_ "github.com/mattn/go-sqlite3"
)

const migrationRevision = "0001"

const migrationSQL = `
CREATE TABLE sales_analytics_events (
  accepted_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL UNIQUE,
  tenant_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  amount_minor TEXT NOT NULL,
  currency TEXT NOT NULL,
  provider TEXT NOT NULL,
  payment_id TEXT NOT NULL,
  related_event_id TEXT,
  occurred_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  payload_digest TEXT NOT NULL
);
CREATE INDEX sales_analytics_events_tenant_acceptance ON sales_analytics_events(tenant_id, accepted_sequence);`

type Store struct{ db *sql.DB }

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		return nil, err
	}
	if err := db.PingContext(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.Exec("PRAGMA foreign_keys = ON"); err != nil {
		db.Close()
		return nil, err
	}
	if err := applyMigration(context.Background(), db); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (store *Store) Close() error              { return store.db.Close() }
func (store *Store) MigrationRevision() string { return migrationRevision }

// Append persists a validated analytics event exactly once. It never changes
// an existing event: an exact replay succeeds and a changed replay conflicts.
func (store *Store) Append(ctx context.Context, event analytics.LedgerEvent) error {
	if err := event.Validate(); err != nil {
		return err
	}
	existing, found, err := store.find(ctx, event.ID)
	if err != nil {
		return err
	}
	if found {
		if existing.matches(event) {
			return nil
		}
		return analytics.ErrEventConflict
	}
	_, err = store.db.ExecContext(ctx, `INSERT INTO sales_analytics_events
		(event_id, tenant_id, kind, amount_minor, currency, provider, payment_id, related_event_id, occurred_at, received_at, payload_digest)
		VALUES (?, ?, ?, ?, ?, ?, ?, NULLIF(?, ''), ?, ?, ?)`,
		event.ID, event.TenantID, event.Kind, event.Amount.String(), event.Currency, event.Provider, event.PaymentID, event.RelatedEventID,
		event.OccurredAt.Format(time.RFC3339), event.ReceivedAt.Format(time.RFC3339), event.Digest[:])
	if err == nil {
		return nil
	}
	existing, found, lookupErr := store.find(ctx, event.ID)
	if lookupErr != nil {
		return err
	}
	if found {
		if existing.matches(event) {
			return nil
		}
		return analytics.ErrEventConflict
	}
	return err
}

type storedEvent struct {
	tenantID, kind, amount, currency, provider, paymentID, relatedID, occurredAt, receivedAt string
	digest                                                                                   []byte
}

func (store *Store) find(ctx context.Context, id string) (storedEvent, bool, error) {
	var event storedEvent
	var related sql.NullString
	err := store.db.QueryRowContext(ctx, `SELECT tenant_id, kind, amount_minor, currency, provider, payment_id, related_event_id, occurred_at, received_at, payload_digest
		FROM sales_analytics_events WHERE event_id = ?`, id).Scan(
		&event.tenantID, &event.kind, &event.amount, &event.currency, &event.provider, &event.paymentID, &related, &event.occurredAt, &event.receivedAt, &event.digest)
	if errors.Is(err, sql.ErrNoRows) {
		return storedEvent{}, false, nil
	}
	if err != nil {
		return storedEvent{}, false, err
	}
	event.relatedID = related.String
	return event, true, nil
}

func (stored storedEvent) matches(event analytics.LedgerEvent) bool {
	return stored.tenantID == event.TenantID && stored.kind == string(event.Kind) && stored.amount == event.Amount.String() &&
		stored.currency == event.Currency && stored.provider == event.Provider && stored.paymentID == event.PaymentID &&
		stored.relatedID == event.RelatedEventID && stored.occurredAt == event.OccurredAt.Format(time.RFC3339) &&
		stored.receivedAt == event.ReceivedAt.Format(time.RFC3339) && string(stored.digest) == string(event.Digest[:])
}

func applyMigration(ctx context.Context, db *sql.DB) error {
	checksum := fmt.Sprintf("%x", sha256.Sum256([]byte(migrationSQL)))
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, "CREATE TABLE IF NOT EXISTS schema_migrations (revision TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at TEXT NOT NULL)"); err != nil {
		return err
	}
	var recorded string
	err = tx.QueryRowContext(ctx, "SELECT checksum FROM schema_migrations WHERE revision = ?", migrationRevision).Scan(&recorded)
	if err == sql.ErrNoRows {
		if _, err := tx.ExecContext(ctx, migrationSQL); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "INSERT INTO schema_migrations(revision, checksum, applied_at) VALUES(?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))", migrationRevision, checksum); err != nil {
			return err
		}
		return tx.Commit()
	}
	if err != nil {
		return err
	}
	if recorded != checksum {
		return fmt.Errorf("analytics sqlite migration checksum drift")
	}
	return tx.Commit()
}
