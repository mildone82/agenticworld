import { afterEach, describe, expect, it, vi } from "vitest";
import type { IssueTemplateInput } from "../types";
import { ApiClient } from "./client";

const input: IssueTemplateInput = {
  name: "Backend review",
  title: "Review backend implementation",
  description: "Check auth and tenancy",
  priority: "high",
  status: "todo",
  project_id: null,
  assignee_type: null,
  assignee_id: null,
  parent_issue_id: null,
  stage: null,
  work_mode: null,
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("ApiClient issue template response boundaries", () => {
  it("degrades an unavailable catalog on an older backend to an empty list", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ error: "not found" }), {
          status: 404,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );

    await expect(
      new ApiClient("https://api.example.test").listIssueTemplates(),
    ).resolves.toEqual({ issue_templates: [] });
  });

  it("rejects a malformed create response instead of reporting success", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ id: "template-1" }), {
          status: 201,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );

    await expect(
      new ApiClient("https://api.example.test").createIssueTemplate(input),
    ).rejects.toThrow("Invalid issue template response");
  });

  it("rejects a malformed instantiated issue response", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ id: "issue-1" }), {
          status: 201,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );

    await expect(
      new ApiClient("https://api.example.test").instantiateIssueTemplate("template-1"),
    ).rejects.toThrow("Invalid issue response");
  });
});
