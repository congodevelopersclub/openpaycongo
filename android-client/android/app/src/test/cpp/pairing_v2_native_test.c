#include <assert.h>
#include <string.h>

#include "pairing_v2_native.h"

static void completion_aad(
    const unsigned char intent[OPENPAY_PAIRING_V2_INTENT_BYTES],
    const unsigned char client_public_key[crypto_kx_PUBLICKEYBYTES],
    unsigned char output[OPENPAY_PAIRING_V2_REQUEST_AAD_BYTES]) {
    static const unsigned char domain[] = "openpaycongo/pairing/complete/v2";
    size_t offset = 0;
    output[offset++] = 0;
    output[offset++] = sizeof(domain) - 1;
    memcpy(output + offset, domain, sizeof(domain) - 1);
    offset += sizeof(domain) - 1;
    output[offset++] = 0;
    output[offset++] = OPENPAY_PAIRING_V2_INTENT_BYTES;
    memcpy(output + offset, intent, OPENPAY_PAIRING_V2_INTENT_BYTES);
    offset += OPENPAY_PAIRING_V2_INTENT_BYTES;
    output[offset++] = 0;
    output[offset++] = crypto_kx_PUBLICKEYBYTES;
    memcpy(output + offset, client_public_key, crypto_kx_PUBLICKEYBYTES);
    assert(offset + crypto_kx_PUBLICKEYBYTES == OPENPAY_PAIRING_V2_REQUEST_AAD_BYTES);
}

int main(void) {
    unsigned char intent[OPENPAY_PAIRING_V2_INTENT_BYTES] = {0};
    unsigned char secret[crypto_kx_SESSIONKEYBYTES] = {0};
    unsigned char server_public_key[crypto_kx_PUBLICKEYBYTES];
    unsigned char server_secret_key[crypto_kx_SECRETKEYBYTES];
    unsigned char server_receive_key[crypto_kx_SESSIONKEYBYTES];
    unsigned char server_send_key[crypto_kx_SESSIONKEYBYTES];
    unsigned char plaintext[crypto_kx_SESSIONKEYBYTES];
    unsigned char aad[OPENPAY_PAIRING_V2_REQUEST_AAD_BYTES];
    openpay_pairing_v2_material material;
    unsigned long long plaintext_length = 0;

    for (size_t index = 0; index < sizeof(intent); index += 1) intent[index] = (unsigned char) index;
    for (size_t index = 0; index < sizeof(secret); index += 1) secret[index] = (unsigned char) (0xa0 + index);
    assert(sodium_init() >= 0);
    assert(crypto_kx_keypair(server_public_key, server_secret_key) == 0);
    assert(openpay_pairing_v2_begin(intent, server_public_key, secret, &material) == 0);
    assert(crypto_kx_server_session_keys(
        server_receive_key,
        server_send_key,
        server_public_key,
        server_secret_key,
        material.client_public_key) == 0);
    assert(sodium_memcmp(material.send_key, server_receive_key, sizeof(material.send_key)) == 0);
    assert(sodium_memcmp(material.receive_key, server_send_key, sizeof(material.receive_key)) == 0);
    completion_aad(intent, material.client_public_key, aad);
    assert(crypto_aead_xchacha20poly1305_ietf_decrypt(
        plaintext,
        &plaintext_length,
        NULL,
        material.ciphertext,
        sizeof(material.ciphertext),
        aad,
        sizeof(aad),
        material.nonce,
        server_receive_key) == 0);
    assert(plaintext_length == sizeof(secret));
    assert(sodium_memcmp(plaintext, secret, sizeof(secret)) == 0);
    aad[sizeof(aad) - 1] ^= 1;
    assert(crypto_aead_xchacha20poly1305_ietf_decrypt(
        plaintext,
        &plaintext_length,
        NULL,
        material.ciphertext,
        sizeof(material.ciphertext),
        aad,
        sizeof(aad),
        material.nonce,
        server_receive_key) != 0);
    openpay_pairing_v2_material_dispose(&material);
    for (size_t index = 0; index < sizeof(material); index += 1) assert(((unsigned char *) &material)[index] == 0);
    sodium_memzero(intent, sizeof(intent));
    sodium_memzero(secret, sizeof(secret));
    sodium_memzero(server_public_key, sizeof(server_public_key));
    sodium_memzero(server_secret_key, sizeof(server_secret_key));
    sodium_memzero(server_receive_key, sizeof(server_receive_key));
    sodium_memzero(server_send_key, sizeof(server_send_key));
    sodium_memzero(plaintext, sizeof(plaintext));
    sodium_memzero(aad, sizeof(aad));
    return 0;
}
