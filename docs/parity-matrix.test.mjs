import assert from 'node:assert/strict';
import test from 'node:test';
import { buildParityMatrix, MatrixFailure } from './parity-matrix.mjs';

const support = {
  contract_version: 'sales-analytics-v1',
  runtimes: [
    { runtime: 'node', datastores: ['sqlite'], capabilities: ['analytics'] },
    { runtime: 'laravel', datastores: ['sqlite'], capabilities: [] },
  ],
};

test('parity matrix entries are generated from declared support metadata', () => {
  assert.deepEqual(buildParityMatrix(support), [
    { runtime: 'laravel', datastore: 'sqlite', contract_version: 'sales-analytics-v1', capabilities: [] },
    { runtime: 'node', datastore: 'sqlite', contract_version: 'sales-analytics-v1', capabilities: ['analytics'] },
  ]);
});

test('parity matrix rejects missing or ambiguous support declarations', () => {
  for (const invalid of [
    { ...support, contract_version: '' },
    { ...support, runtimes: [{ runtime: 'node', datastores: [], capabilities: [] }] },
    { ...support, runtimes: [{ runtime: 'node', datastores: ['sqlite', 'sqlite'], capabilities: [] }] },
    { ...support, runtimes: [{ runtime: 'node', datastores: ['sqlite'], capabilities: ['unknown'] }] },
  ]) {
    assert.throws(() => buildParityMatrix(invalid), MatrixFailure);
  }
});
