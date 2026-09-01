import assert from 'node:assert/strict';
import { constants } from 'node:fs';
import { access, readFile, readdir } from 'node:fs/promises';
import { createHash, createPublicKey, verify } from 'node:crypto';
import test from 'node:test';
import SwaggerParser from '@apidevtools/swagger-parser';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import YAML from 'yaml';

const root = new URL('./', import.meta.url);
const asset = (relativePath) => new URL(relativePath, root);
const readJson = async (relativePath) => JSON.parse(await readFile(asset(relativePath), 'utf8'));
const decode = (value) => Buffer.from(value, 'base64url');
const field = (value) => {
  const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
  const size = Buffer.alloc(2);
  size.writeUInt16BE(bytes.length);
  return Buffer.concat([size, bytes]);
};

const qrTranscript = (qr) => Buffer.concat([
  field('openpaycongo/pairing/qr'),
  field(qr.version),
  field(qr.endpoint),
  field(decode(qr.intent_id)),
  field(decode(qr.intent_nonce)),
  field(qr.expires_at),
  field(qr.algorithms),
  field(decode(qr.enrollment_signing_public_key)),
  field(decode(qr.enrollment_signing_fingerprint)),
  field(decode(qr.server_key_agreement_public_key)),
  field(decode(qr.pairing_secret)),
  field(qr.trust_mode),
]);

test('ADR 004 fixes v2 crypto boundary and the implemented server envelope boundary', async () => {
  const adr = await readFile(asset('adr-004-secure-device-enrollment.md'), 'utf8');
  const envelope = await readFile(asset('mobile-envelope-v1.md'), 'utf8');

  assert.match(adr, /crypto_kx/i);
  assert.match(adr, /XChaCha20-Poly1305-IETF/i);
  assert.match(adr, /raw X25519 scalar multiplication, custom HKDF.*OpenSSL/i);
  assert.match(adr, /Laravel implements QR v2 issuance, completion\/replay, verified-administrator SAS confirmation, and server activation delivery/i);
  assert.match(adr, /the app retrieves only the opaque activation envelope over strict HTTPS without redirects/i);
  assert.match(adr, /official libsodium XChaCha20-Poly1305 implementation/i);
  assert.match(adr, /Laravel now implements the server half of active mobile-envelope deposit transport/i);
  assert.match(adr, /Android transport delivery, acknowledgement, revocation, rotation, and durable pairing recovery remain follow-up slices/i);
  assert.match(adr, /openpaycongo\/pairing\/activation-response\/v2/i);
  assert.match(adr, /0x002b.*exact 43-byte UTF-8 domain field/i);
  assert.match(adr, /no derived key, custom KDF, alternative AEAD, or duplicated crypto implementation/i);
  assert.match(adr, /No forward secrecy, post-compromise.*edge-compromise-resistance/i);
  assert.match(envelope, /POST \/mobile\/envelopes/i);
  assert.match(envelope, /It has no bearer credential/i);
  assert.match(envelope, /openpaycongo\/mobile\/request-envelope\/v1/i);
  assert.match(envelope, /openpaycongo\/mobile\/response-envelope\/v1/i);
  assert.match(envelope, /mobile_envelope_unavailable/i);
});

test('v2 signed QR fixture binds every field', async () => {
  const fixture = await readJson('pairing-v2.fixture.json');
  const qr = await readJson('pairing-qr.valid.json');
  assert.deepEqual(qr, fixture.qr);

  const publicBytes = decode(qr.enrollment_signing_public_key);
  const publicKey = createPublicKey({
    key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), publicBytes]),
    format: 'der',
    type: 'spki',
  });
  assert.deepEqual(createHash('sha256').update(publicBytes).digest(), decode(qr.enrollment_signing_fingerprint));
  assert.equal(verify(null, qrTranscript(qr), publicKey, decode(qr.signature)), true);

  const mutations = {
    version: '3',
    endpoint: 'https://other.example.test/v1/pairing/complete',
    intent_id: 'AAECAwQFBgcICQoLDA0ODw',
    intent_nonce: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    expires_at: '2026-09-01T12:00:01Z',
    algorithms: 'X25519-HKDF-SHA256-AES-256-GCM+Ed25519',
    enrollment_signing_fingerprint: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    enrollment_signing_public_key: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    server_key_agreement_public_key: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    pairing_secret: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    trust_mode: 'first_use_requires_sas',
  };
  for (const [name, replacement] of Object.entries(mutations)) {
    assert.equal(
      verify(null, qrTranscript({ ...qr, [name]: replacement }), publicKey, decode(qr.signature)),
      false,
      `${name} mutation retained signature`,
    );
  }
});

test('v2 public schemas reject old wire shape and plaintext', async () => {
  const ajv = new Ajv({ allErrors: true, strict: true });
  addFormats(ajv);
  const cases = [
    ['pairing-qr.schema.json', 'pairing-qr.valid.json', 'pairing-qr.invalid.json'],
    ['pairing-completion.schema.json', 'pairing-completion.valid.json', 'pairing-completion.invalid.json'],
    [
      'pairing-completion-result.schema.json',
      'pairing-completion-result.valid.json',
      'pairing-completion-result.invalid.json',
    ],
  ];
  for (const [schemaPath, validPath, invalidPath] of cases) {
    const validate = ajv.compile(await readJson(schemaPath));
    assert.equal(validate(await readJson(validPath)), true, ajv.errorsText(validate.errors));
    assert.equal(validate(await readJson(invalidPath)), false, `${invalidPath} accepted`);
  }
});

test('v2 fixture fixes directional KX and exact AAD', async () => {
  const fixture = await readJson('pairing-v2.fixture.json');
  const { key_exchange: keys, completion, response } = fixture;
  assert.equal(keys.client_send_key, keys.server_receive_key);
  assert.equal(keys.client_receive_key, keys.server_send_key);
  assert.equal(completion.intent_id, fixture.qr.intent_id);
  assert.equal(completion.client_public_key, keys.client_public_key);
  assert.equal(
    completion.aad,
    Buffer.concat([
      field('openpaycongo/pairing/complete/v2'),
      field(decode(completion.intent_id)),
      field(decode(completion.client_public_key)),
    ]).toString('base64url'),
  );
  assert.equal(
    response.aad,
    Buffer.concat([
      field('openpaycongo/pairing/complete-response/v2'),
      field(decode(completion.intent_id)),
    ]).toString('base64url'),
  );
  assert.equal(decode(completion.nonce).length, 24);
  assert.equal(decode(completion.ciphertext).length, 48);
  assert.equal(decode(response.nonce).length, 24);
  assert.equal(decode(response.ciphertext).length, 85);
});

test('v2 endpoint grammar remains canonical', async () => {
  const ajv = new Ajv({ allErrors: true, strict: true });
  addFormats(ajv);
  const validate = ajv.compile(await readJson('pairing-qr.schema.json'));
  const qr = await readJson('pairing-qr.valid.json');
  for (const endpoint of [
    'https://PAIRING.example.test/v1/pairing/complete',
    'https://127.0.0.1/v1/pairing/complete',
    'https://pairing.example.test:08443/v1/pairing/complete',
    'https://pairing.example.test/v1/pairing/%63omplete',
    'https://pairing.example.test/v1/pairing/complete/',
  ]) {
    assert.equal(validate({ ...qr, endpoint }), false, `${endpoint} escaped grammar`);
  }
  assert.equal(validate({ ...qr, endpoint: 'https://pairing.example.test:8443/v1/pairing/complete' }), true);
});

test('legacy v1 pairing assets are gone; v2 test plan remains', async () => {
  const names = new Set(await readdir(root));
  for (const legacy of [
    'pairing-key-schedule.vector.json',
    'pairing-protocol.vector.json',
    'pairing-proof.schema.json',
    'pairing-response-plaintext.schema.json',
    'pairing-signed-qr.vector.json',
  ]) {
    assert.equal(names.has(legacy), false, `${legacy} looks current`);
  }
  await access(asset('pairing-v2-test-plan.md'), constants.R_OK);
});

test('OpenAPI exposes confirmed pairing slices and the implemented server envelope', async () => {
  await SwaggerParser.validate(asset('openapi.yaml').pathname);
  const openapi = YAML.parse(await readFile(asset('openapi.yaml'), 'utf8'));
  const complete = openapi.paths['/v1/pairing/complete'].post;
  assert.equal(complete['x-openpay-status'], 'implemented-initial-slice');
  assert.deepEqual(Object.keys(complete.responses), ['201', '404', '429', '503', 'default']);
  assert.equal(complete.responses['429'].$ref, '#/components/responses/PairingRateLimited');
  assert.equal(
    openapi.paths['/v1/pairing/intents/{intent_id}/confirmation'].get['x-openpay-status'],
    'implemented-initial-slice',
  );
  assert.equal(
    openapi.paths['/v1/pairing/intents/{intent_id}/confirmation'].post['x-openpay-status'],
    'implemented-initial-slice',
  );
  const activation = openapi.paths['/v1/pairing/intents/{intent_id}/activation'].get;
  assert.equal(activation['x-openpay-status'], 'implemented-server-slice');
  assert.deepEqual(Object.keys(activation.responses), ['200', '404', '429', '503', 'default']);
  assert.equal(
    activation.responses['200'].content['application/json'].schema.$ref,
    '#/components/schemas/PairingActivationEnvelope',
  );
  assert.deepEqual(
    Object.keys(openapi.components.schemas.PairingActivationEnvelope.properties),
    ['version', 'nonce', 'ciphertext'],
  );
  const envelope = openapi.paths['/mobile/envelopes'].post;
  assert.equal(envelope['x-openpay-status'], 'implemented-server-slice');
  assert.deepEqual(envelope.security, []);
  assert.deepEqual(Object.keys(envelope.responses), ['200', '201', '404', '409']);
  assert.equal(envelope.requestBody.content['application/json'].schema.$ref, '#/components/schemas/MobileEnvelopeRequest');
  assert.equal(envelope.responses['404'].content['application/json'].schema.$ref, '#/components/schemas/MobileEnvelopeUnavailable');
  assert.equal(openapi.components.headers.MobileEnvelopeNoStore.schema.const, 'no-store, private');
  for (const status of ['200', '201', '404', '409']) {
    assert.equal(envelope.responses[status].headers['Cache-Control'].$ref, '#/components/headers/MobileEnvelopeNoStore');
  }
  assert.deepEqual(Object.keys(openapi.components.schemas.MobileEnvelopeRequest.properties), ['version', 'installation_id', 'counter', 'nonce', 'ciphertext']);
  assert.deepEqual(Object.keys(openapi.components.schemas.MobileEnvelopeResult.properties), ['version', 'nonce', 'ciphertext']);
  assert.equal(openapi.paths['/v1/pairing/device-status'].get['x-openpay-status'], 'planned');
});

test('activation response AAD has the fixed 43-byte domain field', () => {
  const domain = 'openpaycongo/pairing/activation-response/v2';
  const encoded = field(domain);

  assert.equal(Buffer.byteLength(domain, 'utf8'), 43);
  assert.equal(encoded.readUInt16BE(0), 43);
  assert.equal(encoded.subarray(2).toString('utf8'), domain);
});
