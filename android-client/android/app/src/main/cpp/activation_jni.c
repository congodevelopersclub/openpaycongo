#include <jni.h>
#include <sodium.h>
#include "pairing_v2_native.h"

static jbyteArray openpay_new_byte_array(JNIEnv *env, const unsigned char *bytes, jsize length) {
    jbyteArray result = (*env)->NewByteArray(env, length);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, length, (const jbyte *) bytes);
    return result;
}

JNIEXPORT jobjectArray JNICALL Java_com_congodeveloperclub_opencongopay_pairing_PairingV2Native_begin(
    JNIEnv *env, jobject self, jbyteArray intent, jbyteArray server_public_key, jbyteArray pairing_secret) {
    (void) self;
    jbyte *intent_bytes = NULL;
    jbyte *server_public_key_bytes = NULL;
    jbyte *pairing_secret_bytes = NULL;
    openpay_pairing_v2_material material;
    jobjectArray result = NULL;
    jclass byte_array_class = NULL;
    jbyteArray values[5] = {NULL, NULL, NULL, NULL, NULL};

    openpay_pairing_v2_material_dispose(&material);
    if (intent == NULL || server_public_key == NULL || pairing_secret == NULL ||
        (*env)->GetArrayLength(env, intent) != OPENPAY_PAIRING_V2_INTENT_BYTES ||
        (*env)->GetArrayLength(env, server_public_key) != crypto_kx_PUBLICKEYBYTES ||
        (*env)->GetArrayLength(env, pairing_secret) != crypto_kx_SESSIONKEYBYTES) goto done;

    intent_bytes = (*env)->GetByteArrayElements(env, intent, NULL);
    server_public_key_bytes = (*env)->GetByteArrayElements(env, server_public_key, NULL);
    pairing_secret_bytes = (*env)->GetByteArrayElements(env, pairing_secret, NULL);
    if (intent_bytes == NULL || server_public_key_bytes == NULL || pairing_secret_bytes == NULL ||
        openpay_pairing_v2_begin(
            (const unsigned char *) intent_bytes,
            (const unsigned char *) server_public_key_bytes,
            (const unsigned char *) pairing_secret_bytes,
            &material) != 0) goto done;

    byte_array_class = (*env)->FindClass(env, "[B");
    if (byte_array_class == NULL) goto done;
    result = (*env)->NewObjectArray(env, 5, byte_array_class, NULL);
    if (result == NULL) goto done;
    values[0] = openpay_new_byte_array(env, material.client_public_key, sizeof(material.client_public_key));
    values[1] = openpay_new_byte_array(env, material.nonce, sizeof(material.nonce));
    values[2] = openpay_new_byte_array(env, material.ciphertext, sizeof(material.ciphertext));
    values[3] = openpay_new_byte_array(env, material.send_key, sizeof(material.send_key));
    values[4] = openpay_new_byte_array(env, material.receive_key, sizeof(material.receive_key));
    for (int i = 0; i < 5; i += 1) {
        if (values[i] == NULL) goto done;
        (*env)->SetObjectArrayElement(env, result, i, values[i]);
    }
    goto success;

done:
    result = NULL;
success:
    for (int i = 0; i < 5; i += 1) {
        if (values[i] != NULL) (*env)->DeleteLocalRef(env, values[i]);
    }
    if (byte_array_class != NULL) (*env)->DeleteLocalRef(env, byte_array_class);
    if (intent_bytes != NULL) (*env)->ReleaseByteArrayElements(env, intent, intent_bytes, JNI_ABORT);
    if (server_public_key_bytes != NULL) (*env)->ReleaseByteArrayElements(env, server_public_key, server_public_key_bytes, JNI_ABORT);
    if (pairing_secret_bytes != NULL) {
        sodium_memzero(pairing_secret_bytes, crypto_kx_SESSIONKEYBYTES);
        (*env)->ReleaseByteArrayElements(env, pairing_secret, pairing_secret_bytes, JNI_ABORT);
    }
    openpay_pairing_v2_material_dispose(&material);
    return result;
}

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
