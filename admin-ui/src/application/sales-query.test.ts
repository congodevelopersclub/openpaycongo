import { describe, expect, it } from "vitest";
import { buildSalesQuery } from "./sales-query";

describe("buildSalesQuery", () => {
  it("uses the selected civil day without assuming a fixed offset", () => {
    const query = buildSalesQuery("today", Date.parse("2026-11-02T12:00:00Z"), "America/New_York");
    expect(query).toMatchObject({
      from: "2026-11-02T05:00:00Z",
      to: "2026-11-02T12:00:00Z",
      interval: "hour",
      comparison: true
    });
  });

  it("bounds the seven-day selection at today's local midnight", () => {
    const query = buildSalesQuery("seven_days", Date.parse("2026-11-02T12:00:00Z"), "Africa/Lubumbashi");
    expect(query.from).toBe("2026-10-26T22:00:00Z");
    expect(query.interval).toBe("day");
  });

  it("uses six prior local civil midnights across New York fall-back", () => {
    const query = buildSalesQuery("seven_days", Date.parse("2026-11-02T12:00:00Z"), "America/New_York");
    expect(query.from).toBe("2026-10-27T04:00:00Z");
    expect(Date.parse(query.to) - Date.parse(query.from)).toBe(6 * 86_400_000 + 8 * 3_600_000);
  });
});
