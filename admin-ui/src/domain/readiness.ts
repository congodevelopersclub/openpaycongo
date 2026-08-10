export type ProcessHealth = "alive" | "unreachable";
export type DatastoreHealth = "ok" | "failed";
export type MigrationHealth = "current" | "pending" | "failed";
export type TopologyHealth = "supported" | "unsupported";
export type ProjectionHealth = "healthy" | "rebuilding" | "failed";
export type WriteAdmission = "open" | "closed";

export interface OperationalIdentity {
  readonly contractVersion: string;
  readonly implementation: string;
  readonly adapter: string;
  readonly migrationRevision: string;
}

export interface ServerIdentity extends OperationalIdentity {
  readonly build: string;
}

export interface Readiness extends OperationalIdentity {
  readonly datastore: DatastoreHealth;
  readonly migration: MigrationHealth;
  readonly topology: TopologyHealth;
  readonly projection: ProjectionHealth;
  readonly writeAdmission: WriteAdmission;
}

export interface ConnectionSnapshot {
  readonly observedAt: number;
  readonly process: ProcessHealth;
  readonly identity: ServerIdentity;
  readonly readiness: Readiness;
}

export const isWriteReady = (readiness: Readiness): boolean =>
  readiness.datastore === "ok" &&
  readiness.migration === "current" &&
  readiness.topology === "supported" &&
  readiness.projection === "healthy" &&
  readiness.writeAdmission === "open";

export const hasConsistentIdentity = (snapshot: ConnectionSnapshot): boolean =>
  snapshot.identity.contractVersion === snapshot.readiness.contractVersion &&
  snapshot.identity.implementation === snapshot.readiness.implementation &&
  snapshot.identity.adapter === snapshot.readiness.adapter &&
  snapshot.identity.migrationRevision === snapshot.readiness.migrationRevision;
