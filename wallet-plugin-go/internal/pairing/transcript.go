package pairing

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
)

func qrSigningTranscript(qr PairingQR) []byte {
	buffer := bytes.NewBuffer(make([]byte, 0, 1024))
	transcriptWriteField(buffer, []byte("openpaycongo/pairing/qr"))
	transcriptWriteField(buffer, []byte(qr.Version))
	transcriptWriteField(buffer, []byte(qr.Endpoint))
	transcriptWriteField(buffer, qr.IntentID[:])
	transcriptWriteField(buffer, qr.IntentNonce[:])
	transcriptWriteField(buffer, []byte(qr.ExpiresAt.UTC().Format(timeFormat)))
	transcriptWriteField(buffer, []byte(qr.Algorithms))
	transcriptWriteField(buffer, qr.EnrollmentSigningPublicKey[:])
	transcriptWriteField(buffer, qr.EnrollmentSigningFingerprint[:])
	transcriptWriteField(buffer, qr.ServerKeyAgreementPublic[:])
	transcriptWriteField(buffer, []byte(qr.TrustMode))
	return buffer.Bytes()
}

func keyProtectionAAD(purpose string, tenantID TenantID, id []byte) ProtectionAAD {
	buffer := bytes.NewBuffer(make([]byte, 0, 256))
	transcriptWriteField(buffer, []byte("openpaycongo/pairing/key-protector"))
	transcriptWriteField(buffer, []byte(ProtocolVersion))
	transcriptWriteField(buffer, []byte(purpose))
	transcriptWriteField(buffer, []byte(tenantID.String()))
	transcriptWriteField(buffer, id)
	aad, err := NewProtectionAAD(buffer.Bytes())
	if err != nil {
		panic("pairing: invalid internal key-protection AAD")
	}
	return aad
}

func completionRequestDigest(request CompletionRequest) (RequestDigest, error) {
	if len(request.Ciphertext) < 16 || len(request.Ciphertext) > CompletionCiphertextMax {
		return RequestDigest{}, ErrInvalidCompletion
	}
	buffer := bytes.NewBuffer(make([]byte, 0, CompletionCiphertextMax+256))
	transcriptWriteField(buffer, []byte("openpaycongo/pairing/completion-request"))
	transcriptWriteField(buffer, []byte(request.Version))
	transcriptWriteField(buffer, request.IntentID[:])
	transcriptWriteField(buffer, request.ClientKeyAgreementPublic[:])
	transcriptWriteField(buffer, request.Nonce[:])
	transcriptWriteField(buffer, request.Ciphertext)
	return sha256.Sum256(buffer.Bytes()), nil
}

func pairingKeyInfo(
	record PendingEnrollment,
	clientPublic ClientKeyAgreementPublic,
	label string,
) string {
	buffer := bytes.NewBuffer(make([]byte, 0, 256))
	transcriptWriteField(buffer, []byte("openpaycongo/pairing/key"))
	transcriptWriteField(buffer, []byte(ProtocolVersion))
	transcriptWriteField(buffer, []byte(AlgorithmSuite))
	transcriptWriteField(buffer, []byte(label))
	transcriptWriteField(buffer, record.ID[:])
	transcriptWriteField(buffer, record.IntentNonce[:])
	transcriptWriteField(buffer, record.EnrollmentSigningFingerprint[:])
	transcriptWriteField(buffer, record.ServerKeyAgreementPublic[:])
	transcriptWriteField(buffer, clientPublic[:])
	digest := sha256.Sum256(buffer.Bytes())
	return string(digest[:])
}

func completionAAD(qr PairingQR, clientPublic ClientKeyAgreementPublic) []byte {
	return completionAADFields(
		qr.IntentID,
		qr.IntentNonce,
		qr.EnrollmentSigningFingerprint,
		qr.ServerKeyAgreementPublic,
		clientPublic,
	)
}

func completionAADFromRecord(
	record PendingEnrollment,
	clientPublic ClientKeyAgreementPublic,
) []byte {
	return completionAADFields(
		record.ID,
		record.IntentNonce,
		record.EnrollmentSigningFingerprint,
		record.ServerKeyAgreementPublic,
		clientPublic,
	)
}

func completionAADFields(
	id PairingIntentID,
	intentNonce IntentNonce,
	enrollmentSigningFingerprint EnrollmentSigningFingerprint,
	serverPublic ServerKeyAgreementPublic,
	clientPublic ClientKeyAgreementPublic,
) []byte {
	buffer := bytes.NewBuffer(make([]byte, 0, 256))
	transcriptWriteField(buffer, []byte("openpaycongo/pairing/completion-aad"))
	transcriptWriteField(buffer, []byte(ProtocolVersion))
	transcriptWriteField(buffer, []byte(AlgorithmSuite))
	transcriptWriteField(buffer, id[:])
	transcriptWriteField(buffer, intentNonce[:])
	transcriptWriteField(buffer, enrollmentSigningFingerprint[:])
	transcriptWriteField(buffer, serverPublic[:])
	transcriptWriteField(buffer, clientPublic[:])
	return buffer.Bytes()
}

func deviceProofTranscript(
	qr PairingQR,
	installID string,
	clientPublic []byte,
	devicePublic []byte,
) DeviceProofTranscript {
	return deviceProofTranscriptFields(
		qr.IntentID,
		qr.IntentNonce,
		qr.EnrollmentSigningFingerprint,
		installID,
		clientPublic,
		devicePublic,
	)
}

func deviceProofTranscriptFromRecord(
	record PendingEnrollment,
	installID string,
	clientPublic []byte,
	devicePublic []byte,
) DeviceProofTranscript {
	return deviceProofTranscriptFields(
		record.ID,
		record.IntentNonce,
		record.EnrollmentSigningFingerprint,
		installID,
		clientPublic,
		devicePublic,
	)
}

func deviceProofTranscriptFields(
	id PairingIntentID,
	intentNonce IntentNonce,
	enrollmentSigningFingerprint EnrollmentSigningFingerprint,
	installID string,
	clientPublic []byte,
	devicePublic []byte,
) DeviceProofTranscript {
	buffer := bytes.NewBuffer(make([]byte, 0, 256))
	transcriptWriteField(buffer, []byte("openpaycongo/pairing/device-proof"))
	transcriptWriteField(buffer, []byte(ProtocolVersion))
	transcriptWriteField(buffer, []byte(AlgorithmSuite))
	transcriptWriteField(buffer, id[:])
	transcriptWriteField(buffer, intentNonce[:])
	transcriptWriteField(buffer, enrollmentSigningFingerprint[:])
	transcriptWriteField(buffer, []byte(installID))
	transcriptWriteField(buffer, clientPublic)
	transcriptWriteField(buffer, devicePublic)
	return newDeviceProofTranscript(buffer.Bytes())
}

func completionResponseAAD(deviceID DeviceID) []byte {
	buffer := bytes.NewBuffer(make([]byte, 0, 96))
	transcriptWriteField(buffer, []byte("openpaycongo/pairing/completion-response"))
	transcriptWriteField(buffer, []byte(ProtocolVersion))
	transcriptWriteField(buffer, deviceID[:])
	return buffer.Bytes()
}

func transcriptWriteField(buffer *bytes.Buffer, value []byte) {
	if buffer == nil {
		panic("pairing: nil transcript buffer")
	}
	if len(value) > 65535 || buffer.Len()+2+len(value) > TranscriptSizeMax {
		panic("pairing: transcript bound exceeded")
	}

	var length [2]byte
	binary.BigEndian.PutUint16(length[:], uint16(len(value)))
	_, _ = buffer.Write(length[:])
	_, _ = buffer.Write(value)
}
