package analytics

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"testing"
	"time"
)

func vectorEvents(t *testing.T) []LedgerEvent {
	t.Helper()
	return []LedgerEvent{
		testEvent(t, "018f0000-0000-7000-8000-000000000001", KindCapture, "4000", "CDF", "orange-money", "previous", "", "2026-10-31T16:00:00Z", "2026-10-31T16:00:10Z"),
		testEvent(t, "018f0000-0000-7000-8000-000000000002", KindCapture, "10000", "CDF", "orange-money", "capture-cdf", "", "2026-11-01T05:30:00Z", "2026-11-01T05:30:10Z"),
		testEvent(t, "018f0000-0000-7000-8000-000000000003", KindCapture, "500", "USD", "mpesa", "capture-usd", "", "2026-11-01T06:30:00Z", "2026-11-01T08:30:00Z"),
		testEvent(t, "018f0000-0000-7000-8000-000000000004", KindRefund, "2000", "CDF", "orange-money", "refund-cdf", "018f0000-0000-7000-8000-000000000002", "2026-11-01T07:00:00Z", "2026-11-01T07:00:10Z"),
		testEvent(t, "018f0000-0000-7000-8000-000000000005", KindCapture, "3000", "CDF", "airtel-money", "voided-capture", "", "2026-11-01T07:30:00Z", "2026-11-01T07:30:05Z"),
		testEvent(t, "018f0000-0000-7000-8000-000000000006", KindVoid, "3000", "CDF", "airtel-money", "void", "018f0000-0000-7000-8000-000000000005", "2026-11-01T08:00:00Z", "2026-11-01T08:00:05Z"),
		testEvent(t, "018f0000-0000-7000-8000-000000000007", KindReconciled, "0", "CDF", "orange-money", "reconciled", "018f0000-0000-7000-8000-000000000002", "2026-11-01T06:00:00Z", "2026-11-01T06:00:00Z"),
	}
}

func testEvent(t *testing.T, id string, kind EventKind, amount, currency, provider, paymentID, relatedID, occurredAt, receivedAt string) LedgerEvent {
	t.Helper()
	input := EventInput{ID: id, TenantID: "tenant-demo", Kind: kind, Amount: amount, Currency: currency, Provider: provider, PaymentID: paymentID, RelatedEventID: relatedID, OccurredAt: mustTime(t, occurredAt), ReceivedAt: mustTime(t, receivedAt)}
	digest, err := CanonicalEventDigest(input)
	if err != nil {
		t.Fatalf("digest %s: %v", id, err)
	}
	input.Digest = digest
	event, err := NewLedgerEvent(input)
	if err != nil {
		t.Fatalf("event %s: %v", id, err)
	}
	return event
}

func mustAmount(t *testing.T, value string) MinorAmount {
	t.Helper()
	amount, err := ParseMinorAmount(value)
	if err != nil {
		t.Fatal(err)
	}
	return amount
}

func mustTime(t *testing.T, value string) time.Time {
	t.Helper()
	parsed, err := ParseCanonicalTimestamp(value)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

type fixedAnalyticsClock struct{ now time.Time }

func (clock fixedAnalyticsClock) Now() time.Time { return clock.now }

func queryProjection(projection SalesProjection, tenantID string, query DashboardQuery) (Dashboard, error) {
	return NewDashboardService(fixedAnalyticsClock{now: query.SnapshotAt}).Query(context.Background(), projection, tenantID, query)
}

func assertCurrency(t *testing.T, metrics []CurrencyMetrics, currency, gross, refunds, net, count, average string) {
	t.Helper()
	for _, metric := range metrics {
		if metric.Currency != currency {
			continue
		}
		if metric.GrossMinor != gross || metric.RefundsMinor != refunds || metric.NetMinor != net || metric.PaymentCount != count || metric.AverageTicketMinor != average {
			t.Fatalf("%s metrics: %#v", currency, metric)
		}
		return
	}
	t.Fatalf("missing %s metrics", currency)
}

func hasCue(cues []ActionCue, kind CueKind) bool {
	for _, cue := range cues {
		if cue.Kind == kind {
			return true
		}
	}
	return false
}

type pagedEventSource struct {
	events    []LedgerEvent
	failPage  uint16
	driftPage uint16
	cyclePage uint16
	snapshot  SourceSnapshot
}

type blockingEventSource struct {
	*pagedEventSource
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (source *blockingEventSource) List(ctx context.Context, tenantID string, snapshot SourceSnapshot, cursor EventCursor, limit uint16) (EventPage, error) {
	if cursor == "" {
		source.once.Do(func() { close(source.entered) })
		select {
		case <-source.release:
		case <-ctx.Done():
			return EventPage{}, ctx.Err()
		}
	}
	return source.pagedEventSource.List(ctx, tenantID, snapshot, cursor, limit)
}

func (source *pagedEventSource) OpenSnapshot(_ context.Context, tenantID string) (SourceSnapshot, error) {
	if tenantID != "tenant-demo" {
		return SourceSnapshot{}, ErrProjectionUnavailable
	}
	if source.snapshot.Generation == 0 {
		source.snapshot = SourceSnapshot{Generation: 1, Token: "snapshot-1"}
	}
	return source.snapshot, nil
}

func (source *pagedEventSource) List(_ context.Context, tenantID string, snapshot SourceSnapshot, cursor EventCursor, limit uint16) (EventPage, error) {
	offset := 0
	if cursor != "" {
		parsed, err := strconv.Atoi(string(cursor))
		if err != nil {
			return EventPage{}, err
		}
		offset = parsed
	}
	pageNumber := uint16(offset/int(ProjectionPageSize)) + 1
	if source.failPage == pageNumber {
		return EventPage{}, errors.New("simulated immutable source crash")
	}
	if tenantID != "tenant-demo" || limit == 0 || limit > ProjectionPageSize {
		return EventPage{}, ErrProjectionUnavailable
	}
	end := offset + int(limit)
	if end > len(source.events) {
		end = len(source.events)
	}
	page := EventPage{Events: append([]LedgerEvent(nil), source.events[offset:end]...), Snapshot: snapshot}
	if end < len(source.events) {
		page.Next = EventCursor(strconv.Itoa(end))
	}
	if source.driftPage == pageNumber {
		page.Snapshot.Generation++
	}
	if source.cyclePage == pageNumber {
		page.Next = cursor
	}
	return page, nil
}

type memoryProjectionRepository struct {
	mu           sync.Mutex
	projection   SalesProjection
	replaceCount int
	generation   uint64
}

func (repository *memoryProjectionRepository) Replace(_ context.Context, tenantID string, snapshot SourceSnapshot, projection SalesProjection) error {
	repository.mu.Lock()
	defer repository.mu.Unlock()
	if tenantID != projection.TenantID() {
		return ErrTenantScope
	}
	if snapshot.Generation < repository.generation {
		return ErrStaleProjection
	}
	if snapshot.Generation == repository.generation && repository.projection.Version() != "" && repository.projection.Version() != projection.Version() {
		return ErrStaleProjection
	}
	repository.projection = projection
	repository.generation = snapshot.Generation
	repository.replaceCount++
	return nil
}
