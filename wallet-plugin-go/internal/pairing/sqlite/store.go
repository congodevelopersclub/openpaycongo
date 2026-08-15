// Package sqlite is the durable, internal implementation of pairing.Repository.
package sqlite

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"sort"
	"sync"
	"time"

	"github.com/example/wallet-plugin-go/internal/pairing"
	_ "github.com/mattn/go-sqlite3"
)

const migrationRevision = "0004"

// Store serializes pairing's coupled lifecycle atomically in SQLite. It has no
// HTTP or issuer dependency; protected key bytes stay opaque to this adapter.
type Store struct {
	db *sql.DB
	mu sync.Mutex
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite3", path+"?_busy_timeout=5000&_foreign_keys=on")
	if err != nil {
		return nil, err
	}
	if err = db.PingContext(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (revision TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS pairing_repository_state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);
INSERT OR IGNORE INTO pairing_repository_state(id,payload) VALUES(1,'{}')`)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}
func (s *Store) Close() error              { return s.db.Close() }
func (s *Store) MigrationRevision() string { return migrationRevision }

type state struct {
	Intents map[string]*intent `json:"intents"`
	Devices map[string]*device `json:"devices"`
	Acks    map[string]string  `json:"acks"`
	Next    uint64             `json:"next"`
	Cursor  int                `json:"cursor"`
}
type intent struct {
	Pending      pending         `json:"pending"`
	Reservations map[string]bool `json:"reservations"`
	Aborted      bool            `json:"aborted"`
	Complete     *complete       `json:"complete,omitempty"`
	Confirmation *confirmation   `json:"confirmation,omitempty"`
}
type pending struct {
	Attempts                                               uint8 `json:"attempts"`
	Expires, Nonce, Protected, Fingerprint, Public, Tenant string
	Trust                                                  pairing.EnrollmentTrustMode
}
type complete struct {
	At, Reservation, Digest string
	Result                  result
	Device                  device
}
type result struct {
	Ciphertext, Device, Nonce string
	Status                    pairing.CompletionStatus
}
type device struct {
	Status                                          pairing.DeviceActivationStatus
	Signing, ID, Install, Root, Token, Code, Tenant string
}
type confirmation struct {
	Subject, Tenant, At, Request string
	Decision                     pairing.ConfirmationDecision
	Reason                       pairing.ConfirmationReason
}

func empty() state {
	return state{map[string]*intent{}, map[string]*device{}, map[string]string{}, 0, 0}
}
func key(v []byte) string            { return base64.RawURLEncoding.EncodeToString(v) }
func bytes(v string) ([]byte, error) { return base64.RawURLEncoding.DecodeString(v) }
func stamp(t time.Time) string       { return t.UTC().Format(time.RFC3339Nano) }
func parse(t string) time.Time       { v, _ := time.Parse(time.RFC3339Nano, t); return v }
func (s *Store) with(ctx context.Context, write bool, fn func(*state) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var raw []byte
	if err = tx.QueryRowContext(ctx, "SELECT payload FROM pairing_repository_state WHERE id=1").Scan(&raw); err != nil {
		return err
	}
	st := empty()
	if len(raw) > 0 && string(raw) != "{}" {
		if err = json.Unmarshal(raw, &st); err != nil {
			return err
		}
	}
	if st.Intents == nil {
		st = empty()
	}
	if err = fn(&st); err != nil {
		return err
	}
	if !write {
		return tx.Commit()
	}
	raw, err = json.Marshal(st)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE pairing_repository_state SET payload=? WHERE id=1", raw); err != nil {
		return err
	}
	return tx.Commit()
}
func pendingOf(p pairing.PendingEnrollment) pending {
	return pending{p.InvalidProofAttempts, stamp(p.ExpiresAt), key(p.IntentNonce[:]), key(p.ProtectedServerPrivateKey.Bytes()), key(p.EnrollmentSigningFingerprint[:]), key(p.ServerKeyAgreementPublic[:]), p.TenantID.String(), p.TrustMode}
}
func (p pending) domain() (pairing.PendingEnrollment, error) {
	var x pairing.PendingEnrollment
	b, e := bytes(p.Nonce)
	if e != nil || len(b) != 32 {
		return x, errors.New("invalid pairing sqlite pending")
	}
	copy(x.IntentNonce[:], b)
	b, e = bytes(p.Fingerprint)
	if e != nil || len(b) != 32 {
		return x, e
	}
	copy(x.EnrollmentSigningFingerprint[:], b)
	b, e = bytes(p.Public)
	if e != nil || len(b) != 32 {
		return x, e
	}
	copy(x.ServerKeyAgreementPublic[:], b)
	x.InvalidProofAttempts = p.Attempts
	x.ExpiresAt = parse(p.Expires)
	x.TrustMode = p.Trust
	x.TenantID, e = pairing.ParseTenantID(p.Tenant)
	if e != nil {
		return x, e
	}
	if p.Protected != "" {
		b, e = bytes(p.Protected)
		if e != nil {
			return x, e
		}
		x.ProtectedServerPrivateKey, e = pairing.NewProtectedMaterial(b)
	}
	return x, e
}
func deviceOf(d pairing.DeviceRecord) device {
	return device{d.ActivationStatus, key(d.DeviceSigningPublicKey[:]), key(d.ID[:]), d.InstallID, key(d.ProtectedInstallRoot.Bytes()), key(d.PairingStatusTokenDigest[:]), d.ShortAuthenticationCode.String(), d.TenantID.String()}
}
func resultOf(r pairing.CompletionResult) result {
	return result{key(r.Ciphertext), key(r.DeviceID[:]), key(r.Nonce[:]), r.Status}
}
func (r result) domain() (pairing.CompletionResult, error) {
	var x pairing.CompletionResult
	var e error
	x.Ciphertext, e = bytes(r.Ciphertext)
	if e != nil {
		return x, e
	}
	b, e := bytes(r.Device)
	if e != nil || len(b) != 16 {
		return x, errors.New("invalid pairing sqlite result")
	}
	copy(x.DeviceID[:], b)
	b, e = bytes(r.Nonce)
	if e != nil || len(b) != 12 {
		return x, e
	}
	copy(x.Nonce[:], b)
	x.Status = r.Status
	return x, nil
}
func (s *Store) Create(ctx context.Context, p pairing.PendingEnrollment) error {
	return s.with(ctx, true, func(st *state) error {
		k := key(p.ID[:])
		if _, ok := st.Intents[k]; ok {
			return pairing.ErrIntentCollision
		}
		st.Intents[k] = &intent{Pending: pendingOf(p), Reservations: map[string]bool{}}
		return nil
	})
}
func (s *Store) FindCompletion(ctx context.Context, id pairing.PairingIntentID, d pairing.RequestDigest) (pairing.CompletionResult, bool, error) {
	var out pairing.CompletionResult
	found := false
	err := s.with(ctx, false, func(st *state) error {
		v := st.Intents[key(id[:])]
		if v == nil || v.Complete == nil {
			return nil
		}
		if v.Complete.Digest != key(d[:]) {
			return pairing.ErrEnrollmentUnavailable
		}
		var e error
		out, e = v.Complete.Result.domain()
		if e == nil {
			out.Status = pairing.CompletionReplayed
			found = true
		}
		return e
	})
	return out, found, err
}
func terminal(v *intent) { v.Pending.Protected = ""; v.Reservations = nil; v.Aborted = true }
func (s *Store) BeginCompletionAttempt(ctx context.Context, id pairing.PairingIntentID, now time.Time, max, maxFlight uint8) (pairing.CompletionReservation, error) {
	var out pairing.CompletionReservation
	err := s.with(ctx, true, func(st *state) error {
		v := st.Intents[key(id[:])]
		if v == nil || v.Complete != nil || v.Aborted {
			return pairing.ErrEnrollmentUnavailable
		}
		p, e := v.Pending.domain()
		if e != nil {
			return e
		}
		p.ID = id
		if !now.Before(p.ExpiresAt) || p.InvalidProofAttempts >= max {
			terminal(v)
			return pairing.ErrEnrollmentUnavailable
		}
		if maxFlight == 0 || maxFlight > pairing.CompletionReservationsMax || len(v.Reservations) >= int(maxFlight) {
			return pairing.ErrEnrollmentUnavailable
		}
		st.Next++
		var rid pairing.CompletionReservationID
		for i := 0; i < 8; i++ {
			rid[15-i] = byte(st.Next >> (8 * i))
		}
		v.Reservations[key(rid[:])] = true
		out = pairing.CompletionReservation{Enrollment: p, ID: rid}
		return nil
	})
	return out, err
}
func (s *Store) ReleaseCompletionAttempt(ctx context.Context, id pairing.PairingIntentID, rid pairing.CompletionReservationID) error {
	return s.with(ctx, true, func(st *state) error {
		v := st.Intents[key(id[:])]
		if v == nil {
			return pairing.ErrEnrollmentUnavailable
		}
		if v.Complete != nil || v.Aborted {
			return nil
		}
		delete(v.Reservations, key(rid[:]))
		return nil
	})
}
func (s *Store) FinishFailedCompletion(ctx context.Context, id pairing.PairingIntentID, rid pairing.CompletionReservationID, at time.Time, max uint8) error {
	return s.with(ctx, true, func(st *state) error {
		v := st.Intents[key(id[:])]
		if v == nil {
			return pairing.ErrEnrollmentUnavailable
		}
		if v.Complete != nil || v.Aborted || !v.Reservations[key(rid[:])] {
			return nil
		}
		delete(v.Reservations, key(rid[:]))
		if v.Pending.Attempts < max {
			v.Pending.Attempts++
		}
		if !at.Before(parse(v.Pending.Expires)) || v.Pending.Attempts >= max {
			terminal(v)
		}
		return nil
	})
}
func (s *Store) AbortCompletion(ctx context.Context, id pairing.PairingIntentID, _ time.Time) error {
	return s.with(ctx, true, func(st *state) error {
		v := st.Intents[key(id[:])]
		if v == nil || v.Complete != nil {
			return pairing.ErrEnrollmentUnavailable
		}
		terminal(v)
		return nil
	})
}
func (s *Store) Commit(ctx context.Context, c pairing.CompletionCommit) (pairing.CommitOutcome, error) {
	out := pairing.CommitOutcome{State: pairing.CommitNotCommitted}
	err := s.with(ctx, true, func(st *state) error {
		k := key(c.IntentID[:])
		v := st.Intents[k]
		if v == nil {
			return pairing.ErrEnrollmentUnavailable
		}
		if v.Complete != nil {
			if v.Complete.Digest != key(c.RequestDigest[:]) {
				return pairing.ErrEnrollmentUnavailable
			}
			r, e := v.Complete.Result.domain()
			if e != nil {
				return e
			}
			r.Status = pairing.CompletionReplayed
			out = pairing.CommitOutcome{State: pairing.CommitCommitted, Result: r}
			return nil
		}
		if !c.CompletedAt.Before(parse(v.Pending.Expires)) || v.Pending.Attempts >= c.MaxAttempts || !v.Reservations[key(c.ReservationID[:])] {
			return pairing.ErrEnrollmentUnavailable
		}
		dk := key(c.Device.ID[:])
		if _, ok := st.Devices[dk]; ok {
			return pairing.ErrEnrollmentUnavailable
		}
		for _, old := range st.Devices {
			if old.Tenant == c.Device.TenantID.String() && old.Install == c.Device.InstallID {
				return pairing.ErrEnrollmentUnavailable
			}
		}
		d := deviceOf(c.Device)
		st.Devices[dk] = &d
		v.Complete = &complete{stamp(c.CompletedAt), key(c.ReservationID[:]), key(c.RequestDigest[:]), resultOf(c.Result), d}
		v.Pending.Protected = ""
		v.Reservations = nil
		out = pairing.CommitOutcome{State: pairing.CommitCommitted, Result: c.Result}
		return nil
	})
	return out, err
}
func expire(d *device) { d.Status = pairing.DeviceExpired; d.Root = ""; d.Code = "" }
func (s *Store) Confirm(ctx context.Context, c pairing.ConfirmationCommand) (pairing.DeviceActivationStatus, error) {
	var out pairing.DeviceActivationStatus
	err := s.with(ctx, true, func(st *state) error {
		v := st.Intents[key(c.IntentID[:])]
		if v == nil || v.Complete == nil {
			return pairing.ErrEnrollmentUnavailable
		}
		d := &v.Complete.Device
		if d.Tenant != c.Actor.TenantID().String() {
			return pairing.ErrEnrollmentUnavailable
		}
		if v.Confirmation != nil {
			x := v.Confirmation
			if x.Subject != c.Actor.Subject() || x.Tenant != c.Actor.TenantID().String() || x.Request != key(c.RequestID[:]) || x.Decision != c.Decision || x.Reason != c.Reason {
				return pairing.ErrConfirmationConflict
			}
			out = d.Status
			return nil
		}
		if d.Status != pairing.DevicePendingConfirmation {
			return pairing.ErrConfirmationConflict
		}
		if !c.ConfirmedAt.Before(parse(v.Pending.Expires)) {
			expire(d)
		} else if c.Decision == pairing.ConfirmationCodesMatch {
			d.Status = pairing.DeviceActive
			d.Code = ""
		} else {
			d.Status = pairing.DeviceRevoked
			d.Root = ""
			d.Code = ""
		}
		st.Devices[d.ID] = d
		v.Confirmation = &confirmation{c.Actor.Subject(), c.Actor.TenantID().String(), stamp(c.ConfirmedAt), key(c.RequestID[:]), c.Decision, c.Reason}
		out = d.Status
		return nil
	})
	return out, err
}
func (s *Store) GetConfirmation(ctx context.Context, a pairing.VerifiedAdminPrincipal, id pairing.PairingIntentID, now time.Time) (pairing.PairingConfirmationView, error) {
	var out pairing.PairingConfirmationView
	err := s.with(ctx, true, func(st *state) error {
		v := st.Intents[key(id[:])]
		if v == nil || v.Complete == nil || v.Complete.Device.Tenant != a.TenantID().String() {
			return pairing.ErrEnrollmentUnavailable
		}
		d := &v.Complete.Device
		if d.Status == pairing.DevicePendingConfirmation && !now.Before(parse(v.Pending.Expires)) {
			expire(d)
			st.Devices[d.ID] = d
		}
		out = pairing.PairingConfirmationView{ExpiresAt: parse(v.Pending.Expires), Status: d.Status}
		if d.Status == pairing.DevicePendingConfirmation {
			copy(out.ShortAuthenticationCode[:], d.Code)
			out.IncludesShortAuthenticationCode = true
		}
		return nil
	})
	return out, err
}
func (s *Store) GetPhoneStatus(ctx context.Context, t pairing.PairingStatusTokenDigest) (pairing.PhonePairingStatusView, error) {
	var out pairing.PhonePairingStatusView
	err := s.with(ctx, false, func(st *state) error {
		for _, d := range st.Devices {
			if d.Token == key(t[:]) {
				out.Status = d.Status
				return nil
			}
		}
		return pairing.ErrEnrollmentUnavailable
	})
	return out, err
}
func (s *Store) AcknowledgePhoneStatus(ctx context.Context, t pairing.PairingStatusTokenDigest, status pairing.DeviceActivationStatus, _ time.Time) error {
	return s.with(ctx, true, func(st *state) error {
		k := key(t[:])
		found := false
		for _, d := range st.Devices {
			if d.Token == k {
				found = true
				if d.Status != status || status == pairing.DevicePendingConfirmation {
					return pairing.ErrEnrollmentUnavailable
				}
				break
			}
		}
		if !found {
			return pairing.ErrEnrollmentUnavailable
		}
		if old, ok := st.Acks[k]; ok && old != string(status) {
			return pairing.ErrEnrollmentUnavailable
		}
		st.Acks[k] = string(status)
		return nil
	})
}
func (s *Store) CleanupExpired(ctx context.Context, before time.Time, limit uint16) (uint16, error) {
	if limit == 0 || limit > pairing.CleanupPageSizeMax {
		return 0, pairing.ErrInvalidCleanupLimit
	}
	var n uint16
	err := s.with(ctx, true, func(st *state) error {
		keys := make([]string, 0, len(st.Intents))
		for k := range st.Intents {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		if len(keys) == 0 {
			return nil
		}
		if st.Cursor >= len(keys) {
			st.Cursor = 0
		}
		for seen := uint16(0); seen < limit && st.Cursor < len(keys); seen++ {
			v := st.Intents[keys[st.Cursor]]
			st.Cursor++
			changed := false
			if !before.Before(parse(v.Pending.Expires)) && v.Pending.Protected != "" {
				v.Pending.Protected = ""
				v.Reservations = nil
				changed = true
			}
			if v.Complete != nil && v.Complete.Device.Status == pairing.DevicePendingConfirmation && !before.Before(parse(v.Pending.Expires)) {
				expire(&v.Complete.Device)
				st.Devices[v.Complete.Device.ID] = &v.Complete.Device
				changed = true
			}
			if changed {
				n++
			}
		}
		return nil
	})
	return n, err
}

var _ pairing.Repository = (*Store)(nil)
