package sqlite

import (
	"database/sql"
	"path/filepath"
	"testing"
)

func TestOpenAppliesChecksummedMigrationIdempotently(t *testing.T) {
	path := filepath.Join(t.TempDir(), "analytics.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if store.MigrationRevision() != "0001" {
		t.Fatalf("revision = %q", store.MigrationRevision())
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if store.MigrationRevision() != "0001" {
		t.Fatalf("reopen revision = %q", store.MigrationRevision())
	}
}

func TestOpenFailsClosedOnMigrationChecksumDrift(t *testing.T) {
	path := filepath.Join(t.TempDir(), "analytics.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("UPDATE schema_migrations SET checksum = 'drift' WHERE revision = '0001'"); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path); err == nil {
		t.Fatal("Open() accepted checksum drift")
	}
}
