package sqlite

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"fmt"

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
