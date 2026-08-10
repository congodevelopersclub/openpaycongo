package analytics

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"testing"
	"time"
)

func TestPortableSalesAnalyticsVector(t *testing.T) {
	t.Parallel()
	encoded, err := os.ReadFile(filepath.FromSlash("testdata/sales-analytics.vector.json"))
	if err != nil {
		t.Fatal(err)
	}
	var vector struct {
		Query struct {
			From       string `json:"from"`
			To         string `json:"to"`
			AsOf       string `json:"snapshot_at"`
			TimeZone   string `json:"time_zone"`
			Interval   string `json:"interval"`
			Comparison bool   `json:"comparison"`
		} `json:"query"`
		Events []struct {
			ID         string    `json:"event_id"`
			TenantID   string    `json:"tenant_id"`
			Kind       EventKind `json:"kind"`
			Amount     string    `json:"amount_minor"`
			Currency   string    `json:"currency"`
			Provider   string    `json:"provider"`
			PaymentID  string    `json:"payment_id"`
			RelatedID  string    `json:"related_event_id"`
			OccurredAt string    `json:"occurred_at"`
			ReceivedAt string    `json:"received_at"`
			Digest     string    `json:"payload_digest"`
		} `json:"events"`
		Expected struct {
			ProjectionVersion string            `json:"projection_version"`
			ETag              string            `json:"etag"`
			Current           []CurrencyMetrics `json:"current_currencies"`
			Providers         []ProviderMetrics `json:"current_providers"`
			ComparisonGross   string            `json:"comparison_cdf_gross_minor"`
			ReconciliationLag string            `json:"reconciliation_lag_seconds_max"`
			Unreconciled      string            `json:"unreconciled_count"`
			Freshness         string            `json:"sync_freshness_seconds"`
			Cues              []CueKind         `json:"action_required"`
		} `json:"expected"`
	}
	if err := json.Unmarshal(encoded, &vector); err != nil {
		t.Fatal(err)
	}
	events := make([]LedgerEvent, 0, len(vector.Events))
	for _, item := range vector.Events {
		digestBytes, err := hex.DecodeString(item.Digest)
		if err != nil {
			t.Fatal(err)
		}
		var digest EventDigest
		copy(digest[:], digestBytes)
		event, err := NewLedgerEvent(EventInput{ID: item.ID, TenantID: item.TenantID, Kind: item.Kind, Amount: item.Amount, Currency: item.Currency, Provider: item.Provider, PaymentID: item.PaymentID, RelatedEventID: item.RelatedID, OccurredAt: mustTime(t, item.OccurredAt), ReceivedAt: mustTime(t, item.ReceivedAt), Digest: digest})
		if err != nil {
			t.Fatal(err)
		}
		events = append(events, event)
	}
	projection, err := Rebuild("tenant-demo", events)
	if err != nil {
		t.Fatal(err)
	}
	result, err := queryProjection(projection, "tenant-demo", DashboardQuery{From: mustTime(t, vector.Query.From), To: mustTime(t, vector.Query.To), SnapshotAt: mustTime(t, vector.Query.AsOf), TimeZone: vector.Query.TimeZone, Interval: Interval(vector.Query.Interval), Comparison: vector.Query.Comparison})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.EqualFunc(result.Current.Currencies, vector.Expected.Current, func(a, b CurrencyMetrics) bool { return a == b }) {
		t.Fatalf("current vector mismatch: %#v", result.Current.Currencies)
	}
	if !reflect.DeepEqual(result.Current.Providers, vector.Expected.Providers) {
		t.Fatalf("provider vector mismatch: %#v", result.Current.Providers)
	}
	if result.ProjectionVersion != vector.Expected.ProjectionVersion || result.ETag != vector.Expected.ETag {
		t.Fatalf("version/etag vector mismatch: %s %s", result.ProjectionVersion, result.ETag)
	}
	if result.Comparison == nil || result.Comparison.Currencies[0].GrossMinor != vector.Expected.ComparisonGross || result.Reconciliation.LagSecondsMax != vector.Expected.ReconciliationLag || result.Reconciliation.UnreconciledCount != vector.Expected.Unreconciled || result.Sync.FreshnessSeconds != vector.Expected.Freshness {
		t.Fatalf("operational vector mismatch: %#v", result)
	}
	for _, cue := range vector.Expected.Cues {
		if !hasCue(result.ActionRequired, cue) {
			t.Fatalf("missing vector cue %s", cue)
		}
	}
}

func TestCanonicalTimestampRequiresExactUTCSecondsWireForm(t *testing.T) {
	t.Parallel()
	if _, err := ParseCanonicalTimestamp("2026-11-01T05:30:00Z"); err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"2026-11-01T05:30:00.000Z", "2026-11-01T05:30:00+00:00", "2026-11-01t05:30:00Z"} {
		if _, err := ParseCanonicalTimestamp(value); !errors.Is(err, ErrInvalidEvent) {
			t.Fatalf("non-canonical timestamp %q: %v", value, err)
		}
	}
}

func TestRebuildIsOrderIndependentIdempotentAndAppliesCorrections(t *testing.T) {
	t.Parallel()
	events := vectorEvents(t)
	forward, err := Rebuild("tenant-demo", events)
	if err != nil {
		t.Fatal(err)
	}
	reversed := slices.Clone(events)
	slices.Reverse(reversed)
	backward, err := Rebuild("tenant-demo", reversed)
	if err != nil {
		t.Fatal(err)
	}
	if forward.Version() != backward.Version() {
		t.Fatal("projection version depends on arrival order")
	}
	query := DashboardQuery{SnapshotAt: mustTime(t, "2026-11-02T12:00:00Z"), From: mustTime(t, "2026-11-01T04:00:00Z"), To: mustTime(t, "2026-11-02T05:00:00Z"), Interval: IntervalDay, TimeZone: "America/New_York", Comparison: true}
	first, err := queryProjection(forward, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	second, err := queryProjection(backward, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	if first.ETag != second.ETag {
		t.Fatal("ETag depends on replay or arrival order")
	}
	assertCurrency(t, first.Current.Currencies, "CDF", "10000", "2000", "8000", "1", "10000")
	assertCurrency(t, first.Current.Currencies, "USD", "500", "0", "500", "1", "500")
	if len(first.Series) != 1 || first.Series[0].From != query.From || first.Series[0].To != query.To {
		t.Fatalf("DST bucket did not preserve 25-hour local day: %#v", first.Series)
	}
	if first.Reconciliation.UnreconciledCount != "1" || first.Reconciliation.LagSecondsMax != "99000" {
		t.Fatalf("reconciliation: %#v", first.Reconciliation)
	}
	if first.Sync.FreshnessSeconds != "99000" {
		t.Fatalf("sync freshness: %#v", first.Sync)
	}
	if !hasCue(first.ActionRequired, CueStaleSync) || !hasCue(first.ActionRequired, CueReconciliationOverdue) || !hasCue(first.ActionRequired, CueLateArrival) {
		t.Fatalf("missing action cues: %#v", first.ActionRequired)
	}
	if first.Comparison == nil {
		t.Fatal("comparison window missing")
	}
	assertCurrency(t, first.Comparison.Currencies, "CDF", "4000", "0", "4000", "1", "4000")
}

func TestSnapshotExcludesEventsReceivedLaterAndFreshnessUsesServerClock(t *testing.T) {
	t.Parallel()
	projection, err := Rebuild("tenant-demo", vectorEvents(t))
	if err != nil {
		t.Fatal(err)
	}
	observedAt := mustTime(t, "2026-11-02T12:00:00Z")
	query := DashboardQuery{SnapshotAt: mustTime(t, "2026-11-01T07:45:00Z"), From: mustTime(t, "2026-11-01T04:00:00Z"), To: mustTime(t, "2026-11-01T07:45:00Z"), Interval: IntervalDay, TimeZone: "America/New_York"}
	result, err := NewDashboardService(fixedAnalyticsClock{now: observedAt}).Query(context.Background(), projection, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	assertCurrency(t, result.Current.Currencies, "CDF", "13000", "2000", "11000", "2", "6500")
	for _, metric := range result.Current.Currencies {
		if metric.Currency == "USD" {
			t.Fatal("future-received USD capture entered snapshot")
		}
	}
	if result.Sync.FreshnessSeconds != "102595" || result.ObservedAt != observedAt || result.SnapshotAt != query.SnapshotAt {
		t.Fatalf("snapshot/clock truth: %#v", result.Sync)
	}
	query.SnapshotAt = observedAt.Add(time.Second)
	if _, err := NewDashboardService(fixedAnalyticsClock{now: observedAt}).Query(context.Background(), projection, "tenant-demo", query); !errors.Is(err, ErrQueryBounds) {
		t.Fatalf("future snapshot: %v", err)
	}
}

func TestDaySeriesUsesLocalMidnightWithBoundedPartialEdges(t *testing.T) {
	t.Parallel()
	projection, err := Rebuild("tenant-demo", vectorEvents(t))
	if err != nil {
		t.Fatal(err)
	}
	query := DashboardQuery{SnapshotAt: mustTime(t, "2026-11-04T12:00:00Z"), From: mustTime(t, "2026-11-01T10:00:00Z"), To: mustTime(t, "2026-11-03T05:00:00Z"), Interval: IntervalDay, TimeZone: "America/New_York"}
	result, err := queryProjection(projection, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	want := []time.Time{query.From, mustTime(t, "2026-11-02T05:00:00Z"), query.To}
	if len(result.Series) != 2 {
		t.Fatalf("partial day buckets: %#v", result.Series)
	}
	for index, bucket := range result.Series {
		if bucket.From != want[index] || bucket.To != want[index+1] {
			t.Fatalf("bucket %d not local-midnight bounded: %#v", index, bucket)
		}
	}
}

func TestCorrectionLifecycleFailsClosedWithoutRewritingSales(t *testing.T) {
	t.Parallel()
	capture := testEvent(t, "018f0000-0000-7000-8000-000000000101", KindCapture, "1000", "CDF", "orange-money", "capture", "", "2026-11-01T05:00:00Z", "2026-11-01T05:00:01Z")
	mismatchedVoid := testEvent(t, "018f0000-0000-7000-8000-000000000102", KindVoid, "999", "CDF", "orange-money", "bad-void", capture.ID, "2026-11-01T05:10:00Z", "2026-11-01T05:10:01Z")
	projection, err := Rebuild("tenant-demo", []LedgerEvent{capture, mismatchedVoid})
	if err != nil {
		t.Fatal(err)
	}
	query := DashboardQuery{SnapshotAt: mustTime(t, "2026-11-02T12:00:00Z"), From: mustTime(t, "2026-11-01T04:00:00Z"), To: mustTime(t, "2026-11-02T05:00:00Z"), Interval: IntervalDay, TimeZone: "America/New_York"}
	result, err := queryProjection(projection, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	assertCurrency(t, result.Current.Currencies, "CDF", "1000", "0", "1000", "1", "1000")
	if !hasCue(result.ActionRequired, CueCorrectionMismatch) {
		t.Fatal("mismatched void was not actionable")
	}

	validVoid := testEvent(t, "018f0000-0000-7000-8000-000000000103", KindVoid, "1000", "CDF", "orange-money", "void", capture.ID, "2026-11-01T05:20:00Z", "2026-11-01T05:20:01Z")
	afterVoid := testEvent(t, "018f0000-0000-7000-8000-000000000104", KindRefund, "100", "CDF", "orange-money", "late-refund", capture.ID, "2026-11-01T05:30:00Z", "2026-11-01T05:30:01Z")
	orphan := testEvent(t, "018f0000-0000-7000-8000-000000000105", KindRefund, "100", "CDF", "orange-money", "orphan", "018f0000-0000-7000-8000-000000000999", "2026-11-01T05:40:00Z", "2026-11-01T05:40:01Z")
	projection, err = Rebuild("tenant-demo", []LedgerEvent{afterVoid, orphan, validVoid, capture})
	if err != nil {
		t.Fatal(err)
	}
	result, err = queryProjection(projection, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Current.Currencies) != 0 {
		t.Fatalf("void lifecycle retained money: %#v", result.Current.Currencies)
	}
	if !hasCue(result.ActionRequired, CueCorrectionAfterVoid) || !hasCue(result.ActionRequired, CueOrphanCorrection) {
		t.Fatalf("correction lifecycle cues: %#v", result.ActionRequired)
	}
}

func TestCorrectionEventTimeLifecycleIsOrderIndependentAndFailClosed(t *testing.T) {
	t.Parallel()
	capture := testEvent(t, "018f0000-0000-7000-8000-000000000201", KindCapture, "1000", "CDF", "orange-money", "capture", "", "2026-11-01T05:00:00Z", "2026-11-01T05:00:01Z")
	priorRefund := testEvent(t, "018f0000-0000-7000-8000-000000000202", KindRefund, "100", "CDF", "orange-money", "refund-before-void", capture.ID, "2026-11-01T05:10:00Z", "2026-11-01T05:40:00Z")
	conflictingVoid := testEvent(t, "018f0000-0000-7000-8000-000000000203", KindVoid, "1000", "CDF", "orange-money", "void-after-refund", capture.ID, "2026-11-01T05:20:00Z", "2026-11-01T05:30:00Z")
	laterRefund := testEvent(t, "018f0000-0000-7000-8000-000000000204", KindRefund, "200", "CDF", "orange-money", "refund-after-conflict", capture.ID, "2026-11-01T05:30:00Z", "2026-11-01T05:31:00Z")
	query := DashboardQuery{SnapshotAt: mustTime(t, "2026-11-02T12:00:00Z"), From: mustTime(t, "2026-11-01T04:00:00Z"), To: mustTime(t, "2026-11-02T05:00:00Z"), Interval: IntervalDay, TimeZone: "America/New_York"}

	projection, err := Rebuild("tenant-demo", []LedgerEvent{conflictingVoid, laterRefund, capture, priorRefund})
	if err != nil {
		t.Fatal(err)
	}
	result, err := queryProjection(projection, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	assertCurrency(t, result.Current.Currencies, "CDF", "1000", "100", "900", "1", "1000")
	if !hasCue(result.ActionRequired, CueLifecycleConflict) {
		t.Fatalf("refund/void conflict was not actionable: %#v", result.ActionRequired)
	}

	predatingRefund := testEvent(t, "018f0000-0000-7000-8000-000000000205", KindRefund, "100", "CDF", "orange-money", "refund-before-capture-time", capture.ID, "2026-11-01T04:57:00Z", "2026-11-01T05:50:00Z")
	predatingReconciliation := testEvent(t, "018f0000-0000-7000-8000-000000000206", KindReconciled, "0", "CDF", "orange-money", "reconcile-before-capture-time", capture.ID, "2026-11-01T04:58:00Z", "2026-11-01T05:51:00Z")
	predatingVoid := testEvent(t, "018f0000-0000-7000-8000-000000000207", KindVoid, "1000", "CDF", "orange-money", "void-before-capture-time", capture.ID, "2026-11-01T04:59:00Z", "2026-11-01T05:52:00Z")
	projection, err = Rebuild("tenant-demo", []LedgerEvent{predatingRefund, predatingReconciliation, predatingVoid, capture})
	if err != nil {
		t.Fatal(err)
	}
	result, err = queryProjection(projection, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	assertCurrency(t, result.Current.Currencies, "CDF", "1000", "0", "1000", "1", "1000")
	if result.Reconciliation.UnreconciledCount != "1" || !hasCue(result.ActionRequired, CueLifecycleConflict) {
		t.Fatalf("predating corrections changed capture state: %#v %#v", result.Reconciliation, result.ActionRequired)
	}

	validVoid := testEvent(t, "018f0000-0000-7000-8000-000000000208", KindVoid, "1000", "CDF", "orange-money", "out-of-order-void", capture.ID, "2026-11-01T05:20:00Z", "2026-11-01T05:20:01Z")
	projection, err = Rebuild("tenant-demo", []LedgerEvent{validVoid, capture})
	if err != nil {
		t.Fatal(err)
	}
	result, err = queryProjection(projection, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Current.Currencies) != 0 || hasCue(result.ActionRequired, CueLifecycleConflict) {
		t.Fatalf("arrival-order-only void was rejected: %#v", result)
	}

	validReconciliation := testEvent(t, "018f0000-0000-7000-8000-000000000209", KindReconciled, "0", "CDF", "orange-money", "out-of-order-reconciliation", capture.ID, "2026-11-01T05:20:00Z", "2026-11-01T05:20:01Z")
	projection, err = Rebuild("tenant-demo", []LedgerEvent{validReconciliation, capture})
	if err != nil {
		t.Fatal(err)
	}
	result, err = queryProjection(projection, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	if result.Reconciliation.UnreconciledCount != "0" || hasCue(result.ActionRequired, CueLifecycleConflict) {
		t.Fatalf("arrival-order-only reconciliation was rejected: %#v", result)
	}
}

func TestDuplicateEventReplayAndConflict(t *testing.T) {
	t.Parallel()
	events := vectorEvents(t)
	events = append(events, events[0])
	projection, err := Rebuild("tenant-demo", events)
	if err != nil {
		t.Fatalf("exact replay: %v", err)
	}
	changed := events[0]
	changed.Amount = mustAmount(t, "999")
	if _, err := Rebuild("tenant-demo", append(events, changed)); !errors.Is(err, ErrEventConflict) {
		t.Fatalf("same supplied digest with changed payload: %v", err)
	}
	changed.ID = "018f0000-0000-7000-8000-000000000099"
	if _, err := Rebuild("tenant-demo", []LedgerEvent{changed}); !errors.Is(err, ErrInvalidEvent) {
		t.Fatalf("unverified supplied digest: %v", err)
	}
	if projection.EventCount() != uint32(len(events)-1) {
		t.Fatalf("event count includes replay: %d", projection.EventCount())
	}
}

func TestRebuildRevalidatesAdapterEventsAndEmptyProjectionDoesNotInventFreshness(t *testing.T) {
	t.Parallel()
	invalid := vectorEvents(t)[0]
	invalid.Currency = "cdf"
	if _, err := Rebuild("tenant-demo", []LedgerEvent{invalid}); !errors.Is(err, ErrInvalidEvent) {
		t.Fatalf("adapter bypassed domain validation: %v", err)
	}
	empty, err := Rebuild("tenant-demo", nil)
	if err != nil {
		t.Fatal(err)
	}
	query := DashboardQuery{SnapshotAt: mustTime(t, "2026-11-02T12:00:00Z"), From: mustTime(t, "2026-11-01T04:00:00Z"), To: mustTime(t, "2026-11-02T05:00:00Z"), Interval: IntervalDay, TimeZone: "America/New_York"}
	dashboard, err := queryProjection(empty, "tenant-demo", query)
	if err != nil {
		t.Fatal(err)
	}
	if dashboard.Sync.Status != "no_events" || dashboard.Sync.LastReceivedAt != nil || dashboard.Sync.FreshnessSeconds != "" || hasCue(dashboard.ActionRequired, CueStaleSync) {
		t.Fatalf("empty projection invented sync freshness: %#v", dashboard.Sync)
	}
}

func TestTenantScopeAndBoundsFailClosed(t *testing.T) {
	t.Parallel()
	events := vectorEvents(t)
	if _, err := Rebuild("tenant-other", events); !errors.Is(err, ErrTenantScope) {
		t.Fatalf("cross-tenant rebuild: %v", err)
	}
	projection, err := Rebuild("tenant-demo", events)
	if err != nil {
		t.Fatal(err)
	}
	query := DashboardQuery{SnapshotAt: mustTime(t, "2026-11-02T12:00:00Z"), From: mustTime(t, "2026-11-01T04:00:00Z"), To: mustTime(t, "2026-11-02T05:00:00Z"), Interval: IntervalDay, TimeZone: "America/New_York"}
	if _, err := queryProjection(projection, "tenant-other", query); !errors.Is(err, ErrTenantScope) {
		t.Fatalf("cross-tenant query: %v", err)
	}
	query.To = query.From.Add(MaximumQueryWindow + time.Second)
	if _, err := queryProjection(projection, "tenant-demo", query); !errors.Is(err, ErrQueryBounds) {
		t.Fatalf("oversized window: %v", err)
	}
	unique := make([]LedgerEvent, 0, MaximumProjectionEvents+1)
	for index := 0; index <= MaximumProjectionEvents; index++ {
		id := fmt.Sprintf("018f0000-0000-7000-8000-%012d", index+1)
		unique = append(unique, testEvent(t, id, KindCapture, "1", "CDF", "provider", fmt.Sprintf("payment-%d", index), "", "2026-11-01T05:30:00Z", "2026-11-01T05:30:01Z"))
	}
	if _, err := Rebuild("tenant-demo", unique); !errors.Is(err, ErrProjectionBounds) {
		t.Fatalf("unique event cardinality: %v", err)
	}
	raw := make([]LedgerEvent, MaximumRawProjectionEvents+1)
	for index := range raw {
		raw[index] = events[0]
	}
	if _, err := Rebuild("tenant-demo", raw); !errors.Is(err, ErrProjectionBounds) {
		t.Fatalf("raw replay work bound: %v", err)
	}
}

func TestProviderCardinalityIsBoundedBeforeProjectionPublication(t *testing.T) {
	t.Parallel()
	events := make([]LedgerEvent, 0, ProviderCardinalityMax+1)
	for index := 0; index <= ProviderCardinalityMax; index++ {
		id := fmt.Sprintf("018f0000-0000-7000-8000-%012d", index+1)
		events = append(events, testEvent(t, id, KindCapture, "1", "CDF", fmt.Sprintf("provider-%02d", index), fmt.Sprintf("payment-%02d", index), "", "2026-11-01T05:30:00Z", "2026-11-01T05:30:01Z"))
	}
	if _, err := Rebuild("tenant-demo", events); !errors.Is(err, ErrProjectionBounds) {
		t.Fatalf("provider cardinality: %v", err)
	}
}

func TestApplicationRebuildPermitsBoundedRawReplayWorkAfterDeduplication(t *testing.T) {
	t.Parallel()
	event := vectorEvents(t)[0]
	replays := make([]LedgerEvent, MaximumRawProjectionEvents)
	for index := range replays {
		replays[index] = event
	}
	repository := &memoryProjectionRepository{}
	if err := NewRebuilder(&pagedEventSource{events: replays}, repository).Rebuild(context.Background(), "tenant-demo"); err != nil {
		t.Fatal(err)
	}
	if repository.projection.EventCount() != 1 {
		t.Fatalf("deduplicated events = %d, want 1", repository.projection.EventCount())
	}
}

func TestApplicationRebuildDoesNotPublishPartialProjectionAfterSourceCrash(t *testing.T) {
	t.Parallel()
	source := &pagedEventSource{events: vectorEvents(t), failPage: 2}
	repository := &memoryProjectionRepository{}
	rebuilder := NewRebuilder(source, repository)
	if err := rebuilder.Rebuild(context.Background(), "tenant-demo"); !errors.Is(err, ErrProjectionUnavailable) {
		t.Fatalf("source crash: %v", err)
	}
	if repository.replaceCount != 0 {
		t.Fatal("partial projection was published")
	}
	source.failPage = 0
	if err := rebuilder.Rebuild(context.Background(), "tenant-demo"); err != nil {
		t.Fatal(err)
	}
	first := repository.projection.Version()
	if err := rebuilder.Rebuild(context.Background(), "tenant-demo"); err != nil {
		t.Fatal(err)
	}
	if repository.projection.Version() != first {
		t.Fatal("replay changed projection version")
	}
}

func TestRebuildRejectsSnapshotDriftAndAnySeenCursorCycle(t *testing.T) {
	t.Parallel()
	for name, source := range map[string]*pagedEventSource{
		"snapshot drift": {events: vectorEvents(t), driftPage: 2},
		"cursor cycle":   {events: vectorEvents(t), cyclePage: 2},
	} {
		t.Run(name, func(t *testing.T) {
			repository := &memoryProjectionRepository{}
			if err := NewRebuilder(source, repository).Rebuild(context.Background(), "tenant-demo"); !errors.Is(err, ErrProjectionUnavailable) {
				t.Fatalf("unstable source: %v", err)
			}
			if repository.replaceCount != 0 {
				t.Fatal("unstable source published projection")
			}
		})
	}
}

func TestConcurrentSlowOldRebuildCannotReplaceFastNewSnapshot(t *testing.T) {
	t.Parallel()
	events := vectorEvents(t)
	repository := &memoryProjectionRepository{}
	oldSource := &blockingEventSource{pagedEventSource: &pagedEventSource{events: events[:1], snapshot: SourceSnapshot{Generation: 1, Token: "snapshot-old"}}, entered: make(chan struct{}), release: make(chan struct{})}
	oldResult := make(chan error, 1)
	go func() { oldResult <- NewRebuilder(oldSource, repository).Rebuild(context.Background(), "tenant-demo") }()
	select {
	case <-oldSource.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("old rebuild did not block")
	}
	newSource := &pagedEventSource{events: events, snapshot: SourceSnapshot{Generation: 2, Token: "snapshot-new"}}
	if err := NewRebuilder(newSource, repository).Rebuild(context.Background(), "tenant-demo"); err != nil {
		t.Fatalf("fast new rebuild: %v", err)
	}
	close(oldSource.release)
	if err := <-oldResult; !errors.Is(err, ErrStaleProjection) {
		t.Fatalf("slow old rebuild: %v", err)
	}
	expected, _ := Rebuild("tenant-demo", events)
	if repository.generation != 2 || repository.projection.Version() != expected.Version() {
		t.Fatal("older rebuild replaced newer projection")
	}
}
