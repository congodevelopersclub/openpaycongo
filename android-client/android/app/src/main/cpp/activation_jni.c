#include <jni.h>
#include <sodium.h>

JNIEXPORT jbyteArray JNICALL Java_com_congodeveloperclub_opencongopay_pairing_PairingActivationNative_decrypt(
    JNIEnv *env, jobject self, jbyteArray receive_key, jbyteArray nonce, jbyteArray ciphertext, jbyteArray aad) {
    (void) self;
    if (sodium_init() < 0 || receive_key == NULL || nonce == NULL || ciphertext == NULL || aad == NULL ||
        (*env)->GetArrayLength(env, receive_key) != crypto_aead_xchacha20poly1305_ietf_KEYBYTES ||
        (*env)->GetArrayLength(env, nonce) != crypto_aead_xchacha20poly1305_ietf_NPUBBYTES) return NULL;
    const jsize ciphertext_length = (*env)->GetArrayLength(env, ciphertext);
    if (ciphertext_length < crypto_aead_xchacha20poly1305_ietf_ABYTES || ciphertext_length > 8192) return NULL;
    jbyte *key_bytes = (*env)->GetByteArrayElements(env, receive_key, NULL);
    jbyte *nonce_bytes = (*env)->GetByteArrayElements(env, nonce, NULL);
    jbyte *ciphertext_bytes = (*env)->GetByteArrayElements(env, ciphertext, NULL);
    jbyte *aad_bytes = (*env)->GetByteArrayElements(env, aad, NULL);
    unsigned long long plaintext_length = 0;
    unsigned char *plaintext = sodium_malloc((size_t) ciphertext_length);
    jbyteArray result = NULL;
    if (key_bytes == NULL || nonce_bytes == NULL || ciphertext_bytes == NULL || aad_bytes == NULL || plaintext == NULL) goto done;
    if (crypto_aead_xchacha20poly1305_ietf_decrypt(plaintext, &plaintext_length, NULL,
            (unsigned char *) ciphertext_bytes, (unsigned long long) ciphertext_length,
            (unsigned char *) aad_bytes, (unsigned long long) (*env)->GetArrayLength(env, aad),
            (unsigned char *) nonce_bytes, (unsigned char *) key_bytes) != 0 || plaintext_length > 8192) goto done;
    result = (*env)->NewByteArray(env, (jsize) plaintext_length);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, (jsize) plaintext_length, (jbyte *) plaintext);
done:
    if (plaintext != NULL) { sodium_memzero(plaintext, (size_t) ciphertext_length); sodium_free(plaintext); }
    if (key_bytes != NULL) { sodium_memzero(key_bytes, crypto_aead_xchacha20poly1305_ietf_KEYBYTES); (*env)->ReleaseByteArrayElements(env, receive_key, key_bytes, JNI_ABORT); }
    if (nonce_bytes != NULL) (*env)->ReleaseByteArrayElements(env, nonce, nonce_bytes, JNI_ABORT);
    if (ciphertext_bytes != NULL) (*env)->ReleaseByteArrayElements(env, ciphertext, ciphertext_bytes, JNI_ABORT);
    if (aad_bytes != NULL) (*env)->ReleaseByteArrayElements(env, aad, aad_bytes, JNI_ABORT);
    return result;
}

JNIEXPORT jbyteArray JNICALL Java_com_congodeveloperclub_opencongopay_pairing_MobileEnvelopeNative_seal(
    JNIEnv *env, jobject self, jbyteArray send_key, jbyteArray nonce, jbyteArray plaintext, jbyteArray aad) {
    (void) self;
    if (sodium_init() < 0 || send_key == NULL || nonce == NULL || plaintext == NULL || aad == NULL ||
        (*env)->GetArrayLength(env, send_key) != crypto_aead_xchacha20poly1305_ietf_KEYBYTES ||
        (*env)->GetArrayLength(env, nonce) != crypto_aead_xchacha20poly1305_ietf_NPUBBYTES) return NULL;
    const jsize plaintext_length = (*env)->GetArrayLength(env, plaintext);
    if (plaintext_length < 2 || plaintext_length > 8320) return NULL;
    jbyte *key_bytes = (*env)->GetByteArrayElements(env, send_key, NULL);
    jbyte *nonce_bytes = (*env)->GetByteArrayElements(env, nonce, NULL);
    jbyte *plaintext_bytes = (*env)->GetByteArrayElements(env, plaintext, NULL);
    jbyte *aad_bytes = (*env)->GetByteArrayElements(env, aad, NULL);
    const size_t ciphertext_size = (size_t) plaintext_length + crypto_aead_xchacha20poly1305_ietf_ABYTES;
    unsigned char *ciphertext = sodium_malloc(ciphertext_size);
    unsigned long long ciphertext_length = 0;
    jbyteArray result = NULL;
    if (key_bytes == NULL || nonce_bytes == NULL || plaintext_bytes == NULL || aad_bytes == NULL || ciphertext == NULL) goto done;
    if (crypto_aead_xchacha20poly1305_ietf_encrypt(ciphertext, &ciphertext_length,
            (const unsigned char *) plaintext_bytes, (unsigned long long) plaintext_length,
            (const unsigned char *) aad_bytes, (unsigned long long) (*env)->GetArrayLength(env, aad), NULL,
            (const unsigned char *) nonce_bytes, (const unsigned char *) key_bytes) != 0 ||
        ciphertext_length != ciphertext_size) goto done;
    result = (*env)->NewByteArray(env, (jsize) ciphertext_length);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, (jsize) ciphertext_length, (const jbyte *) ciphertext);
done:
    if (ciphertext != NULL) { sodium_memzero(ciphertext, ciphertext_size); sodium_free(ciphertext); }
    if (key_bytes != NULL) { sodium_memzero(key_bytes, crypto_aead_xchacha20poly1305_ietf_KEYBYTES); (*env)->ReleaseByteArrayElements(env, send_key, key_bytes, JNI_ABORT); }
    if (nonce_bytes != NULL) (*env)->ReleaseByteArrayElements(env, nonce, nonce_bytes, JNI_ABORT);
    if (plaintext_bytes != NULL) { sodium_memzero(plaintext_bytes, (size_t) plaintext_length); (*env)->ReleaseByteArrayElements(env, plaintext, plaintext_bytes, JNI_ABORT); }
    if (aad_bytes != NULL) (*env)->ReleaseByteArrayElements(env, aad, aad_bytes, JNI_ABORT);
    return result;
}
