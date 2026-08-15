// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/preact";
import { afterEach, describe, expect, it } from "vitest";
import {
  OperationalStatusView,
  type OperationalStatusKind
} from "./operational-status";

afterEach(cleanup);

const cases: ReadonlyArray<readonly [OperationalStatusKind, string]> = [
  ["loading", "Loading operational evidence"],
  ["empty", "No operational evidence for this period"],
  ["stale", "Operational evidence is stale"],
  ["conflict", "Operational evidence conflicts"],
  ["recovery_required", "Recovery required"],
  ["unavailable", "Operational evidence is unavailable"]
];

describe("OperationalStatusView", () => {
  it("has an accessible, non-financial state for every synthetic operational outcome", () => {
    for (const [kind, title] of cases) {
      const rendered = render(<OperationalStatusView status={{ kind }} />);
      const status = screen.getByRole("status");
      expect(status.getAttribute("aria-live")).toBe("polite");
      expect(screen.getByRole("heading", { name: title })).toBeTruthy();
      expect(screen.queryByLabelText(/sales totals|payment total|gross volume/i)).toBeNull();
      expect(screen.queryByRole("button")).toBeNull();
      rendered.unmount();
    }
  });

  it("only marks the loading state busy and keeps recovery explicit", () => {
    const loading = render(<OperationalStatusView status={{ kind: "loading" }} />);
    expect(screen.getByRole("status").getAttribute("aria-busy")).toBe("true");
    loading.unmount();

    render(<OperationalStatusView status={{ kind: "recovery_required" }} />);
    expect(screen.getByRole("status").getAttribute("aria-busy")).toBe("false");
    expect(screen.getByText(/approved recovery validation completes/i)).toBeTruthy();
  });
});
