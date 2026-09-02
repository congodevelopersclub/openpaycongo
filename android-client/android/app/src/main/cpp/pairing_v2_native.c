#include "pairing_v2_native.h"

#include <string.h>

static int request_aad(
    const unsigned char intent[OPENPAY_PAIRING_V2_INTENT_BYTES],
    const unsigned char client_public_key[crypto_kx_PUBLICKEYBYTES],
    unsigned char output[OPENPAY_PAIRING_V2_REQUEST_AAD_BYTES]) {
    static const unsigned char domain[] = "openpaycongo/pairing/complete/v2";
    const size_t domain_length = sizeof(domain) - 1;
    size_t offset = 0;
    output[offset++] = (unsigned char) (domain_length >> 8);
    output[offset++] = (unsigned char) domain_length;
    memcpy(output + offset, domain, domain_length);
    offset += domain_length;
    output[offset++] = 0;
    output[offset++] = OPENPAY_PAIRING_V2_INTENT_BYTES;
    memcpy(output + offset, intent, OPENPAY_PAIRING_V2_INTENT_BYTES);
    offset += OPENPAY_PAIRING_V2_INTENT_BYTES;
    output[offset++] = 0;
    output[offset++] = crypto_kx_PUBLICKEYBYTES;
    memcpy(output + offset, client_public_key, crypto_kx_PUBLICKEYBYTES);
    offset += crypto_kx_PUBLICKEYBYTES;
    return offset == OPENPAY_PAIRING_V2_REQUEST_AAD_BYTES ? 0 : -1;
}

int openpay_pairing_v2_begin(
    const unsigned char intent[OPENPAY_PAIRING_V2_INTENT_BYTES],
    const unsigned char server_public_key[crypto_kx_PUBLICKEYBYTES],
    const unsigned char pairing_secret[crypto_kx_SESSIONKEYBYTES],
    openpay_pairing_v2_material *material) {
    unsigned char client_secret_key[crypto_kx_SECRETKEYBYTES];
    unsigned char aad[OPENPAY_PAIRING_V2_REQUEST_AAD_BYTES];
    unsigned long long ciphertext_length = 0;
    int result = -1;

    if (intent == NULL || server_public_key == NULL || pairing_secret == NULL || material == NULL || sodium_init() < 0) {
        return -1;
    }
    sodium_memzero(material, sizeof(*material));
    sodium_memzero(client_secret_key, sizeof(client_secret_key));
    sodium_memzero(aad, sizeof(aad));
    if (crypto_kx_keypair(material->client_public_key, client_secret_key) != 0 ||
        crypto_kx_client_session_keys(
            material->receive_key,
            material->send_key,
            material->client_public_key,
            client_secret_key,
            server_public_key) != 0 ||
        request_aad(intent, material->client_public_key, aad) != 0) goto done;
    randombytes_buf(material->nonce, sizeof(material->nonce));
    if (crypto_aead_xchacha20poly1305_ietf_encrypt(
            material->ciphertext,
            &ciphertext_length,
            pairing_secret,
            crypto_kx_SESSIONKEYBYTES,
            aad,
            sizeof(aad),
            NULL,
            material->nonce,
            material->send_key) != 0 ||
        ciphertext_length != sizeof(material->ciphertext)) goto done;
    result = 0;

done:
    sodium_memzero(client_secret_key, sizeof(client_secret_key));
    sodium_memzero(aad, sizeof(aad));
    if (result != 0) openpay_pairing_v2_material_dispose(material);
    return result;
}

void openpay_pairing_v2_material_dispose(openpay_pairing_v2_material *material) {
    if (material != NULL) sodium_memzero(material, sizeof(*material));
}
