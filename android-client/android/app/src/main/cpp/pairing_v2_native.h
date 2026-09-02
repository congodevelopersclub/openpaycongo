#ifndef OPENPAY_PAIRING_V2_NATIVE_H
#define OPENPAY_PAIRING_V2_NATIVE_H

#include <sodium.h>

enum {
    OPENPAY_PAIRING_V2_INTENT_BYTES = 16,
    OPENPAY_PAIRING_V2_NONCE_BYTES = crypto_aead_xchacha20poly1305_ietf_NPUBBYTES,
    OPENPAY_PAIRING_V2_CIPHERTEXT_BYTES = crypto_kx_SESSIONKEYBYTES + crypto_aead_xchacha20poly1305_ietf_ABYTES,
    OPENPAY_PAIRING_V2_REQUEST_AAD_BYTES = 86,
};

typedef struct {
    unsigned char client_public_key[crypto_kx_PUBLICKEYBYTES];
    unsigned char nonce[OPENPAY_PAIRING_V2_NONCE_BYTES];
    unsigned char ciphertext[OPENPAY_PAIRING_V2_CIPHERTEXT_BYTES];
    unsigned char send_key[crypto_kx_SESSIONKEYBYTES];
    unsigned char receive_key[crypto_kx_SESSIONKEYBYTES];
} openpay_pairing_v2_material;

int openpay_pairing_v2_begin(
    const unsigned char intent[OPENPAY_PAIRING_V2_INTENT_BYTES],
    const unsigned char server_public_key[crypto_kx_PUBLICKEYBYTES],
    const unsigned char pairing_secret[crypto_kx_SESSIONKEYBYTES],
    openpay_pairing_v2_material *material);

void openpay_pairing_v2_material_dispose(openpay_pairing_v2_material *material);

#endif
