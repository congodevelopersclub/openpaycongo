package sqlite

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/example/wallet-plugin-go/internal/analytics"
	_ "github.com/mattn/go-sqlite3"
)

const migrationRevision = "0002"

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

const snapshotMigrationSQL = `
CREATE TABLE sales_analytics_snapshots (
  token TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  generation INTEGER NOT NULL,
  max_accepted_sequence INTEGER NOT NULL,
  created_at TEXT NOT NULL
);`

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

func (store *Store) OpenSnapshot(ctx context.Context, tenantID string) (analytics.SourceSnapshot, error) {
	var maximum uint64
	if err := store.db.QueryRowContext(ctx, "SELECT COALESCE(MAX(accepted_sequence), 0) FROM sales_analytics_events WHERE tenant_id = ?", tenantID).Scan(&maximum); err != nil {
		return analytics.SourceSnapshot{}, err
	}
	generation := maximum + 1
	token := "snapshot-" + tenantID + "-" + strconv.FormatUint(generation, 10)
	if _, err := store.db.ExecContext(ctx, `INSERT OR IGNORE INTO sales_analytics_snapshots(token, tenant_id, generation, max_accepted_sequence, created_at)
		VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))`, token, tenantID, generation, maximum); err != nil {
		return analytics.SourceSnapshot{}, err
	}
	return analytics.SourceSnapshot{Generation: generation, Token: token}, nil
}

func (store *Store) List(ctx context.Context, tenantID string, snapshot analytics.SourceSnapshot, cursor analytics.EventCursor, limit uint16) (analytics.EventPage, error) {
	if limit == 0 || limit > analytics.ProjectionPageSize {
		return analytics.EventPage{}, fmt.Errorf("invalid analytics page limit")
	}
	var maximum uint64
	if err := store.db.QueryRowContext(ctx, "SELECT max_accepted_sequence FROM sales_analytics_snapshots WHERE token = ? AND tenant_id = ? AND generation = ?", snapshot.Token, tenantID, snapshot.Generation).Scan(&maximum); err != nil {
		return analytics.EventPage{}, err
	}
	position := uint64(0)
	if cursor != "" {
		parsed, err := strconv.ParseUint(string(cursor), 10, 64)
		if err != nil {
			return analytics.EventPage{}, err
		}
		position = parsed
	}
	rows, err := store.db.QueryContext(ctx, `SELECT accepted_sequence, event_id, tenant_id, kind, amount_minor, currency, provider, payment_id, related_event_id, occurred_at, received_at, payload_digest
		FROM sales_analytics_events WHERE tenant_id = ? AND accepted_sequence > ? AND accepted_sequence <= ? ORDER BY accepted_sequence ASC LIMIT ?`, tenantID, position, maximum, limit+1)
	if err != nil {
		return analytics.EventPage{}, err
	}
	defer rows.Close()
	result := analytics.EventPage{Snapshot: snapshot, Events: make([]analytics.LedgerEvent, 0, limit)}
	var last uint64
	for rows.Next() {
		var sequence uint64
		var event analytics.LedgerEvent
		var amount, occurred, received string
		var related sql.NullString
		var digest []byte
		if err := rows.Scan(&sequence, &event.ID, &event.TenantID, &event.Kind, &amount, &event.Currency, &event.Provider, &event.PaymentID, &related, &occurred, &received, &digest); err != nil {
			return analytics.EventPage{}, err
		}
		if len(result.Events) == int(limit) {
			result.Next = analytics.EventCursor(strconv.FormatUint(last, 10))
			break
		}
		var err error
		event.Amount, err = analytics.ParseMinorAmount(amount)
		if err != nil {
			return analytics.EventPage{}, err
		}
		event.RelatedEventID = related.String
		event.OccurredAt, err = analytics.ParseCanonicalTimestamp(occurred)
		if err != nil {
			return analytics.EventPage{}, err
		}
		event.ReceivedAt, err = analytics.ParseCanonicalTimestamp(received)
		if err != nil {
			return analytics.EventPage{}, err
		}
		if len(digest) != len(event.Digest) {
			return analytics.EventPage{}, fmt.Errorf("invalid analytics digest")
		}
		copy(event.Digest[:], digest)
		if err := event.Validate(); err != nil {
			return analytics.EventPage{}, err
		}
		result.Events = append(result.Events, event)
		last = sequence
	}
	if err := rows.Err(); err != nil {
		return analytics.EventPage{}, err
	}
	return result, nil
}

func applyMigration(ctx context.Context, db *sql.DB) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, "CREATE TABLE IF NOT EXISTS schema_migrations (revision TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at TEXT NOT NULL)"); err != nil {
		return err
	}
	for _, migration := range []struct{ revision, sql string }{{"0001", migrationSQL}, {"0002", snapshotMigrationSQL}} {
		checksum := fmt.Sprintf("%x", sha256.Sum256([]byte(migration.sql)))
		var recorded string
		err = tx.QueryRowContext(ctx, "SELECT checksum FROM schema_migrations WHERE revision = ?", migration.revision).Scan(&recorded)
		if errors.Is(err, sql.ErrNoRows) {
			if _, err := tx.ExecContext(ctx, migration.sql); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, "INSERT INTO schema_migrations(revision, checksum, applied_at) VALUES(?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))", migration.revision, checksum); err != nil {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		if recorded != checksum {
			return fmt.Errorf("analytics sqlite migration checksum drift")
		}
	}
	return tx.Commit()
}
