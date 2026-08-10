package analytics

import (
	"context"
	"errors"
	"time"
)

type Clock interface{ Now() time.Time }

type DashboardService struct{ clock Clock }

func NewDashboardService(clock Clock) DashboardService {
	if clock == nil {
		panic("analytics: nil dashboard clock")
	}
	return DashboardService{clock: clock}
}

func (service DashboardService) Query(ctx context.Context, projection SalesProjection, tenantID string, query DashboardQuery) (Dashboard, error) {
	if err := ctx.Err(); err != nil {
		return Dashboard{}, ErrProjectionUnavailable
	}
	observedAt := service.clock.Now().UTC().Truncate(time.Second)
	return projection.dashboard(tenantID, query, observedAt)
}

type EventCursor string

type SourceSnapshot struct {
	Generation uint64
	Token      string
}

type EventPage struct {
	Events   []LedgerEvent
	Next     EventCursor
	Snapshot SourceSnapshot
}

type LedgerEventSource interface {
	OpenSnapshot(ctx context.Context, tenantID string) (SourceSnapshot, error)
	List(ctx context.Context, tenantID string, snapshot SourceSnapshot, cursor EventCursor, limit uint16) (EventPage, error)
}

type ProjectionRepository interface {
	// Replace publishes the complete rebuild atomically. A caller crash or source
	// failure before this call must leave the previously ready projection intact.
	// Replace performs a generation CAS: older generations are rejected, equal
	// generations are idempotent only for the exact same projection version.
	Replace(ctx context.Context, tenantID string, snapshot SourceSnapshot, projection SalesProjection) error
}

type Rebuilder struct {
	source     LedgerEventSource
	repository ProjectionRepository
}

func NewRebuilder(source LedgerEventSource, repository ProjectionRepository) Rebuilder {
	if source == nil || repository == nil {
		panic("analytics: nil rebuild port")
	}
	return Rebuilder{source: source, repository: repository}
}

func (rebuilder Rebuilder) Rebuild(ctx context.Context, tenantID string) error {
	snapshot, err := rebuilder.source.OpenSnapshot(ctx, tenantID)
	if err != nil || snapshot.Generation == 0 || !validIdentifier(snapshot.Token, 128) {
		return ErrProjectionUnavailable
	}
	events := make([]LedgerEvent, 0, ProjectionPageSize)
	var cursor EventCursor
	seenCursors := map[EventCursor]struct{}{cursor: {}}
	for pageNumber := uint16(0); pageNumber < MaximumProjectionPages; pageNumber++ {
		page, err := rebuilder.source.List(ctx, tenantID, snapshot, cursor, ProjectionPageSize)
		if err != nil {
			return ErrProjectionUnavailable
		}
		if page.Snapshot != snapshot {
			return ErrProjectionUnavailable
		}
		if len(page.Events) > int(ProjectionPageSize) || len(events)+len(page.Events) > MaximumRawProjectionEvents {
			return ErrProjectionBounds
		}
		events = append(events, page.Events...)
		if page.Next == "" {
			projection, err := Rebuild(tenantID, events)
			if err != nil {
				return err
			}
			if err := rebuilder.repository.Replace(ctx, tenantID, snapshot, projection); err != nil {
				if errors.Is(err, ErrStaleProjection) {
					return ErrStaleProjection
				}
				return ErrProjectionUnavailable
			}
			return nil
		}
		if len(page.Next) == 0 || len(page.Next) > 128 {
			return ErrProjectionUnavailable
		}
		if _, seen := seenCursors[page.Next]; seen {
			return ErrProjectionUnavailable
		}
		seenCursors[page.Next] = struct{}{}
		cursor = page.Next
	}
	return ErrProjectionBounds
}
