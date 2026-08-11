import { describe, expect, it } from "vitest";
import { issueTemplateKeys } from "./queries";

// The workspace id must remain part of every template cache key; templates
// are shared workspace furniture and may never bleed across a workspace switch.
describe("issueTemplateKeys", () => {
  it("scopes list state by workspace", () => {
    expect(issueTemplateKeys.list("ws-a")).toEqual(["issue-templates", "ws-a", "list"]);
    expect(issueTemplateKeys.list("ws-a")).not.toEqual(issueTemplateKeys.list("ws-b"));
  });
});
