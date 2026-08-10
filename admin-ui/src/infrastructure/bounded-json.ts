export type BoundaryFailureKind = "mime" | "oversize" | "shape";

export class BoundaryFailure extends Error {
  public constructor(public readonly kind: BoundaryFailureKind, message: string) {
    super(message);
    this.name = "BoundaryFailure";
  }
}

const jsonMime = /^application\/json(?:\s*;.*)?$/i;

export const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === "object" && value !== null && !Array.isArray(value);
};

export const readBoundedJsonObject = async (
  response: Response,
  maximumBytes: number
): Promise<Record<string, unknown>> => {
  const mime = response.headers.get("content-type") ?? "";
  if (!jsonMime.test(mime)) {
    await response.body?.cancel();
    throw new BoundaryFailure("mime", "Response did not contain JSON.");
  }
  const declaredSizeHeader = response.headers.get("content-length");
  if (declaredSizeHeader !== null) {
    const declaredSize = Number(declaredSizeHeader);
    if (!Number.isSafeInteger(declaredSize) || declaredSize < 0 || declaredSize > maximumBytes) {
      await response.body?.cancel();
      throw new BoundaryFailure("oversize", "Response exceeds the byte limit.");
    }
  }
  if (response.body === null) {
    throw new BoundaryFailure("shape", "Response body is missing.");
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let byteCount = 0;
  while (true) {
    const part = await reader.read();
    if (part.done) {
      break;
    }
    byteCount += part.value.byteLength;
    if (byteCount > maximumBytes) {
      await reader.cancel("response byte limit exceeded");
      throw new BoundaryFailure("oversize", "Response exceeds the byte limit.");
    }
    chunks.push(part.value);
  }
  const bytes = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new BoundaryFailure("shape", "Response is not valid UTF-8 JSON.");
  }
  if (!isRecord(decoded)) {
    throw new BoundaryFailure("shape", "Response must be an object.");
  }
  return decoded;
};
