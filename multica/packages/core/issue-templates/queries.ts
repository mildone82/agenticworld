import { queryOptions } from "@tanstack/react-query";
import { api } from "../api";

export const issueTemplateKeys = {
  all: (wsId: string) => ["issue-templates", wsId] as const,
  list: (wsId: string) => [...issueTemplateKeys.all(wsId), "list"] as const,
};

export function issueTemplateListOptions(wsId: string) {
  return queryOptions({
    queryKey: issueTemplateKeys.list(wsId),
    queryFn: () => api.listIssueTemplates(),
    select: (response) => response.issue_templates,
  });
}
