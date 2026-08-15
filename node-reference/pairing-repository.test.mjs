import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { SqlitePairingRepository } from './pairing-repository.mjs';

const pairing = {
  tenantId: 'tenant-a',
  intentId: 'intent-1',
  deviceId: 'device-1',
  checksum: 'checksum-v1',
  version: 'pairing-v1',
};

test('SQLite pairing lifecycle is tenant and device scoped, one-time, exact-replay only, and restart persistent', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'openpaycongo-node-pairing-'));
  const databasePath = join(directory, 'pairing.sqlite');
  t.after(() => rm(directory, { recursive: true, force: true }));

  const repository = new SqlitePairingRepository({ databasePath });
  t.after(() => repository.close());

  assert.deepEqual(repository.issue(pairing), { status: 'issued', replayed: false });
  assert.deepEqual(repository.issue(pairing), { status: 'issued', replayed: true });
  assert.throws(() => repository.issue({ ...pairing, version: 'pairing-v2' }), /conflicts/);
  assert.throws(() => repository.complete({ ...pairing, completionDigest: 'digest-1', deviceId: 'device-2' }), /device scope/);
  assert.throws(() => repository.complete({ ...pairing, completionDigest: 'digest-1', tenantId: 'tenant-b' }), /tenant scope/);

  assert.deepEqual(repository.complete({ ...pairing, completionDigest: 'digest-1' }), { status: 'completed', replayed: false });
  assert.deepEqual(repository.complete({ ...pairing, completionDigest: 'digest-1' }), { status: 'completed', replayed: true });
  assert.throws(() => repository.complete({ ...pairing, completionDigest: 'digest-2' }), /conflicts/);
  repository.close();

  const afterRestart = new SqlitePairingRepository({ databasePath });
  t.after(() => afterRestart.close());
  assert.deepEqual(afterRestart.activate({ ...pairing, activationDigest: 'admin-activation-1' }), { status: 'active', replayed: false });
  assert.deepEqual(afterRestart.activate({ ...pairing, activationDigest: 'admin-activation-1' }), { status: 'active', replayed: true });
  assert.throws(() => afterRestart.activate({ ...pairing, activationDigest: 'admin-activation-2' }), /conflicts/);
});

test('activated devices accept bounded immutable batches and persist only contiguous acknowledgement', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'openpaycongo-node-sync-'));
  const databasePath = join(directory, 'sync.sqlite');
  t.after(() => rm(directory, { recursive: true, force: true }));

  const repository = new SqlitePairingRepository({ databasePath });
  repository.issue(pairing);
  repository.complete({ ...pairing, completionDigest: 'completion-1' });
  repository.activate({ ...pairing, activationDigest: 'activation-1' });

  const initialBatch = [
    { sequence: 1, eventId: 'event-1', payload: { amount_minor: '100', occurred_at: '2026-01-01T00:00:00Z' } },
    { sequence: 3, eventId: 'event-3', payload: { amount_minor: '300', occurred_at: '2026-01-01T00:02:00Z' } },
  ];
  assert.deepEqual(repository.sync({ tenantId: pairing.tenantId, deviceId: pairing.deviceId, idempotencyKey: 'batch-1', events: initialBatch }), { acknowledgement: 1, replayed: false });
  assert.deepEqual(repository.sync({ tenantId: pairing.tenantId, deviceId: pairing.deviceId, idempotencyKey: 'batch-1', events: initialBatch }), { acknowledgement: 1, replayed: true });
  assert.throws(() => repository.sync({ tenantId: pairing.tenantId, deviceId: pairing.deviceId, idempotencyKey: 'batch-1', events: [{ sequence: 1, eventId: 'event-1', payload: { amount_minor: '101' } }] }), /conflicts/);
  assert.throws(() => repository.sync({ tenantId: pairing.tenantId, deviceId: pairing.deviceId, idempotencyKey: 'batch-2', events: [{ sequence: 1, eventId: 'event-1', payload: { amount_minor: '999' } }] }), /immutable/);
  assert.throws(() => repository.sync({ tenantId: pairing.tenantId, deviceId: pairing.deviceId, idempotencyKey: 'too-many', events: Array.from({ length: 101 }, (_, index) => ({ sequence: index + 10, eventId: `event-${index + 10}`, payload: {} })) }), /bounded/);
  repository.close();

  const afterRestart = new SqlitePairingRepository({ databasePath });
  t.after(() => afterRestart.close());
  assert.deepEqual(afterRestart.sync({ tenantId: pairing.tenantId, deviceId: pairing.deviceId, idempotencyKey: 'batch-2', events: [{ sequence: 2, eventId: 'event-2', payload: { amount_minor: '200', occurred_at: '2026-01-01T00:01:00Z' } }] }), { acknowledgement: 3, replayed: false });
  assert.throws(() => afterRestart.sync({ tenantId: pairing.tenantId, deviceId: 'device-other', idempotencyKey: 'wrong-device', events: [] }), /activated/);
});
