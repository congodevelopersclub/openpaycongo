export class MatrixFailure extends Error {}

const knownCapabilities = new Set(['analytics']);

const nonEmptyString = (value) => typeof value === 'string' && value.length > 0;

export function buildParityMatrix(support) {
  if (!nonEmptyString(support?.contract_version)) {
    throw new MatrixFailure('contract_version must be a non-empty string');
  }
  if (!Array.isArray(support?.runtimes) || support.runtimes.length === 0) {
    throw new MatrixFailure('runtimes must be a non-empty array');
  }

  const entries = [];
  for (const declaration of support.runtimes) {
    if (!nonEmptyString(declaration?.runtime)) {
      throw new MatrixFailure('runtime must be a non-empty string');
    }
    if (!Array.isArray(declaration.datastores) || declaration.datastores.length === 0 || declaration.datastores.some((datastore) => !nonEmptyString(datastore))) {
      throw new MatrixFailure(`${declaration.runtime}: datastores must be a non-empty string array`);
    }
    if (new Set(declaration.datastores).size !== declaration.datastores.length) {
      throw new MatrixFailure(`${declaration.runtime}: datastores must not contain duplicates`);
    }
    if (!Array.isArray(declaration.capabilities) || declaration.capabilities.some((capability) => !knownCapabilities.has(capability))) {
      throw new MatrixFailure(`${declaration.runtime}: capabilities must contain only known values`);
    }
    for (const datastore of declaration.datastores) {
      entries.push({ runtime: declaration.runtime, datastore, contract_version: support.contract_version, capabilities: [...declaration.capabilities] });
    }
  }
  return entries.sort((left, right) => left.runtime.localeCompare(right.runtime) || left.datastore.localeCompare(right.datastore));
}
