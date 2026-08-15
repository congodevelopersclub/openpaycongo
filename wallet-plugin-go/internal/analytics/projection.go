package analytics

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"sort"
	"strconv"
	"time"
)

type SalesProjection struct {
	tenantID string
	events   []LedgerEvent
	version  string
}

func Rebuild(tenantID string, input []LedgerEvent) (SalesProjection, error) {
	if !validIdentifier(tenantID, 128) {
		return SalesProjection{}, ErrTenantScope
	}
	if len(input) > MaximumRawProjectionEvents {
		return SalesProjection{}, ErrProjectionBounds
	}
	byID := make(map[string]LedgerEvent, len(input))
	providers := make(map[string]struct{})
	currencies := make(map[string]struct{})
	for _, event := range input {
		if existing, found := byID[event.ID]; found {
			if existing.Digest != event.Digest || existing != event {
				return SalesProjection{}, ErrEventConflict
			}
			continue
		}
		if err := validateLedgerEvent(event); err != nil {
			return SalesProjection{}, err
		}
		if event.TenantID != tenantID {
			return SalesProjection{}, ErrTenantScope
		}
		byID[event.ID] = event
		if len(byID) > MaximumProjectionEvents {
			return SalesProjection{}, ErrProjectionBounds
		}
		providers[event.Provider] = struct{}{}
		currencies[event.Currency] = struct{}{}
		if len(providers) > ProviderCardinalityMax || len(currencies) > CurrencyCardinalityMax {
			return SalesProjection{}, ErrProjectionBounds
		}
	}
	events := make([]LedgerEvent, 0, len(byID))
	for _, event := range byID {
		events = append(events, event)
	}
	sort.Slice(events, func(i, j int) bool { return events[i].ID < events[j].ID })
	return SalesProjection{tenantID: tenantID, events: events, version: projectionVersion(events)}, nil
}

func projectionVersion(events []LedgerEvent) string {
	hash := sha256.New()
	for _, event := range events {
		hash.Write([]byte(event.ID))
		hash.Write(event.Digest[:])
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func (projection SalesProjection) TenantID() string   { return projection.tenantID }
func (projection SalesProjection) Version() string    { return projection.version }
func (projection SalesProjection) EventCount() uint32 { return uint32(len(projection.events)) }
func (projection SalesProjection) Events() []LedgerEvent {
	return append([]LedgerEvent(nil), projection.events...)
}

func (projection SalesProjection) dashboard(tenantID string, query DashboardQuery, observedAt time.Time) (Dashboard, error) {
	if projection.version == "" {
		return Dashboard{}, ErrProjectionNotReady
	}
	if tenantID != projection.tenantID {
		return Dashboard{}, ErrTenantScope
	}
	location, buckets, err := validateQuery(query, observedAt)
	if err != nil {
		return Dashboard{}, err
	}
	visibleEvents := make([]LedgerEvent, 0, len(projection.events))
	watermark := time.Time{}
	for _, event := range projection.events {
		if event.ReceivedAt.After(query.SnapshotAt) {
			continue
		}
		visibleEvents = append(visibleEvents, event)
		if event.ReceivedAt.After(watermark) {
			watermark = event.ReceivedAt
		}
	}
	state := deriveState(visibleEvents)
	visibleVersion := projectionVersion(visibleEvents)
	current := state.window(query.From, query.To)
	current.From, current.To = query.From, query.To
	series := make([]SeriesBucket, 0, len(buckets)-1)
	for index := 0; index+1 < len(buckets); index++ {
		bucket := state.window(buckets[index], buckets[index+1])
		bucket.From, bucket.To = buckets[index], buckets[index+1]
		series = append(series, bucket)
	}
	result := Dashboard{ContractVersion: AnalyticsContractVersion, ProjectionVersion: visibleVersion, Readiness: ReadinessReady, TenantID: tenantID, SnapshotAt: query.SnapshotAt, ObservedAt: observedAt, TimeZone: location.String(), Current: current, Series: series}
	if query.Comparison {
		duration := query.To.Sub(query.From)
		comparison := state.window(query.From.Add(-duration), query.From)
		comparison.From, comparison.To = query.From.Add(-duration), query.From
		result.Comparison = &comparison
	}
	result.Reconciliation = state.reconciliation(query.From, query.To, query.SnapshotAt)
	result.Sync = syncMetrics(watermark, observedAt)
	result.ActionRequired = state.cues(query.From, query.To, query.SnapshotAt, result.Sync)
	result.ETag = dashboardETag(result)
	return result, nil
}

func validateQuery(query DashboardQuery, observedAt time.Time) (*time.Location, []time.Time, error) {
	if !canonicalSecond(query.SnapshotAt) || !canonicalSecond(observedAt) || !canonicalSecond(query.From) || !canonicalSecond(query.To) || !query.From.Before(query.To) || query.To.After(query.SnapshotAt) || query.SnapshotAt.After(observedAt) {
		return nil, nil, ErrQueryBounds
	}
	duration := query.To.Sub(query.From)
	if duration < MinimumQueryWindow || duration > MaximumQueryWindow || len(query.TimeZone) == 0 || len(query.TimeZone) > 64 {
		return nil, nil, ErrQueryBounds
	}
	if query.Interval != IntervalHour && query.Interval != IntervalDay {
		return nil, nil, ErrQueryBounds
	}
	location, err := time.LoadLocation(query.TimeZone)
	if err != nil {
		return nil, nil, ErrQueryBounds
	}
	buckets := []time.Time{query.From}
	for len(buckets) <= MaximumSeriesBuckets {
		current := buckets[len(buckets)-1]
		var next time.Time
		if query.Interval == IntervalHour {
			next = current.Add(time.Hour)
		} else {
			local := current.In(location)
			next = time.Date(local.Year(), local.Month(), local.Day()+1, 0, 0, 0, 0, location).UTC()
		}
		if !next.Before(query.To) {
			buckets = append(buckets, query.To)
			return location, buckets, nil
		}
		if !next.After(current) {
			return nil, nil, ErrQueryBounds
		}
		buckets = append(buckets, next)
	}
	return nil, nil, ErrQueryBounds
}

type derivedState struct {
	captures             map[string]LedgerEvent
	refunds              []LedgerEvent
	voided               map[string]struct{}
	reconciled           map[string]LedgerEvent
	orphans              uint64
	overRefunds          uint64
	correctionMismatches uint64
	correctionsAfterVoid uint64
	lifecycleConflicts   uint64
	events               []LedgerEvent
}

func deriveState(events []LedgerEvent) derivedState {
	state := derivedState{captures: map[string]LedgerEvent{}, voided: map[string]struct{}{}, reconciled: map[string]LedgerEvent{}, events: events}
	for _, event := range events {
		if event.Kind == KindCapture {
			state.captures[event.ID] = event
		}
	}
	corrections := map[string][]LedgerEvent{}
	for _, event := range events {
		if event.Kind == KindCapture {
			continue
		}
		capture, found := state.captures[event.RelatedEventID]
		if !found {
			state.orphans++
			continue
		}
		if event.OccurredAt.Before(capture.OccurredAt) {
			state.lifecycleConflicts++
			continue
		}
		if capture.Currency != event.Currency || capture.Provider != event.Provider {
			state.correctionMismatches++
			continue
		}
		if event.Kind == KindVoid && capture.Amount != event.Amount {
			state.correctionMismatches++
			continue
		}
		corrections[event.RelatedEventID] = append(corrections[event.RelatedEventID], event)
	}
	refundTotals := map[string]*big.Int{}
	for captureID, captureCorrections := range corrections {
		sort.Slice(captureCorrections, func(left, right int) bool {
			if captureCorrections[left].OccurredAt.Equal(captureCorrections[right].OccurredAt) {
				return captureCorrections[left].ID < captureCorrections[right].ID
			}
			return captureCorrections[left].OccurredAt.Before(captureCorrections[right].OccurredAt)
		})
		lifecycleBlocked := false
		voided := false
		for _, event := range captureCorrections {
			if lifecycleBlocked {
				state.lifecycleConflicts++
				continue
			}
			if voided {
				state.correctionsAfterVoid++
				state.lifecycleConflicts++
				continue
			}
			switch event.Kind {
			case KindRefund:
				state.refunds = append(state.refunds, event)
				if refundTotals[captureID] == nil {
					refundTotals[captureID] = new(big.Int)
				}
				refundTotals[captureID].Add(refundTotals[captureID], amountInt(event.Amount))
			case KindVoid:
				if refundTotals[captureID] != nil && refundTotals[captureID].Sign() > 0 {
					state.lifecycleConflicts++
					lifecycleBlocked = true
					continue
				}
				state.voided[captureID] = struct{}{}
				voided = true
			case KindReconciled:
				if current, exists := state.reconciled[captureID]; !exists || event.ReceivedAt.Before(current.ReceivedAt) {
					state.reconciled[captureID] = event
				}
			}
		}
	}
	for captureID, total := range refundTotals {
		if total.Cmp(amountInt(state.captures[captureID].Amount)) > 0 {
			state.overRefunds++
		}
	}
	return state
}

type metricAccumulator struct {
	gross, refunds        *big.Int
	payments, refundCount uint64
}

func newAccumulator() *metricAccumulator {
	return &metricAccumulator{gross: new(big.Int), refunds: new(big.Int)}
}

func (state derivedState) window(from, to time.Time) WindowMetrics {
	byCurrency := map[string]*metricAccumulator{}
	byProvider := map[string]map[string]*metricAccumulator{}
	add := func(provider, currency string) (*metricAccumulator, *metricAccumulator) {
		if byCurrency[currency] == nil {
			byCurrency[currency] = newAccumulator()
		}
		if byProvider[provider] == nil {
			byProvider[provider] = map[string]*metricAccumulator{}
		}
		if byProvider[provider][currency] == nil {
			byProvider[provider][currency] = newAccumulator()
		}
		return byCurrency[currency], byProvider[provider][currency]
	}
	for id, event := range state.captures {
		if _, voided := state.voided[id]; voided || event.OccurredAt.Before(from) || !event.OccurredAt.Before(to) {
			continue
		}
		currency, provider := add(event.Provider, event.Currency)
		for _, target := range []*metricAccumulator{currency, provider} {
			target.gross.Add(target.gross, amountInt(event.Amount))
			target.payments++
		}
	}
	for _, event := range state.refunds {
		if event.OccurredAt.Before(from) || !event.OccurredAt.Before(to) {
			continue
		}
		currency, provider := add(event.Provider, event.Currency)
		for _, target := range []*metricAccumulator{currency, provider} {
			target.refunds.Add(target.refunds, amountInt(event.Amount))
			target.refundCount++
		}
	}
	return WindowMetrics{Currencies: renderCurrencies(byCurrency), Providers: renderProviders(byProvider)}
}

func renderCurrencies(values map[string]*metricAccumulator) []CurrencyMetrics {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]CurrencyMetrics, 0, len(keys))
	for _, currency := range keys {
		value := values[currency]
		net := new(big.Int).Sub(new(big.Int).Set(value.gross), value.refunds)
		result = append(result, CurrencyMetrics{Currency: currency, GrossMinor: value.gross.String(), RefundsMinor: value.refunds.String(), NetMinor: net.String(), PaymentCount: strconv.FormatUint(value.payments, 10), RefundCount: strconv.FormatUint(value.refundCount, 10), AverageTicketMinor: roundedAverage(value.gross, value.payments)})
	}
	return result
}

func renderProviders(values map[string]map[string]*metricAccumulator) []ProviderMetrics {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]ProviderMetrics, 0, len(keys))
	for _, key := range keys {
		result = append(result, ProviderMetrics{Provider: key, Currencies: renderCurrencies(values[key])})
	}
	return result
}

func roundedAverage(total *big.Int, count uint64) string {
	if count == 0 {
		return "0"
	}
	divisor := new(big.Int).SetUint64(count)
	quotient, remainder := new(big.Int), new(big.Int)
	quotient.QuoRem(total, divisor, remainder)
	if new(big.Int).Lsh(remainder, 1).Cmp(divisor) >= 0 {
		quotient.Add(quotient, big.NewInt(1))
	}
	return quotient.String()
}

func amountInt(amount MinorAmount) *big.Int {
	value, ok := new(big.Int).SetString(amount.String(), 10)
	if !ok {
		panic("analytics: validated minor amount became invalid")
	}
	return value
}

func (state derivedState) reconciliation(from, to, asOf time.Time) ReconciliationMetrics {
	var maximum int64
	var unreconciled uint64
	for id, capture := range state.captures {
		if _, voided := state.voided[id]; voided || capture.OccurredAt.Before(from) || !capture.OccurredAt.Before(to) {
			continue
		}
		end := asOf
		if reconciliation, found := state.reconciled[id]; found {
			end = reconciliation.ReceivedAt
		} else {
			unreconciled++
		}
		lag := int64(end.Sub(capture.ReceivedAt) / time.Second)
		if lag < 0 {
			lag = 0
		}
		if lag > maximum {
			maximum = lag
		}
	}
	return ReconciliationMetrics{LagSecondsMax: strconv.FormatInt(maximum, 10), UnreconciledCount: strconv.FormatUint(unreconciled, 10)}
}

func syncMetrics(watermark, asOf time.Time) SyncMetrics {
	if watermark.IsZero() {
		return SyncMetrics{Status: "no_events"}
	}
	seconds := int64(0)
	if !watermark.IsZero() && asOf.After(watermark) {
		seconds = int64(asOf.Sub(watermark) / time.Second)
	}
	status := "fresh"
	if seconds > int64(SyncStaleAfter/time.Second) {
		status = "stale"
	}
	return SyncMetrics{Status: status, LastReceivedAt: &watermark, FreshnessSeconds: strconv.FormatInt(seconds, 10)}
}

func (state derivedState) cues(from, to, asOf time.Time, sync SyncMetrics) []ActionCue {
	result := make([]ActionCue, 0, 5)
	add := func(kind CueKind, count uint64, action string) {
		if count > 0 {
			result = append(result, ActionCue{Kind: kind, Count: strconv.FormatUint(count, 10), Action: action})
		}
	}
	late := uint64(0)
	overdue := uint64(0)
	for _, event := range state.events {
		if !event.OccurredAt.Before(from) && event.OccurredAt.Before(to) && event.ReceivedAt.Sub(event.OccurredAt) > LateArrivalAfter {
			late++
		}
	}
	for id, capture := range state.captures {
		if _, voided := state.voided[id]; !voided && !capture.OccurredAt.Before(from) && capture.OccurredAt.Before(to) {
			if _, found := state.reconciled[id]; !found && asOf.Sub(capture.ReceivedAt) > ReconciliationOverdueAfter {
				overdue++
			}
		}
	}
	add(CueLateArrival, late, "review_offline_sync")
	add(CueCorrectionAfterVoid, state.correctionsAfterVoid, "review_correction_order")
	add(CueCorrectionMismatch, state.correctionMismatches, "review_correction_identity")
	add(CueLifecycleConflict, state.lifecycleConflicts, "review_correction_lifecycle")
	add(CueOrphanCorrection, state.orphans, "repair_event_linkage")
	add(CueOverRefund, state.overRefunds, "review_refund_total")
	add(CueReconciliationOverdue, overdue, "reconcile_provider")
	freshness, _ := strconv.ParseInt(sync.FreshnessSeconds, 10, 64)
	if sync.Status == "stale" && freshness > int64(SyncStaleAfter/time.Second) {
		add(CueStaleSync, 1, "check_replica_sync")
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Kind < result[j].Kind })
	return result
}

func dashboardETag(value Dashboard) string {
	value.ETag = ""
	encoded, err := json.Marshal(value)
	if err != nil {
		panic("analytics: bounded dashboard JSON failed")
	}
	var object map[string]any
	if err := json.Unmarshal(encoded, &object); err != nil {
		panic("analytics: bounded dashboard canonicalization failed")
	}
	delete(object, "etag")
	canonical, err := json.Marshal(object)
	if err != nil {
		panic("analytics: bounded dashboard canonical JSON failed")
	}
	digest := sha256.Sum256(canonical)
	return `"` + hex.EncodeToString(digest[:]) + `"`
}
