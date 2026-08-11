import type { ReactNode } from "react";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

vi.mock("@multica/core/issues/stores/create-mode-store", () => ({
  useCreateModeStore: (selector: (state: { setLastMode: () => void }) => unknown) => selector({ setLastMode: vi.fn() }),
}));
vi.mock("@multica/ui/lib/utils", () => ({ cn: (...values: unknown[]) => values.filter(Boolean).join(" ") }));
vi.mock("@multica/ui/components/ui/dialog", () => ({
  Dialog: ({ children }: { children: ReactNode }) => <div>{children}</div>,
  DialogContent: ({ children }: { children: ReactNode }) => <div>{children}</div>,
}));
vi.mock("../i18n", () => ({
  useT: () => ({
    t: (selector: (value: { issue_templates: { tab_new: string; tab_templates: string } }) => string) =>
      selector({ issue_templates: { tab_new: "New Issue", tab_templates: "Issue Template" } }),
  }),
}));
vi.mock("./quick-create-issue", () => ({ AgentCreatePanel: () => <div>agent panel</div> }));
vi.mock("./create-issue", () => ({
  ManualCreatePanel: () => <div>manual draft body</div>,
  manualDialogContentClass: () => "manual",
}));
vi.mock("./issue-templates-panel", () => ({ IssueTemplatesPanel: () => <div>template catalog</div> }));

import { CreateIssueDialog } from "./create-issue-dialog";

describe("CreateIssueDialog issue template surface", () => {
  it("switches tabs locally and returns to the existing create surface", () => {
    render(<CreateIssueDialog onClose={vi.fn()} initialMode="manual" />);
    expect(screen.getByText("manual draft body")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Issue Template" }));
    expect(screen.getByText("template catalog")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "New Issue" }));
    expect(screen.getByText("manual draft body")).toBeTruthy();
  });
});
