package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/example/wallet-plugin-go/internal/analytics"
)

func TestOpenAppliesChecksummedMigrationIdempotently(t *testing.T) {
	path := filepath.Join(t.TempDir(), "analytics.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if store.MigrationRevision() != "0003" {
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
	if store.MigrationRevision() != "0003" {
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

func TestAppendIsImmutableAndIdempotent(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "analytics.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	event := storageEvent(t, "018f0000-0000-7000-8000-000000000001", "4000")
	if err := store.Append(context.Background(), event); err != nil {
		t.Fatal(err)
	}
	if err := store.Append(context.Background(), event); err != nil {
		t.Fatalf("exact replay = %v", err)
	}
	changed := storageEvent(t, event.ID, "5000")
	if err := store.Append(context.Background(), changed); !errors.Is(err, analytics.ErrEventConflict) {
		t.Fatalf("changed replay error = %v, want conflict", err)
	}

	var count int
	var amount string
	if err := store.db.QueryRow("SELECT count(*), max(amount_minor) FROM sales_analytics_events").Scan(&count, &amount); err != nil {
		t.Fatal(err)
	}
	if count != 1 || amount != "4000" {
		t.Fatalf("persisted rows = count %d amount %q", count, amount)
	}
}

func TestSnapshotExcludesLaterAppendAndPagesInAcceptanceOrder(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "analytics.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	first := storageEvent(t, "018f0000-0000-7000-8000-000000000001", "4000")
	if err := store.Append(context.Background(), first); err != nil {
		t.Fatal(err)
	}
	snapshot, err := store.OpenSnapshot(context.Background(), first.TenantID)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Append(context.Background(), storageEvent(t, "018f0000-0000-7000-8000-000000000002", "5000")); err != nil {
		t.Fatal(err)
	}
	page, err := store.List(context.Background(), first.TenantID, snapshot, "", analytics.ProjectionPageSize)
	if err != nil {
		t.Fatal(err)
	}
	if page.Snapshot != snapshot || len(page.Events) != 1 || page.Events[0].ID != first.ID || page.Next != "" {
		t.Fatalf("page = %#v", page)
	}
}

func TestReplaceUsesGenerationCAS(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "analytics.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	event := storageEvent(t, "018f0000-0000-7000-8000-000000000001", "4000")
	projection, err := analytics.Rebuild(event.TenantID, []analytics.LedgerEvent{event})
	if err != nil {
		t.Fatal(err)
	}
	newer := analytics.SourceSnapshot{Generation: 2, Token: "snapshot-tenant-demo-2"}
	if err := store.Replace(context.Background(), event.TenantID, newer, projection); err != nil {
		t.Fatal(err)
	}
	if err := store.Replace(context.Background(), event.TenantID, newer, projection); err != nil {
		t.Fatalf("exact replay = %v", err)
	}
	if err := store.Replace(context.Background(), event.TenantID, analytics.SourceSnapshot{Generation: 1, Token: "snapshot-tenant-demo-1"}, projection); !errors.Is(err, analytics.ErrStaleProjection) {
		t.Fatalf("older replace = %v", err)
	}
	var generation uint64
	if err := store.db.QueryRow("SELECT generation FROM sales_analytics_projections WHERE tenant_id = ?", event.TenantID).Scan(&generation); err != nil {
		t.Fatal(err)
	}
	if generation != 2 {
		t.Fatalf("generation = %d", generation)
	}
}

func storageEvent(t *testing.T, id, amount string) analytics.LedgerEvent {
	t.Helper()
	input := analytics.EventInput{
		ID:         id,
		TenantID:   "tenant-demo",
		Kind:       analytics.KindCapture,
		Amount:     amount,
		Currency:   "CDF",
		Provider:   "orange-money",
		PaymentID:  "payment-demo",
		OccurredAt: time.Date(2026, time.November, 1, 12, 0, 0, 0, time.UTC),
		ReceivedAt: time.Date(2026, time.November, 1, 12, 0, 1, 0, time.UTC),
	}
	digest, err := analytics.CanonicalEventDigest(input)
	if err != nil {
		t.Fatal(err)
	}
	input.Digest = digest
	event, err := analytics.NewLedgerEvent(input)
	if err != nil {
		t.Fatal(err)
	}
	return event
}
