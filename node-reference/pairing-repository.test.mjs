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
