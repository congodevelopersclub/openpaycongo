import type { AnalyticsInterval, SalesQuery } from "../domain/sales-analytics";

export type SalesPeriod = "today" | "seven_days";

const utcSecond = (milliseconds: number): string => {
  return new Date(Math.floor(milliseconds / 1_000) * 1_000).toISOString().replace(".000Z", "Z");
};

const localDateParts = (milliseconds: number, timeZone: string): readonly [number, number, number] => {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  }).formatToParts(new Date(milliseconds));
  const value = (name: Intl.DateTimeFormatPartTypes): number => {
    const part = parts.find((candidate) => candidate.type === name)?.value;
    if (part === undefined) {
      throw new Error("The selected time zone cannot be resolved.");
    }
    return Number(part);
  };
  return [value("year"), value("month"), value("day")];
};

const localComponentsAt = (milliseconds: number, timeZone: string): readonly number[] => {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit"
  }).formatToParts(new Date(milliseconds));
  const names = ["year", "month", "day", "hour", "minute", "second"] as const;
  return names.map((name) => Number(parts.find((part) => part.type === name)?.value));
};

const startOfCivilDate = (year: number, month: number, day: number, timeZone: string): number => {
  const approximation = Date.UTC(year, month - 1, day);
  const [zoneYear, zoneMonth, zoneDay, hour, minute, second] = localComponentsAt(approximation, timeZone);
  const representedAsUtc = Date.UTC(zoneYear ?? 0, (zoneMonth ?? 1) - 1, zoneDay, hour, minute, second);
  const firstCandidate = approximation - (representedAsUtc - approximation);
  const candidateParts = localComponentsAt(firstCandidate, timeZone);
  const candidateAsUtc = Date.UTC(candidateParts[0] ?? 0, (candidateParts[1] ?? 1) - 1, candidateParts[2], candidateParts[3], candidateParts[4], candidateParts[5]);
  return firstCandidate - (candidateAsUtc - approximation);
};

const startOfLocalDay = (now: number, timeZone: string): number => {
  const [year, month, day] = localDateParts(now, timeZone);
  return startOfCivilDate(year, month, day, timeZone);
};

const sixCivilMidnightsBefore = (now: number, timeZone: string): number => {
  const [year, month, day] = localDateParts(now, timeZone);
  const civilDate = new Date(Date.UTC(year, month - 1, day - 6));
  return startOfCivilDate(civilDate.getUTCFullYear(), civilDate.getUTCMonth() + 1, civilDate.getUTCDate(), timeZone);
};

export const buildSalesQuery = (period: SalesPeriod, now: number, timeZone: string): SalesQuery => {
  if (!Number.isFinite(now) || timeZone.length === 0 || timeZone.length > 64) {
    throw new Error("A valid clock and time zone are required for analytics.");
  }
  const today = startOfLocalDay(now, timeZone);
  const from = period === "today" ? today : sixCivilMidnightsBefore(now, timeZone);
  const interval: AnalyticsInterval = period === "today" ? "hour" : "day";
  return {
    from: utcSecond(from),
    to: utcSecond(now),
    snapshotAt: utcSecond(now),
    timeZone,
    interval,
    comparison: true
  };
};
