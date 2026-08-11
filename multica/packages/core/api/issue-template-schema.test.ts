import { describe, expect, it } from "vitest";
import { parseWithFallback } from "./schema";
import {
  EMPTY_LIST_ISSUE_TEMPLATES_RESPONSE,
  IssueTemplateSchema,
  ListIssueTemplatesResponseSchema,
} from "./schemas";

const template = {
  id: "template-1", workspace_id: "ws-1", name: "Review", title: "Review backend",
  description: "", priority: "high", status: "backlog", project_id: null,
  assignee_type: "squad", assignee_id: "squad-1", parent_issue_id: "parent-1",
  stage: 2, work_mode: "serial", created_by_id: "user-1",
  created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
};

describe("IssueTemplate schemas", () => {
  it("accepts nullable relations and unknown future fields", () => {
    expect(IssueTemplateSchema.safeParse({ ...template, future: true }).success).toBe(true);
    expect(IssueTemplateSchema.safeParse({ ...template, assignee_type: null, assignee_id: null, parent_issue_id: null, stage: null, work_mode: null }).success).toBe(true);
  });

  it("degrades a malformed list to an empty catalog", () => {
    expect(parseWithFallback({ issue_templates: [{ ...template, work_mode: "scheduler" }] }, ListIssueTemplatesResponseSchema, EMPTY_LIST_ISSUE_TEMPLATES_RESPONSE, { endpoint: "GET /api/issue-templates" })).toEqual({ issue_templates: [] });
  });

  it("rejects unsupported work modes at the entity boundary", () => {
    expect(IssueTemplateSchema.safeParse({ ...template, work_mode: "scheduler" }).success).toBe(false);
  });
});
