package analytics

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"regexp"
	"time"
)

const (
	AnalyticsContractVersion          = "sales-analytics-v1"
	MaximumProjectionEvents           = 10_000
	MaximumRawProjectionEvents        = 20_000
	MaximumQueryWindow                = 93 * 24 * time.Hour
	MinimumQueryWindow                = time.Minute
	MaximumSeriesBuckets              = 500
	ProjectionPageSize         uint16 = 3
	MaximumProjectionPages     uint16 = 6_667
	ProviderCardinalityMax            = 64
	CurrencyCardinalityMax            = 16
	ReconciliationOverdueAfter        = 24 * time.Hour
	SyncStaleAfter                    = 15 * time.Minute
	LateArrivalAfter                  = time.Hour
)

var (
	ErrEventConflict          = errors.New("analytics event identity conflict")
	ErrInvalidEvent           = errors.New("invalid analytics ledger event")
	ErrProjectionBounds       = errors.New("analytics projection bounds exceeded")
	ErrProjectionNotReady     = errors.New("analytics projection not ready")
	ErrProjectionUnavailable  = errors.New("analytics projection unavailable")
	ErrStaleProjection        = errors.New("analytics stale projection generation")
	ErrQueryBounds            = errors.New("analytics query bounds exceeded")
	ErrTenantScope            = errors.New("analytics tenant scope violation")
	eventIDPattern            = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	identifierPattern         = regexp.MustCompile(`^[A-Za-z0-9._:-]+$`)
	canonicalTimestampPattern = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`)
)

type EventKind string

const (
	KindCapture    EventKind = "payment_captured"
	KindRefund     EventKind = "payment_refunded"
	KindVoid       EventKind = "payment_voided"
	KindReconciled EventKind = "payment_reconciled"
)

type Interval string

const (
	IntervalHour Interval = "hour"
	IntervalDay  Interval = "day"
)

type CueKind string

const (
	CueCorrectionAfterVoid   CueKind = "correction_after_void"
	CueLifecycleConflict     CueKind = "lifecycle_conflict"
	CueCorrectionMismatch    CueKind = "correction_mismatch"
	CueLateArrival           CueKind = "late_arrival"
	CueOrphanCorrection      CueKind = "orphan_correction"
	CueOverRefund            CueKind = "over_refund"
	CueReconciliationOverdue CueKind = "reconciliation_overdue"
	CueStaleSync             CueKind = "stale_sync"
)

type ReadinessState string

const (
	ReadinessReady ReadinessState = "ready"
)

type MinorAmount struct {
	digits [20]byte
	length uint8
}

func ParseMinorAmount(value string) (MinorAmount, error) {
	if len(value) == 0 || len(value) > 20 {
		return MinorAmount{}, ErrInvalidEvent
	}
	if value != "0" && value[0] == '0' {
		return MinorAmount{}, ErrInvalidEvent
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return MinorAmount{}, ErrInvalidEvent
		}
	}
	var amount MinorAmount
	copy(amount.digits[:], value)
	amount.length = uint8(len(value))
	return amount, nil
}
func (amount MinorAmount) String() string { return string(amount.digits[:amount.length]) }
func (amount MinorAmount) IsZero() bool   { return amount.length == 1 && amount.digits[0] == '0' }

type EventDigest [sha256.Size]byte

type EventInput struct {
	ID             string
	TenantID       string
	Kind           EventKind
	Amount         string
	Currency       string
	Provider       string
	PaymentID      string
	RelatedEventID string
	OccurredAt     time.Time
	ReceivedAt     time.Time
	Digest         EventDigest
}

type LedgerEvent struct {
	ID             string
	TenantID       string
	Kind           EventKind
	Amount         MinorAmount
	Currency       string
	Provider       string
	PaymentID      string
	RelatedEventID string
	OccurredAt     time.Time
	ReceivedAt     time.Time
	Digest         EventDigest
}

func NewLedgerEvent(input EventInput) (LedgerEvent, error) {
	amount, err := ParseMinorAmount(input.Amount)
	if err != nil {
		return LedgerEvent{}, err
	}
	if !eventIDPattern.MatchString(input.ID) || !validIdentifier(input.TenantID, 128) || !validIdentifier(input.Provider, 128) || !validIdentifier(input.PaymentID, 128) {
		return LedgerEvent{}, ErrInvalidEvent
	}
	if len(input.Currency) != 3 {
		return LedgerEvent{}, ErrInvalidEvent
	}
	for _, c := range input.Currency {
		if c < 'A' || c > 'Z' {
			return LedgerEvent{}, ErrInvalidEvent
		}
	}
	if !canonicalSecond(input.OccurredAt) || !canonicalSecond(input.ReceivedAt) || input.ReceivedAt.Before(input.OccurredAt) {
		return LedgerEvent{}, ErrInvalidEvent
	}
	if input.Digest == (EventDigest{}) {
		return LedgerEvent{}, ErrInvalidEvent
	}
	switch input.Kind {
	case KindCapture:
		if amount.IsZero() || input.RelatedEventID != "" {
			return LedgerEvent{}, ErrInvalidEvent
		}
	case KindRefund, KindVoid:
		if amount.IsZero() || !eventIDPattern.MatchString(input.RelatedEventID) {
			return LedgerEvent{}, ErrInvalidEvent
		}
	case KindReconciled:
		if !amount.IsZero() || !eventIDPattern.MatchString(input.RelatedEventID) {
			return LedgerEvent{}, ErrInvalidEvent
		}
	default:
		return LedgerEvent{}, ErrInvalidEvent
	}
	event := LedgerEvent{ID: input.ID, TenantID: input.TenantID, Kind: input.Kind, Amount: amount, Currency: input.Currency, Provider: input.Provider, PaymentID: input.PaymentID, RelatedEventID: input.RelatedEventID, OccurredAt: input.OccurredAt, ReceivedAt: input.ReceivedAt, Digest: input.Digest}
	if err := validateLedgerEvent(event); err != nil {
		return LedgerEvent{}, err
	}
	return event, nil
}

func CanonicalEventDigest(input EventInput) (EventDigest, error) {
	amount, err := ParseMinorAmount(input.Amount)
	if err != nil {
		return EventDigest{}, err
	}
	event := LedgerEvent{ID: input.ID, TenantID: input.TenantID, Kind: input.Kind, Amount: amount, Currency: input.Currency, Provider: input.Provider, PaymentID: input.PaymentID, RelatedEventID: input.RelatedEventID, OccurredAt: input.OccurredAt, ReceivedAt: input.ReceivedAt, Digest: EventDigest{1}}
	if err := validateLedgerEventStructure(event); err != nil {
		return EventDigest{}, err
	}
	return recomputeEventDigest(event), nil
}

func validateLedgerEvent(event LedgerEvent) error {
	if err := validateLedgerEventStructure(event); err != nil {
		return err
	}
	if event.Digest == (EventDigest{}) || recomputeEventDigest(event) != event.Digest {
		return ErrInvalidEvent
	}
	return nil
}

func validateLedgerEventStructure(event LedgerEvent) error {
	if !eventIDPattern.MatchString(event.ID) || !validIdentifier(event.TenantID, 128) || !validIdentifier(event.Provider, 128) || !validIdentifier(event.PaymentID, 128) || event.Amount.length == 0 {
		return ErrInvalidEvent
	}
	if len(event.Currency) != 3 || !canonicalSecond(event.OccurredAt) || !canonicalSecond(event.ReceivedAt) || event.ReceivedAt.Before(event.OccurredAt) {
		return ErrInvalidEvent
	}
	for _, character := range event.Currency {
		if character < 'A' || character > 'Z' {
			return ErrInvalidEvent
		}
	}
	switch event.Kind {
	case KindCapture:
		if event.Amount.IsZero() || event.RelatedEventID != "" {
			return ErrInvalidEvent
		}
	case KindRefund, KindVoid:
		if event.Amount.IsZero() || !eventIDPattern.MatchString(event.RelatedEventID) {
			return ErrInvalidEvent
		}
	case KindReconciled:
		if !event.Amount.IsZero() || !eventIDPattern.MatchString(event.RelatedEventID) {
			return ErrInvalidEvent
		}
	default:
		return ErrInvalidEvent
	}
	return nil
}

func recomputeEventDigest(event LedgerEvent) EventDigest {
	payload := struct {
		AmountMinor    string    `json:"amount_minor"`
		Currency       string    `json:"currency"`
		EventID        string    `json:"event_id"`
		Kind           EventKind `json:"kind"`
		OccurredAt     string    `json:"occurred_at"`
		PaymentID      string    `json:"payment_id"`
		Provider       string    `json:"provider"`
		ReceivedAt     string    `json:"received_at"`
		RelatedEventID string    `json:"related_event_id,omitempty"`
		TenantID       string    `json:"tenant_id"`
	}{event.Amount.String(), event.Currency, event.ID, event.Kind, event.OccurredAt.Format(time.RFC3339), event.PaymentID, event.Provider, event.ReceivedAt.Format(time.RFC3339), event.RelatedEventID, event.TenantID}
	encoded, err := json.Marshal(payload)
	if err != nil {
		panic("analytics: bounded canonical event JSON failed")
	}
	return sha256.Sum256(encoded)
}

func validIdentifier(value string, maximum int) bool {
	return len(value) > 0 && len(value) <= maximum && identifierPattern.MatchString(value)
}
func canonicalSecond(value time.Time) bool {
	return value.Location() == time.UTC && value.Nanosecond() == 0
}

func ParseCanonicalTimestamp(value string) (time.Time, error) {
	if !canonicalTimestampPattern.MatchString(value) {
		return time.Time{}, ErrInvalidEvent
	}
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil || parsed.Format(time.RFC3339) != value {
		return time.Time{}, ErrInvalidEvent
	}
	return parsed, nil
}

type DashboardQuery struct {
	SnapshotAt time.Time
	From       time.Time
	To         time.Time
	Interval   Interval
	TimeZone   string
	Comparison bool
}

type CurrencyMetrics struct {
	Currency           string `json:"currency"`
	GrossMinor         string `json:"gross_minor"`
	RefundsMinor       string `json:"refunds_minor"`
	NetMinor           string `json:"net_minor"`
	PaymentCount       string `json:"payment_count"`
	RefundCount        string `json:"refund_count"`
	AverageTicketMinor string `json:"average_ticket_minor"`
}

type ProviderMetrics struct {
	Provider   string            `json:"provider"`
	Currencies []CurrencyMetrics `json:"currencies"`
}

type WindowMetrics struct {
	From       time.Time         `json:"from"`
	To         time.Time         `json:"to"`
	Currencies []CurrencyMetrics `json:"currencies"`
	Providers  []ProviderMetrics `json:"providers"`
}

type SeriesBucket = WindowMetrics

type ReconciliationMetrics struct {
	LagSecondsMax     string `json:"lag_seconds_max"`
	UnreconciledCount string `json:"unreconciled_count"`
}

type SyncMetrics struct {
	Status           string     `json:"status"`
	LastReceivedAt   *time.Time `json:"last_received_at,omitempty"`
	FreshnessSeconds string     `json:"freshness_seconds,omitempty"`
}

type ActionCue struct {
	Kind   CueKind `json:"kind"`
	Count  string  `json:"count"`
	Action string  `json:"action"`
}

type Dashboard struct {
	ContractVersion   string                `json:"contract_version"`
	ProjectionVersion string                `json:"projection_version"`
	Readiness         ReadinessState        `json:"readiness"`
	TenantID          string                `json:"tenant_id"`
	SnapshotAt        time.Time             `json:"snapshot_at"`
	ObservedAt        time.Time             `json:"observed_at"`
	TimeZone          string                `json:"time_zone"`
	Current           WindowMetrics         `json:"current"`
	Comparison        *WindowMetrics        `json:"comparison,omitempty"`
	Series            []SeriesBucket        `json:"series"`
	Reconciliation    ReconciliationMetrics `json:"reconciliation"`
	Sync              SyncMetrics           `json:"sync"`
	ActionRequired    []ActionCue           `json:"action_required"`
	ETag              string                `json:"etag"`
}
