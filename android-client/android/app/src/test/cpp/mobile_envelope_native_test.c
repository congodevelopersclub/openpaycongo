#include <assert.h>
#include <string.h>
#include <sodium.h>

int main(void) {
    unsigned char key[crypto_aead_xchacha20poly1305_ietf_KEYBYTES];
    unsigned char nonce[crypto_aead_xchacha20poly1305_ietf_NPUBBYTES];
    const unsigned char aad[] = {
        0x00, 0x27, 'o','p','e','n','p','a','y','c','o','n','g','o','/','m','o','b','i','l','e','/',
        'r','e','q','u','e','s','t','-','e','n','v','e','l','o','p','e','/','v','1',
        0x12,0x3e,0x45,0x67,0xe8,0x9b,0x12,0xd3,0xa4,0x56,0x42,0x66,0x14,0x17,0x40,0x00,
        0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,
    };
    const unsigned char changed_aad[] = {
        0x00, 0x27, 'o','p','e','n','p','a','y','c','o','n','g','o','/','m','o','b','i','l','e','/',
        'r','e','q','u','e','s','t','-','e','n','v','e','l','o','p','e','/','v','1',
        0x12,0x3e,0x45,0x67,0xe8,0x9b,0x12,0xd3,0xa4,0x56,0x42,0x66,0x14,0x17,0x40,0x00,
        0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x02,
    };
    const unsigned char plaintext[] = "{\"version\":1,\"operation\":\"deposit\",\"payload\":{\"customer_lookup_identifier\":\"fixture-customer\",\"provider_reference\":\"fixture-reference\",\"amount_minor\":1250,\"currency\":\"CDF\",\"provider_occurred_at\":\"2026-01-02T03:04:05Z\"}}";
    unsigned char ciphertext[sizeof(plaintext) + crypto_aead_xchacha20poly1305_ietf_ABYTES];
    unsigned char opened[sizeof(plaintext)];
    char encoded[sizeof(ciphertext) * 2 + 1];
    unsigned long long ciphertext_length = 0;
    unsigned long long opened_length = 0;

    assert(sodium_init() >= 0);
    for (size_t i = 0; i < sizeof key; i++) key[i] = (unsigned char) i;
    for (size_t i = 0; i < sizeof nonce; i++) nonce[i] = (unsigned char) i;
    assert(crypto_aead_xchacha20poly1305_ietf_encrypt(ciphertext, &ciphertext_length,
        plaintext, sizeof plaintext - 1, aad, sizeof aad, NULL, nonce, key) == 0);
    assert(ciphertext_length == sizeof plaintext - 1 + crypto_aead_xchacha20poly1305_ietf_ABYTES);
    sodium_bin2hex(encoded, sizeof encoded, ciphertext, ciphertext_length);
    assert(strcmp(encoded, "e5e0791ae2a1e4c15d661cffe770c7982e3549d194b973c945385bd34dc286302a249ac631067008baf4ca7bf55a710104c996362a1189466bf4fc56fa971b9dd64591c761ff0de05e7d1ce33d0c71d62c7279b7d0704eed39fd5805933d513c1c6b03257375029497685bb24164333f551df5d980320310bc033b0215ecbf8c60c00c2eae9567f8e3f5582668c5a2ee9f2a06f228ae1e3393822158ea92bd9245dfef6b8e27e1b6d33f7a6f76d1f776a2c38c9a21d230546ca602dc68590eb38e43af8fcf2b2fd45e33af3f14f9e83b8949ed5c97e51fe53ad31c447a46fade89542046c601f7f6ac34c1") == 0);
    assert(crypto_aead_xchacha20poly1305_ietf_decrypt(opened, &opened_length, NULL,
        ciphertext, ciphertext_length, aad, sizeof aad, nonce, key) == 0);
    assert(opened_length == sizeof plaintext - 1);
    assert(memcmp(opened, plaintext, sizeof plaintext - 1) == 0);
    assert(crypto_aead_xchacha20poly1305_ietf_decrypt(opened, &opened_length, NULL,
        ciphertext, ciphertext_length, changed_aad, sizeof changed_aad, nonce, key) != 0);
    nonce[0] ^= 1;
    assert(crypto_aead_xchacha20poly1305_ietf_decrypt(opened, &opened_length, NULL,
        ciphertext, ciphertext_length, aad, sizeof aad, nonce, key) != 0);
    sodium_memzero(key, sizeof key);
    sodium_memzero(opened, sizeof opened);
    return 0;
}
