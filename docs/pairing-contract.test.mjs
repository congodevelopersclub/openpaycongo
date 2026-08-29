import assert from 'node:assert/strict';
import { createDecipheriv, createHash, createHmac, createPrivateKey, createPublicKey, diffieHellman, hkdfSync, sign, verify } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import YAML from 'yaml';

const root = new URL('./', import.meta.url);
const asset = (relativePath) => new URL(relativePath, root);
const readJson = async (relativePath) => JSON.parse(
  await readFile(asset(relativePath), 'utf8'),
);

test('pairing contract states the bootstrap trust boundary without edge-resistance claims', async () => {
  const adr = await readFile(asset('adr-004-secure-device-enrollment.md'), 'utf8');

  assert.match(adr, /hosting edge and administrator UI delivery are trusted during bootstrap/i);
  assert.match(adr, /does not protect against a compromised hosting edge, administrator UI, or OAuth session/i);
  assert.match(adr, /same hosting edge cannot detect malicious edge replacement/i);
  assert.doesNotMatch(adr, /blind HTTPS prox(?:y|ies)/i);
});

test('pairing contract makes key destruction and protector failure semantics normative', async () => {
  const adr = await readFile(asset('adr-004-secure-device-enrollment.md'), 'utf8');

  assert.match(adr, /clears the protected ephemeral X25519 private key/i);
  assert.match(adr, /preserving\s+non-secret replay metadata/i);
  assert.match(adr, /opaque protected material\s+of at most 1024 bytes/i);
  assert.match(adr, /unique nonce/i);
  assert.match(adr, /unknown key ID, malformed or oversized blobs, wrong AAD, or integrity\s+failure/i);
  assert.match(adr, /unique, fixed-size reservation under the independent in-flight bound/i);
  assert.match(adr, /Reservation alone never increments the invalid-proof counter/i);
  assert.match(adr, /repeated cleanup is idempotent/i);
  assert.match(adr, /in-flight bound rejects additional work without\s+clearing the intent key/i);
  assert.match(adr, /first terminal decision wins/i);
});

test('signed QR vector binds the public key, fingerprint, canonical timestamp, and every field', async () => {
  const publicVector = await readJson('pairing-signed-qr.vector.json');
  const { qr } = publicVector;
  assert.deepEqual(await readJson('pairing-qr.valid.json'), qr, 'positive QR fixture is not the signed vector');
  const decode = (value) => Buffer.from(value, 'base64url');
  const field = (value) => {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
    const size = Buffer.alloc(2);
    size.writeUInt16BE(bytes.length);
    return Buffer.concat([size, bytes]);
  };
  const transcript = (value) => Buffer.concat([
    field('openpaycongo/pairing/qr'),
    field(value.version),
    field(value.endpoint),
    field(decode(value.intent_id)),
    field(decode(value.intent_nonce)),
    field(value.expires_at),
    field(value.algorithms),
    field(decode(value.enrollment_signing_public_key)),
    field(decode(value.enrollment_signing_fingerprint)),
    field(decode(value.server_key_agreement_public_key)),
    field(value.trust_mode),
  ]);
  const publicBytes = decode(qr.enrollment_signing_public_key);
  const publicKey = createPublicKey({
    key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), publicBytes]),
    format: 'der',
    type: 'spki',
  });

  assert.match(qr.expires_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.deepEqual(
    createHash('sha256').update(publicBytes).digest(),
    decode(qr.enrollment_signing_fingerprint),
  );
  assert.equal(verify(null, transcript(qr), publicKey, decode(qr.signature)), true);

  const mutations = {
    version: '2',
    endpoint: 'https://other.example.test/v1/pairing/complete',
    intent_id: 'AQECAwQFBgcICQoLDA0ODw',
    intent_nonce: 'AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    expires_at: '2026-08-10T09:32:01Z',
    algorithms: 'X25519-HKDF-SHA256-AES-256-GCM',
    enrollment_signing_public_key: 'AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    enrollment_signing_fingerprint: 'AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    server_key_agreement_public_key: 'AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    trust_mode: 'first_use_requires_sas',
  };
  for (const [name, replacement] of Object.entries(mutations)) {
    const changed = { ...qr, [name]: replacement };
    assert.equal(
      verify(null, transcript(changed), publicKey, decode(qr.signature)),
      false,
      `${name} mutation retained a valid signature`,
    );
  }
});

test('pairing QR and completion fixtures preserve the public security boundary', async () => {
  const ajv = new Ajv({ allErrors: true, strict: true });
  addFormats(ajv);
  const cases = [
    ['pairing-qr.schema.json', 'pairing-qr.valid.json', 'pairing-qr.invalid.json'],
    [
      'pairing-completion.schema.json',
      'pairing-completion.valid.json',
      'pairing-completion.invalid.json',
    ],
    ['pairing-proof.schema.json', 'pairing-proof.valid.json', 'pairing-proof.invalid.json'],
    [
      'pairing-response-plaintext.schema.json',
      'pairing-response-plaintext.valid.json',
      'pairing-response-plaintext.invalid.json',
    ],
  ];

  for (const [schemaPath, validPath, invalidPath] of cases) {
    const validate = ajv.compile(await readJson(schemaPath));
    assert.equal(validate(await readJson(validPath)), true, ajv.errorsText(validate.errors));
    assert.equal(validate(await readJson(invalidPath)), false, `${invalidPath} must be rejected`);
  }
});

test('canonical completion endpoint grammar is identical at the public schema boundary', async () => {
  const ajv = new Ajv({ allErrors: true, strict: true }); addFormats(ajv);
  const validate = ajv.compile(await readJson('pairing-qr.schema.json'));
  const qr = await readJson('pairing-qr.valid.json');
  for (const endpoint of [
    'https://PAIRING.example.test/v1/pairing/complete',
    'https://127.0.0.1/v1/pairing/complete',
    'https://pairing.example.test:08443/v1/pairing/complete',
    'https://pairing.example.test/v1/pairing/%63omplete',
    'https://pairing.example.test/v1/pairing/complete/',
  ]) {
    assert.equal(validate({ ...qr, endpoint }), false, `${endpoint} escaped canonical grammar`);
  }
  assert.equal(validate({ ...qr, endpoint: 'https://pairing.example.test:8443/v1/pairing/complete' }), true);
});

test('pairing key schedule and unbiased short code match the portable vector', async () => {
  const vector = await readJson('pairing-key-schedule.vector.json');
  const fromHex = (value) => Buffer.from(value, 'hex');
  const field = (value) => {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
    assert.ok(bytes.length <= 65535, 'transcript field exceeds uint16');
    const size = Buffer.alloc(2);
    size.writeUInt16BE(bytes.length);
    return Buffer.concat([size, bytes]);
  };
  const intentID = fromHex(vector.intent_id_hex);
  const intentNonce = fromHex(vector.intent_nonce_hex);
  const signingFingerprint = fromHex(vector.enrollment_signing_fingerprint_hex);
  const serverPublic = fromHex(vector.server_key_agreement_public_key_hex);
  const clientPublic = fromHex(vector.client_key_agreement_public_key_hex);
  const derive = (label, length) => {
    const info = createHash('sha256').update(Buffer.concat([
      field('openpaycongo/pairing/key'),
      field(vector.version),
      field(vector.algorithms),
      field(label),
      field(intentID),
      field(intentNonce),
      field(signingFingerprint),
      field(serverPublic),
      field(clientPublic),
    ])).digest();
    return Buffer.from(hkdfSync(
      'sha256',
      fromHex(vector.shared_secret_hex),
      intentNonce,
      info,
      length,
    ));
  };

  assert.equal(derive('c2s', 32).toString('hex'), vector.expected.c2s_hex);
  assert.equal(derive('s2c-aead', 32).toString('hex'), vector.expected.s2c_aead_hex);
  assert.equal(derive('s2c-confirm', 32).toString('hex'), vector.expected.s2c_confirm_hex);
  assert.equal(derive('install-root', 32).toString('hex'), vector.expected.install_root_hex);

  const candidates = derive('short-authentication-code', 16);
  const rejectionLimit = 4_294_000_000;
  let shortCode;
  for (let offset = 0; offset < 16; offset += 4) {
    const candidate = candidates.readUInt32BE(offset);
    if (candidate < rejectionLimit) {
      shortCode = String(candidate % 1_000_000).padStart(6, '0');
      break;
    }
  }
  assert.equal(shortCode, vector.expected.short_authentication_code);
});

test('full protocol vector independently verifies X25519, HKDF, Ed25519 proof, both AEADs, and confirmation', async () => {
  const vector = await readJson('pairing-protocol.vector.json');
  const d = (value) => Buffer.from(value, 'base64url');
  const h = (value) => Buffer.from(value, 'hex');
  const field = (value) => {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value);
    const size = Buffer.alloc(2); size.writeUInt16BE(bytes.length);
    return Buffer.concat([size, bytes]);
  };
  const transcript = (...values) => Buffer.concat(values.map(field));
  const x25519Private = (raw) => createPrivateKey({
    key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), raw]),
    format: 'der', type: 'pkcs8',
  });
  const clientPrivate = x25519Private(h(vector.inputs.client_private_hex));
  const serverPrivate = x25519Private(h(vector.inputs.server_private_hex));
  const rawPublic = (privateKey) => createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(-32);
  assert.equal(rawPublic(serverPrivate).toString('base64url'), vector.inputs.server_public);
  assert.equal(rawPublic(clientPrivate).toString('base64url'), vector.inputs.client_public);
  const shared = diffieHellman({ privateKey: clientPrivate, publicKey: createPublicKey(serverPrivate) });
  assert.equal(shared.toString('hex'), vector.expected.shared_secret_hex);
  const key = (label) => Buffer.from(hkdfSync(
    'sha256', shared, d(vector.inputs.intent_nonce),
    createHash('sha256').update(transcript(
      'openpaycongo/pairing/key', vector.version, vector.algorithms, label,
      d(vector.inputs.intent_id), d(vector.inputs.intent_nonce),
      d(vector.inputs.enrollment_signing_fingerprint), d(vector.inputs.server_public),
      d(vector.inputs.client_public),
    )).digest(), 32,
  ));
  const c2s = key('c2s');
  const s2cAead = key('s2c-aead');
  const s2cConfirm = key('s2c-confirm');
  assert.equal(c2s.toString('hex'), vector.expected.c2s_hex);
  assert.equal(s2cAead.toString('hex'), vector.expected.s2c_aead_hex);
  assert.equal(s2cConfirm.toString('hex'), vector.expected.s2c_confirm_hex);
  assert.equal(key('install-root').toString('hex'), vector.expected.install_root_hex);
  const open = (keyBytes, nonce, ciphertext, aad) => {
    const sealed = d(ciphertext); const tag = sealed.subarray(-16);
    const decipher = createDecipheriv('aes-256-gcm', keyBytes, d(nonce));
    decipher.setAAD(aad); decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(sealed.subarray(0, -16)), decipher.final()]);
  };
  const completionAad = transcript(
    'openpaycongo/pairing/completion-aad', vector.version, vector.algorithms,
    d(vector.inputs.intent_id), d(vector.inputs.intent_nonce),
    d(vector.inputs.enrollment_signing_fingerprint), d(vector.inputs.server_public),
    d(vector.inputs.client_public),
  );
  const proof = JSON.parse(open(c2s, vector.inputs.c2s_nonce, vector.expected.c2s_ciphertext, completionAad));
  assert.deepEqual(proof, vector.expected.proof_plaintext);
  const devicePublic = createPublicKey({
    key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), d(vector.inputs.device_signing_public)]),
    format: 'der', type: 'spki',
  });
  const devicePrivate = createPrivateKey({
    key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), h(vector.inputs.device_signing_seed_hex)]),
    format: 'der', type: 'pkcs8',
  });
  assert.equal(rawPublic(devicePrivate).toString('base64url'), vector.inputs.device_signing_public);
  const proofTranscript = transcript(
    'openpaycongo/pairing/device-proof', vector.version, vector.algorithms,
    d(vector.inputs.intent_id), d(vector.inputs.intent_nonce),
    d(vector.inputs.enrollment_signing_fingerprint), vector.inputs.install_id,
    d(vector.inputs.client_public), d(vector.inputs.device_signing_public),
  );
  assert.equal(verify(null, proofTranscript, devicePublic, d(proof.signature)), true);
  assert.equal(sign(null, proofTranscript, devicePrivate).toString('base64url'), vector.expected.device_proof_signature);
  const responseAad = transcript('openpaycongo/pairing/completion-response', vector.version, d(vector.inputs.device_id));
  const response = JSON.parse(open(s2cAead, vector.inputs.s2c_nonce, vector.expected.s2c_ciphertext, responseAad));
  assert.deepEqual(response, vector.expected.response_plaintext);
  assert.equal(createHmac('sha256', s2cConfirm).update(responseAad).digest('base64url'), response.key_confirmation);
});

test('OpenAPI exposes bounded pairing and administrator confirmation entry points', async () => {
  const source = await readFile(asset('openapi.yaml'), 'utf8');
  const contract = YAML.parse(source);
  const issue = contract.paths['/v1/pairing/intents'].post;
  const complete = contract.paths['/v1/pairing/complete'].post;
  const confirmationPath = contract.paths['/v1/pairing/intents/{intent_id}/confirmation'];
  const confirmationState = confirmationPath.get;
  const confirm = confirmationPath.post;

  assert.deepEqual(issue.security, [{ AdministratorOAuth: ['pairing:intent:create'] }]);
  assert.deepEqual(complete.security, []);
  assert.deepEqual(confirmationState.security, [{ AdministratorOAuth: ['pairing:confirm'] }]);
  assert.deepEqual(confirm.security, [{ AdministratorOAuth: ['pairing:confirm'] }]);
  assert.equal(
    Object.hasOwn(
      contract.components.schemas.PairingConfirmationPending.properties,
      'short_authentication_code',
    ),
    true,
  );
  const confirmationProperties = confirm.requestBody.content['application/json'].schema.properties;
  assert.equal(Object.hasOwn(confirmationProperties, 'short_authentication_code'), false);
  assert.equal(
    complete.requestBody.content['application/json'].schema.$ref,
    './pairing-completion.schema.json',
  );
  assert.equal(
    complete.responses['201'].content['application/json'].schema.$ref,
    './pairing-completion-result.schema.json',
  );
});

test('administrator pairing states discriminate SAS exposure and forbid caching', async () => {
  const source = await readFile(asset('openapi.yaml'), 'utf8');
  const contract = YAML.parse(source);
  const issue = contract.paths['/v1/pairing/intents'].post;
  const confirmationPath = contract.paths['/v1/pairing/intents/{intent_id}/confirmation'];
  const readState = confirmationPath.get;
  const confirm = confirmationPath.post;
  const pending = contract.components.schemas.PairingConfirmationPending;
  const terminal = contract.components.schemas.PairingConfirmationTerminal;

  assert.equal(issue.responses['201'].headers['Cache-Control'].schema.const, 'private, no-store');
  assert.equal(readState.responses['200'].headers['Cache-Control'].schema.const, 'private, no-store');
  assert.equal(confirm.responses['200'].headers['Cache-Control'].schema.const, 'private, no-store');
  assert.equal(confirm.responses['409'].headers['Cache-Control'].schema.const, 'private, no-store');
  assert.ok(pending.required.includes('short_authentication_code'));
  assert.equal(pending.properties.status.const, 'pending_confirmation');
  assert.equal(Object.hasOwn(terminal.properties, 'short_authentication_code'), false);
  assert.deepEqual(terminal.properties.status.enum, ['active', 'revoked', 'expired']);
  const confirmationProperties = confirm.requestBody.content['application/json'].schema.properties;
  assert.deepEqual(Object.keys(confirmationProperties).sort(), ['decision', 'reason', 'request_id']);
});

test('phone terminal status is encrypted-completion-bearer bound and all pairing responses are no-store', async () => {
  const contract = YAML.parse(await readFile(new URL('openapi.yaml', root), 'utf8'));
  const status = contract.paths['/v1/pairing/device-status'];
  assert.deepEqual(status.get.security, [{ PairingStatusBearer: [] }]);
  assert.deepEqual(status.post.security, [{ PairingStatusBearer: [] }]);
  assert.deepEqual(status.post.requestBody.content['application/json'].schema.properties.status.enum,
    ['active', 'revoked', 'expired']);
  assert.equal(contract.components.securitySchemes.PairingStatusBearer.scheme, 'bearer');

  const unavailable = contract.components.responses.PairingUnavailable;
  const unavailableSchema = unavailable.content['application/problem+json'].schema;
  assert.equal(unavailableSchema.additionalProperties, false);
  assert.equal(unavailableSchema.properties.code.const, 'pairing_unavailable');
  assert.equal(unavailableSchema.properties.status.const, 404);
  assert.equal('detail' in unavailableSchema.properties, false);

  const unavailableRef = '#/components/responses/PairingUnavailable';
  const completion = contract.paths['/v1/pairing/complete'].post;
  for (const [statusCode, response] of Object.entries(completion.responses)) {
    if (statusCode === '200' || statusCode === '201') continue;
    assert.equal(response.$ref, unavailableRef, `completion ${statusCode} is not fixed unavailable`);
  }
  for (const operation of [status.get, status.post]) {
    for (const [statusCode, response] of Object.entries(operation.responses)) {
      if (statusCode === '200' || statusCode === '204') continue;
      assert.equal(response.$ref, unavailableRef, `phone status ${statusCode} is not fixed unavailable`);
    }
  }

  const resolveResponse = (response) => response.$ref
    ? contract.components.responses[response.$ref.split('/').at(-1)]
    : response;
  for (const [path, item] of Object.entries(contract.paths)) {
    if (!path.startsWith('/v1/pairing/')) continue;
    for (const operation of Object.values(item)) {
      for (const response of Object.values(operation.responses)) {
        const resolved = resolveResponse(response);
        const cache = resolved.headers?.['Cache-Control'];
        const resolvedCache = cache?.$ref
          ? contract.components.headers[cache.$ref.split('/').at(-1)]
          : cache;
        assert.equal(resolvedCache?.schema?.const, 'private, no-store', `${path} response can be cached`);
      }
    }
  }
});
