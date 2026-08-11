import type { Issue, IssueAssigneeType, IssuePriority, IssueStatus } from "./issue";

export type IssueTemplateWorkMode = "serial" | "swarm";

export interface IssueTemplate {
  id: string;
  workspace_id: string;
  name: string;
  title: string;
  description: string;
  priority: IssuePriority;
  status: IssueStatus;
  project_id: string | null;
  assignee_type: IssueAssigneeType | null;
  assignee_id: string | null;
  parent_issue_id: string | null;
  stage: number | null;
  work_mode: IssueTemplateWorkMode | null;
  created_by_id: string;
  created_at: string;
  updated_at: string;
}

export interface IssueTemplateInput {
  name: string;
  title: string;
  description: string;
  priority: IssuePriority;
  status: IssueStatus;
  project_id: string | null;
  assignee_type: IssueAssigneeType | null;
  assignee_id: string | null;
  parent_issue_id: string | null;
  stage: number | null;
  work_mode: IssueTemplateWorkMode | null;
}

export interface ListIssueTemplatesResponse {
  issue_templates: IssueTemplate[];
}

export interface InstantiateIssueTemplateRequest {
  allow_duplicate?: boolean;
}

export type InstantiateIssueTemplateResponse = Issue;
