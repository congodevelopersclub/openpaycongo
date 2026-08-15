package pairing

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// SQLiteRepository is the durable, internal-only pairing state adapter. All
// lifecycle transitions are serialized by SQLite transactions; no route wires
// this adapter to a public endpoint.
type SQLiteRepository struct{ db *sql.DB }

func OpenSQLiteRepository(path string) (*SQLiteRepository, error) {
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		return nil, err
	}
	// A single writer makes the check-then-transition invariants deterministic,
	// including for :memory: databases used by contract tests.
	db.SetMaxOpenConns(1)
	if err = db.Ping(); err != nil {
		db.Close()
		return nil, err
	}
	if _, err = db.Exec("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000"); err != nil {
		db.Close()
		return nil, err
	}
	if err = migratePairingSQLite(context.Background(), db); err != nil {
		db.Close()
		return nil, err
	}
	return &SQLiteRepository{db: db}, nil
}

func (r *SQLiteRepository) Close() error { return r.db.Close() }

const pairingSchema = `
CREATE TABLE IF NOT EXISTS pairing_intents (
 id BLOB PRIMARY KEY, tenant_id TEXT NOT NULL, expires_at INTEGER NOT NULL,
 intent_nonce BLOB NOT NULL, protected_ephemeral BLOB, signing_fingerprint BLOB NOT NULL,
 server_public BLOB NOT NULL, trust_mode TEXT NOT NULL, invalid_attempts INTEGER NOT NULL DEFAULT 0,
 state TEXT NOT NULL DEFAULT 'pending', request_digest BLOB, result_ciphertext BLOB, result_device_id BLOB,
 result_nonce BLOB, completed_at INTEGER
);
CREATE TABLE IF NOT EXISTS pairing_reservations (intent_id BLOB NOT NULL REFERENCES pairing_intents(id), id BLOB NOT NULL, PRIMARY KEY(intent_id,id));
CREATE TABLE IF NOT EXISTS pairing_devices (
 id BLOB PRIMARY KEY, intent_id BLOB NOT NULL UNIQUE REFERENCES pairing_intents(id), tenant_id TEXT NOT NULL,
 install_id TEXT NOT NULL, status TEXT NOT NULL, protected_root BLOB, status_digest BLOB NOT NULL UNIQUE,
 short_code BLOB, signing_public BLOB NOT NULL, UNIQUE(tenant_id,install_id)
);
CREATE TABLE IF NOT EXISTS pairing_confirmations (
 intent_id BLOB PRIMARY KEY REFERENCES pairing_intents(id), actor_subject TEXT NOT NULL, actor_tenant TEXT NOT NULL,
 request_id BLOB NOT NULL, decision INTEGER NOT NULL, reason TEXT NOT NULL, confirmed_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS pairing_phone_acknowledgements (
 status_digest BLOB PRIMARY KEY, status TEXT NOT NULL, acknowledged_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS pairing_intents_expiry ON pairing_intents(state, expires_at);`

func migratePairingSQLite(ctx context.Context, db *sql.DB) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS pairing_schema_migrations (revision TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at INTEGER NOT NULL)`); err != nil {
		return err
	}
	checksum := fmt.Sprintf("%x", sha256.Sum256([]byte(pairingSchema)))
	var recorded string
	err = tx.QueryRowContext(ctx, "SELECT checksum FROM pairing_schema_migrations WHERE revision='0001'").Scan(&recorded)
	if errors.Is(err, sql.ErrNoRows) {
		if _, err = tx.ExecContext(ctx, pairingSchema); err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, "INSERT INTO pairing_schema_migrations(revision,checksum,applied_at) VALUES('0001',?,?)", checksum, time.Now().UTC().UnixNano()); err != nil {
			return err
		}
	} else if err != nil {
		return err
	} else if recorded != checksum {
		return errors.New("pairing sqlite migration checksum drift")
	}
	return tx.Commit()
}

func (r *SQLiteRepository) Create(ctx context.Context, e PendingEnrollment) error {
	_, err := r.db.ExecContext(ctx, `INSERT INTO pairing_intents(id,tenant_id,expires_at,intent_nonce,protected_ephemeral,signing_fingerprint,server_public,trust_mode)
	 VALUES(?,?,?,?,?,?,?,?)`, e.ID[:], e.TenantID.String(), e.ExpiresAt.UTC().UnixNano(), e.IntentNonce[:], e.ProtectedServerPrivateKey.Bytes(), e.EnrollmentSigningFingerprint[:], e.ServerKeyAgreementPublic[:], string(e.TrustMode))
	if err != nil {
		return ErrIntentCollision
	}
	return nil
}

func (r *SQLiteRepository) BeginCompletionAttempt(ctx context.Context, id PairingIntentID, now time.Time, maxAttempts, maxInFlight uint8) (CompletionReservation, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return CompletionReservation{}, err
	}
	defer tx.Rollback()
	e, state, err := readPending(ctx, tx, id)
	if err != nil || state != "pending" || !now.Before(e.ExpiresAt) || e.InvalidProofAttempts >= maxAttempts {
		return CompletionReservation{}, ErrEnrollmentUnavailable
	}
	var count uint8
	if err = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM pairing_reservations WHERE intent_id=?", id[:]).Scan(&count); err != nil || count >= maxInFlight {
		return CompletionReservation{}, ErrEnrollmentUnavailable
	}
	var reservation CompletionReservationID
	if _, err = rand.Read(reservation[:]); err != nil {
		return CompletionReservation{}, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO pairing_reservations(intent_id,id) VALUES(?,?)", id[:], reservation[:]); err != nil {
		return CompletionReservation{}, ErrEnrollmentUnavailable
	}
	if err = tx.Commit(); err != nil {
		return CompletionReservation{}, err
	}
	return CompletionReservation{Enrollment: e, ID: reservation}, nil
}

func (r *SQLiteRepository) ReleaseCompletionAttempt(ctx context.Context, id PairingIntentID, reservation CompletionReservationID) error {
	_, err := r.db.ExecContext(ctx, "DELETE FROM pairing_reservations WHERE intent_id=? AND id=?", id[:], reservation[:])
	return err
}

func (r *SQLiteRepository) FinishFailedCompletion(ctx context.Context, id PairingIntentID, reservation CompletionReservationID, failedAt time.Time, maxAttempts uint8) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, "DELETE FROM pairing_reservations WHERE intent_id=? AND id=?", id[:], reservation[:])
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return tx.Commit()
	}
	if _, err = tx.ExecContext(ctx, `UPDATE pairing_intents SET invalid_attempts=invalid_attempts+1, protected_ephemeral=CASE WHEN invalid_attempts+1>=? OR expires_at<=? THEN NULL ELSE protected_ephemeral END WHERE id=? AND state='pending'`, maxAttempts, failedAt.UTC().UnixNano(), id[:]); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *SQLiteRepository) AbortCompletion(ctx context.Context, id PairingIntentID, failedAt time.Time) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var state string
	err = tx.QueryRowContext(ctx, "SELECT state FROM pairing_intents WHERE id=?", id[:]).Scan(&state)
	if err != nil || state == "completed" {
		return ErrEnrollmentUnavailable
	}
	if _, err = tx.ExecContext(ctx, "UPDATE pairing_intents SET state='aborted', protected_ephemeral=NULL WHERE id=?", id[:]); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM pairing_reservations WHERE intent_id=?", id[:]); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *SQLiteRepository) Commit(ctx context.Context, c CompletionCommit) (CommitOutcome, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return CommitOutcome{State: CommitNotCommitted}, err
	}
	defer tx.Rollback()
	var state string
	var digest []byte
	err = tx.QueryRowContext(ctx, "SELECT state,request_digest FROM pairing_intents WHERE id=?", c.IntentID[:]).Scan(&state, &digest)
	if err != nil {
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	if state == "completed" {
		result, ok, e := readCompletion(ctx, tx, c.IntentID, c.RequestDigest)
		if e != nil {
			return CommitOutcome{State: CommitUnknown}, e
		}
		if ok {
			return CommitOutcome{State: CommitCommitted, Result: result}, nil
		}
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	if state != "pending" {
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	var reserved int
	if err = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM pairing_reservations WHERE intent_id=? AND id=?", c.IntentID[:], c.ReservationID[:]).Scan(&reserved); err != nil || reserved != 1 {
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO pairing_devices(id,intent_id,tenant_id,install_id,status,protected_root,status_digest,short_code,signing_public) VALUES(?,?,?,?,?,?,?,?,?)`, c.Device.ID[:], c.IntentID[:], c.Device.TenantID.String(), c.Device.InstallID, string(c.Device.ActivationStatus), c.Device.ProtectedInstallRoot.Bytes(), c.Device.PairingStatusTokenDigest[:], c.Device.ShortAuthenticationCode[:], c.Device.DeviceSigningPublicKey[:])
	if err != nil {
		return CommitOutcome{State: CommitNotCommitted}, ErrEnrollmentUnavailable
	}
	_, err = tx.ExecContext(ctx, `UPDATE pairing_intents SET state='completed',request_digest=?,result_ciphertext=?,result_device_id=?,result_nonce=?,completed_at=?,protected_ephemeral=NULL WHERE id=?`, c.RequestDigest[:], c.Result.Ciphertext, c.Result.DeviceID[:], c.Result.Nonce[:], c.CompletedAt.UTC().UnixNano(), c.IntentID[:])
	if err != nil {
		return CommitOutcome{State: CommitUnknown}, err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM pairing_reservations WHERE intent_id=?", c.IntentID[:]); err != nil {
		return CommitOutcome{State: CommitUnknown}, err
	}
	if err = tx.Commit(); err != nil {
		return CommitOutcome{State: CommitUnknown}, err
	}
	return CommitOutcome{State: CommitCommitted, Result: c.Result}, nil
}

func (r *SQLiteRepository) FindCompletion(ctx context.Context, id PairingIntentID, digest RequestDigest) (CompletionResult, bool, error) {
	return readCompletion(ctx, r.db, id, digest)
}

func (r *SQLiteRepository) Confirm(ctx context.Context, c ConfirmationCommand) (DeviceActivationStatus, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var subject, tenant string
	var request []byte
	var decision ConfirmationDecision
	var reason ConfirmationReason
	err = tx.QueryRowContext(ctx, "SELECT actor_subject,actor_tenant,request_id,decision,reason FROM pairing_confirmations WHERE intent_id=?", c.IntentID[:]).Scan(&subject, &tenant, &request, &decision, &reason)
	if err == nil {
		if subject == c.Actor.Subject() && tenant == c.Actor.TenantID().String() && string(request) == string(c.RequestID[:]) && decision == c.Decision && reason == c.Reason {
			var status DeviceActivationStatus
			err = tx.QueryRowContext(ctx, "SELECT status FROM pairing_devices WHERE intent_id=?", c.IntentID[:]).Scan(&status)
			return status, err
		}
		return "", ErrConfirmationConflict
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	var deviceTenant string
	var status DeviceActivationStatus
	var expires int64
	err = tx.QueryRowContext(ctx, `SELECT d.tenant_id,d.status,i.expires_at FROM pairing_devices d JOIN pairing_intents i ON i.id=d.intent_id WHERE d.intent_id=?`, c.IntentID[:]).Scan(&deviceTenant, &status, &expires)
	if err != nil || deviceTenant != c.Actor.TenantID().String() || status != DevicePendingConfirmation {
		return "", ErrEnrollmentUnavailable
	}
	if c.ConfirmedAt.UTC().UnixNano() >= expires {
		status = DeviceExpired
	} else if c.Decision == ConfirmationCodesMatch {
		status = DeviceActive
	} else {
		status = DeviceRevoked
	}
	if _, err = tx.ExecContext(ctx, "UPDATE pairing_devices SET status=?,protected_root=NULL,short_code=NULL WHERE intent_id=?", string(status), c.IntentID[:]); err != nil {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO pairing_confirmations(intent_id,actor_subject,actor_tenant,request_id,decision,reason,confirmed_at) VALUES(?,?,?,?,?,?,?)", c.IntentID[:], c.Actor.Subject(), c.Actor.TenantID().String(), c.RequestID[:], c.Decision, string(c.Reason), c.ConfirmedAt.UTC().UnixNano()); err != nil {
		return "", err
	}
	if err = tx.Commit(); err != nil {
		return "", err
	}
	return status, nil
}

func (r *SQLiteRepository) GetConfirmation(ctx context.Context, actor VerifiedAdminPrincipal, id PairingIntentID, now time.Time) (PairingConfirmationView, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return PairingConfirmationView{}, err
	}
	defer tx.Rollback()
	var tenant string
	var status DeviceActivationStatus
	var code []byte
	var expiry int64
	err = tx.QueryRowContext(ctx, `SELECT d.tenant_id,d.status,d.short_code,i.expires_at FROM pairing_devices d JOIN pairing_intents i ON i.id=d.intent_id WHERE d.intent_id=?`, id[:]).Scan(&tenant, &status, &code, &expiry)
	if err != nil || tenant != actor.TenantID().String() {
		return PairingConfirmationView{}, ErrEnrollmentUnavailable
	}
	if status == DevicePendingConfirmation && now.UTC().UnixNano() >= expiry {
		status = DeviceExpired
		if _, err = tx.ExecContext(ctx, "UPDATE pairing_devices SET status=?,protected_root=NULL,short_code=NULL WHERE intent_id=?", string(status), id[:]); err != nil {
			return PairingConfirmationView{}, err
		}
		code = nil
	}
	var result PairingConfirmationView
	result.ExpiresAt = time.Unix(0, expiry).UTC()
	result.Status = status
	if status == DevicePendingConfirmation && len(code) == len(result.ShortAuthenticationCode) {
		copy(result.ShortAuthenticationCode[:], code)
		result.IncludesShortAuthenticationCode = true
	}
	if err = tx.Commit(); err != nil {
		return PairingConfirmationView{}, err
	}
	return result, nil
}

func (r *SQLiteRepository) GetPhoneStatus(ctx context.Context, digest PairingStatusTokenDigest) (PhonePairingStatusView, error) {
	var status DeviceActivationStatus
	err := r.db.QueryRowContext(ctx, "SELECT status FROM pairing_devices WHERE status_digest=?", digest[:]).Scan(&status)
	if err != nil {
		return PhonePairingStatusView{}, ErrEnrollmentUnavailable
	}
	return PhonePairingStatusView{Status: status}, nil
}
func (r *SQLiteRepository) AcknowledgePhoneStatus(ctx context.Context, digest PairingStatusTokenDigest, status DeviceActivationStatus, at time.Time) error {
	var actual DeviceActivationStatus
	err := r.db.QueryRowContext(ctx, "SELECT status FROM pairing_devices WHERE status_digest=?", digest[:]).Scan(&actual)
	if err != nil || actual != status || status == DevicePendingConfirmation {
		return ErrEnrollmentUnavailable
	}
	var existing DeviceActivationStatus
	err = r.db.QueryRowContext(ctx, "SELECT status FROM pairing_phone_acknowledgements WHERE status_digest=?", digest[:]).Scan(&existing)
	if err == nil {
		if existing == status {
			return nil
		}
		return ErrEnrollmentUnavailable
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	_, err = r.db.ExecContext(ctx, "INSERT INTO pairing_phone_acknowledgements(status_digest,status,acknowledged_at) VALUES(?,?,?)", digest[:], string(status), at.UTC().UnixNano())
	return err
}

func (r *SQLiteRepository) CleanupExpired(ctx context.Context, before time.Time, limit uint16) (uint16, error) {
	if limit == 0 {
		return 0, ErrInvalidCleanupLimit
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, "SELECT id FROM pairing_intents WHERE expires_at<=? AND state IN ('pending','completed') ORDER BY expires_at LIMIT ?", before.UTC().UnixNano(), limit)
	if err != nil {
		return 0, err
	}
	var ids [][]byte
	for rows.Next() {
		var id []byte
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	for _, id := range ids {
		if _, err = tx.ExecContext(ctx, "UPDATE pairing_intents SET protected_ephemeral=NULL WHERE id=?", id); err != nil {
			return 0, err
		}
		if _, err = tx.ExecContext(ctx, "UPDATE pairing_devices SET status=CASE WHEN status='pending_confirmation' THEN 'expired' ELSE status END,protected_root=CASE WHEN status='pending_confirmation' THEN NULL ELSE protected_root END,short_code=CASE WHEN status='pending_confirmation' THEN NULL ELSE short_code END WHERE intent_id=?", id); err != nil {
			return 0, err
		}
	}
	if err = tx.Commit(); err != nil {
		return 0, err
	}
	return uint16(len(ids)), nil
}

func readPending(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, id PairingIntentID) (PendingEnrollment, string, error) {
	var e PendingEnrollment
	var expiry int64
	var nonce, protected, fingerprint, server []byte
	var mode, state string
	err := q.QueryRowContext(ctx, "SELECT tenant_id,expires_at,intent_nonce,protected_ephemeral,signing_fingerprint,server_public,trust_mode,invalid_attempts,state FROM pairing_intents WHERE id=?", id[:]).Scan(&e.TenantID.value, &expiry, &nonce, &protected, &fingerprint, &server, &mode, &e.InvalidProofAttempts, &state)
	if err != nil {
		return e, "", err
	}
	e.ID = id
	e.ExpiresAt = time.Unix(0, expiry).UTC()
	copy(e.IntentNonce[:], nonce)
	copy(e.EnrollmentSigningFingerprint[:], fingerprint)
	copy(e.ServerKeyAgreementPublic[:], server)
	e.TrustMode = EnrollmentTrustMode(mode)
	if len(protected) > 0 {
		e.ProtectedServerPrivateKey, _ = NewProtectedMaterial(protected)
	}
	return e, state, nil
}
func readCompletion(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, id PairingIntentID, digest RequestDigest) (CompletionResult, bool, error) {
	var got, cipher, device, nonce []byte
	err := q.QueryRowContext(ctx, "SELECT request_digest,result_ciphertext,result_device_id,result_nonce FROM pairing_intents WHERE id=? AND state='completed'", id[:]).Scan(&got, &cipher, &device, &nonce)
	if errors.Is(err, sql.ErrNoRows) {
		return CompletionResult{}, false, nil
	}
	if err != nil {
		return CompletionResult{}, false, err
	}
	if string(got) != string(digest[:]) {
		return CompletionResult{}, false, nil
	}
	var result CompletionResult
	result.Status = CompletionPendingConfirmation
	result.Ciphertext = append([]byte(nil), cipher...)
	copy(result.DeviceID[:], device)
	copy(result.Nonce[:], nonce)
	return result, true, nil
}

var _ Repository = (*SQLiteRepository)(nil)
