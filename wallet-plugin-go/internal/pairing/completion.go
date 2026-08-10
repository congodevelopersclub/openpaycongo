package pairing

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

type encryptedProofWire struct {
	DeviceSigningPublicKey string `json:"device_signing_public_key"`
	InstallID              string `json:"install_id"`
	Signature              string `json:"signature"`
	Version                string `json:"version"`
}

type completionResponseWire struct {
	DeviceID           string `json:"device_id"`
	KeyConfirmation    string `json:"key_confirmation"`
	PairingStatusToken string `json:"pairing_status_token"`
	Status             string `json:"status"`
	Version            string `json:"version"`
}

type openedProof struct {
	deviceSigningPublicKey DeviceSigningPublicKey
	installID              string
}

type sessionKeySet struct {
	clientToServer             SessionKey
	installRoot                SecretMaterial
	serverToClientAEAD         SessionKey
	serverToClientConfirmation SessionKey
	shortCode                  ShortAuthenticationCode
}

func (service *Service) openCompletionProof(
	ctx context.Context,
	record PendingEnrollment,
	request CompletionRequest,
) (openedProof, sessionKeySet, error) {
	privateKeyBytes, err := service.keyProtector.Unprotect(
		ctx,
		record.ProtectedServerPrivateKey,
		keyProtectionAAD("intent-private", record.TenantID, record.ID[:]),
	)
	if err != nil {
		if errors.Is(err, ErrKeyProtectorRetryable) {
			return openedProof{}, sessionKeySet{}, errors.Join(ErrInvalidCompletion, ErrKeyProtectorRetryable)
		}
		return openedProof{}, sessionKeySet{}, errors.Join(ErrInvalidCompletion, ErrKeyProtectionFailure)
	}
	defer wipe(privateKeyBytes[:])
	serverPrivateKey, err := ecdh.X25519().NewPrivateKey(privateKeyBytes[:])
	if err != nil {
		return openedProof{}, sessionKeySet{}, ErrInvalidCompletion
	}
	clientPublicKey, err := ecdh.X25519().NewPublicKey(
		request.ClientKeyAgreementPublic[:],
	)
	if err != nil {
		return openedProof{}, sessionKeySet{}, ErrInvalidCompletion
	}
	sharedSecret, err := serverPrivateKey.ECDH(clientPublicKey)
	if err != nil {
		return openedProof{}, sessionKeySet{}, ErrInvalidCompletion
	}
	defer wipe(sharedSecret)
	keys, err := deriveSessionKeys(sharedSecret, record, request.ClientKeyAgreementPublic)
	if err != nil {
		return openedProof{}, sessionKeySet{}, ErrInvalidCompletion
	}
	defer wipe(keys.clientToServer[:])

	plaintext, err := openProofCiphertext(record, request, keys.clientToServer[:])
	if err != nil {
		keys.wipe()
		return openedProof{}, sessionKeySet{}, ErrInvalidCompletion
	}
	defer wipe(plaintext)
	proof, err := decodeAndVerifyProof(record, request, plaintext)
	if err != nil {
		keys.wipe()
		return openedProof{}, sessionKeySet{}, ErrInvalidCompletion
	}
	return proof, keys, nil
}

func deriveSessionKeys(
	sharedSecret []byte,
	record PendingEnrollment,
	clientPublic ClientKeyAgreementPublic,
) (sessionKeySet, error) {
	pseudorandomKey, err := hkdf.Extract(
		sha256.New,
		sharedSecret,
		record.IntentNonce[:],
	)
	if err != nil {
		return sessionKeySet{}, err
	}
	defer wipe(pseudorandomKey)
	clientToServer, err := pairingKey(pseudorandomKey, record, clientPublic, "c2s", SessionKeySize)
	if err != nil {
		return sessionKeySet{}, err
	}
	serverToClientAEAD, err := pairingKey(pseudorandomKey, record, clientPublic, "s2c-aead", SessionKeySize)
	if err != nil {
		wipe(clientToServer)
		return sessionKeySet{}, err
	}
	serverToClientConfirmation, err := pairingKey(
		pseudorandomKey,
		record,
		clientPublic,
		"s2c-confirm",
		SessionKeySize,
	)
	if err != nil {
		wipe(clientToServer)
		wipe(serverToClientAEAD)
		return sessionKeySet{}, err
	}
	installRoot, err := pairingKey(pseudorandomKey, record, clientPublic, "install-root", SecretSize)
	if err != nil {
		wipe(clientToServer)
		wipe(serverToClientAEAD)
		wipe(serverToClientConfirmation)
		return sessionKeySet{}, err
	}
	shortCodeBytes, err := pairingKey(
		pseudorandomKey,
		record,
		clientPublic,
		"short-authentication-code",
		ShortAuthenticationCandidateSize*ShortAuthenticationCandidates,
	)
	if err != nil {
		wipe(clientToServer)
		wipe(serverToClientAEAD)
		wipe(serverToClientConfirmation)
		wipe(installRoot)
		return sessionKeySet{}, err
	}
	shortCode, err := deriveShortAuthenticationCode(shortCodeBytes)
	wipe(shortCodeBytes)
	if err != nil {
		wipe(clientToServer)
		wipe(serverToClientAEAD)
		wipe(serverToClientConfirmation)
		wipe(installRoot)
		return sessionKeySet{}, err
	}
	var keys sessionKeySet
	copy(keys.clientToServer[:], clientToServer)
	copy(keys.installRoot[:], installRoot)
	copy(keys.serverToClientAEAD[:], serverToClientAEAD)
	copy(keys.serverToClientConfirmation[:], serverToClientConfirmation)
	keys.shortCode = shortCode
	wipe(clientToServer)
	wipe(installRoot)
	wipe(serverToClientAEAD)
	wipe(serverToClientConfirmation)
	return keys, nil
}

func deriveShortAuthenticationCode(material []byte) (ShortAuthenticationCode, error) {
	const rangeSize uint64 = 1_000_000
	const uint32Space uint64 = 1 << 32
	const rejectionLimit uint64 = (uint32Space / rangeSize) * rangeSize
	expectedLength := ShortAuthenticationCandidateSize * ShortAuthenticationCandidates
	if len(material) != expectedLength {
		return ShortAuthenticationCode{}, ErrInvalidCompletion
	}
	for candidate := 0; candidate < ShortAuthenticationCandidates; candidate++ {
		offset := candidate * ShortAuthenticationCandidateSize
		value := binary.BigEndian.Uint32(material[offset : offset+ShortAuthenticationCandidateSize])
		if uint64(value) < rejectionLimit {
			var code ShortAuthenticationCode
			copy(code[:], fmt.Sprintf("%06d", uint64(value)%rangeSize))
			return code, nil
		}
	}
	return ShortAuthenticationCode{}, ErrInvalidCompletion
}

func pairingKey(
	pseudorandomKey []byte,
	record PendingEnrollment,
	clientPublic ClientKeyAgreementPublic,
	label string,
	keyLength int,
) ([]byte, error) {
	return hkdf.Expand(
		sha256.New,
		pseudorandomKey,
		pairingKeyInfo(record, clientPublic, label),
		keyLength,
	)
}

func openProofCiphertext(
	record PendingEnrollment,
	request CompletionRequest,
	proofKey []byte,
) ([]byte, error) {
	if len(request.Ciphertext) < 16 || len(request.Ciphertext) > CompletionCiphertextMax {
		return nil, ErrInvalidCompletion
	}
	block, err := aes.NewCipher(proofKey)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return aead.Open(
		nil,
		request.Nonce[:],
		request.Ciphertext,
		completionAADFromRecord(record, request.ClientKeyAgreementPublic),
	)
}

func decodeAndVerifyProof(
	record PendingEnrollment,
	request CompletionRequest,
	plaintext []byte,
) (openedProof, error) {
	decoder := json.NewDecoder(bytes.NewReader(plaintext))
	decoder.DisallowUnknownFields()
	var wire encryptedProofWire
	if err := decoder.Decode(&wire); err != nil {
		return openedProof{}, err
	}
	if err := ensureJSONEnd(decoder); err != nil {
		return openedProof{}, err
	}
	if wire.Version != ProtocolVersion {
		return openedProof{}, ErrInvalidCompletion
	}
	if !isPortableIdentifier(wire.InstallID, InstallIDLengthMax) {
		return openedProof{}, ErrInvalidCompletion
	}
	publicKey, err := decodeBase64Fixed(wire.DeviceSigningPublicKey, ed25519.PublicKeySize)
	if err != nil {
		return openedProof{}, err
	}
	signature, err := decodeBase64Fixed(wire.Signature, ed25519.SignatureSize)
	if err != nil {
		return openedProof{}, err
	}
	transcript := deviceProofTranscriptFromRecord(
		record,
		wire.InstallID,
		request.ClientKeyAgreementPublic[:],
		publicKey,
	)
	if !ed25519.Verify(ed25519.PublicKey(publicKey), transcript.Bytes(), signature) {
		return openedProof{}, ErrInvalidCompletion
	}
	var fixedPublicKey DeviceSigningPublicKey
	copy(fixedPublicKey[:], publicKey)
	return openedProof{
		deviceSigningPublicKey: fixedPublicKey,
		installID:              wire.InstallID,
	}, nil
}

func ensureJSONEnd(decoder *json.Decoder) error {
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	return ErrInvalidCompletion
}

func decodeBase64Fixed(value string, expectedLength int) ([]byte, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return nil, ErrInvalidCompletion
	}
	if len(decoded) != expectedLength {
		return nil, ErrInvalidCompletion
	}
	return decoded, nil
}

func (service *Service) prepareCompletion(
	ctx context.Context,
	record PendingEnrollment,
	proof openedProof,
	keys sessionKeySet,
) (CompletionResult, DeviceRecord, error) {
	defer keys.wipe()
	var deviceID DeviceID
	if _, err := io.ReadFull(service.random, deviceID[:]); err != nil {
		return CompletionResult{}, DeviceRecord{}, err
	}
	var statusToken PairingStatusToken
	if _, err := io.ReadFull(service.random, statusToken[:]); err != nil {
		return CompletionResult{}, DeviceRecord{}, err
	}
	statusTokenDigest := sha256.Sum256(statusToken[:])
	var installRoot SecretMaterial
	copy(installRoot[:], keys.installRoot[:])
	protectedInstallRoot, err := service.keyProtector.Protect(
		ctx,
		installRoot,
		keyProtectionAAD("install-root", record.TenantID, deviceID[:]),
	)
	wipe(installRoot[:])
	if err != nil {
		return CompletionResult{}, DeviceRecord{}, err
	}
	if protectedInstallRoot.IsZero() {
		return CompletionResult{}, DeviceRecord{}, ErrInvalidProtectedMaterial
	}
	result, err := service.sealCompletionResponse(
		deviceID,
		statusToken,
		keys.serverToClientAEAD[:],
		keys.serverToClientConfirmation[:],
	)
	if err != nil {
		return CompletionResult{}, DeviceRecord{}, err
	}
	device := DeviceRecord{
		ActivationStatus:         DevicePendingConfirmation,
		DeviceSigningPublicKey:   proof.deviceSigningPublicKey,
		ID:                       deviceID,
		InstallID:                proof.installID,
		ProtectedInstallRoot:     protectedInstallRoot,
		PairingStatusTokenDigest: statusTokenDigest,
		ShortAuthenticationCode:  keys.shortCode,
		TenantID:                 record.TenantID,
	}
	return result, device, nil
}

func (service *Service) sealCompletionResponse(
	deviceID DeviceID,
	statusToken PairingStatusToken,
	responseAEADKey []byte,
	responseConfirmationKey []byte,
) (CompletionResult, error) {
	keyConfirmation := hmac.New(sha256.New, responseConfirmationKey)
	_, _ = keyConfirmation.Write(completionResponseAAD(deviceID))
	wire := completionResponseWire{
		DeviceID:           base64.RawURLEncoding.EncodeToString(deviceID[:]),
		KeyConfirmation:    base64.RawURLEncoding.EncodeToString(keyConfirmation.Sum(nil)),
		PairingStatusToken: base64.RawURLEncoding.EncodeToString(statusToken[:]),
		Status:             string(CompletionPendingConfirmation),
		Version:            ProtocolVersion,
	}
	plaintext, err := json.Marshal(wire)
	if err != nil {
		return CompletionResult{}, err
	}
	defer wipe(plaintext)
	block, err := aes.NewCipher(responseAEADKey)
	if err != nil {
		return CompletionResult{}, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return CompletionResult{}, err
	}
	var nonce Nonce
	if _, err := io.ReadFull(service.random, nonce[:]); err != nil {
		return CompletionResult{}, err
	}
	return CompletionResult{
		Ciphertext: aead.Seal(nil, nonce[:], plaintext, completionResponseAAD(deviceID)),
		DeviceID:   deviceID,
		Nonce:      nonce,
		Status:     CompletionPendingConfirmation,
	}, nil
}

func (keys *sessionKeySet) wipe() {
	wipe(keys.clientToServer[:])
	wipe(keys.installRoot[:])
	wipe(keys.serverToClientAEAD[:])
	wipe(keys.serverToClientConfirmation[:])
	wipe(keys.shortCode[:])
}

func wipe(value []byte) {
	for index := range value {
		value[index] = 0
	}
}
