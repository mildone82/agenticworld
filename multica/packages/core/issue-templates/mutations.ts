import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../api";
import { useWorkspaceId } from "../hooks";
import { reconcileCreatedIssue, settleCreatedIssue } from "../issues/mutations";
import type { IssueTemplateInput, InstantiateIssueTemplateRequest } from "../types";
import { issueTemplateKeys } from "./queries";

export function useCreateIssueTemplate() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (input: IssueTemplateInput) => api.createIssueTemplate(input),
    onSettled: () => qc.invalidateQueries({ queryKey: issueTemplateKeys.all(wsId) }),
  });
}

export function useReplaceIssueTemplate() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: ({ id, input }: { id: string; input: IssueTemplateInput }) =>
      api.replaceIssueTemplate(id, input),
    onSettled: () => qc.invalidateQueries({ queryKey: issueTemplateKeys.all(wsId) }),
  });
}

export function useDeleteIssueTemplate() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (id: string) => api.deleteIssueTemplate(id),
    onSettled: () => qc.invalidateQueries({ queryKey: issueTemplateKeys.all(wsId) }),
  });
}

export function useInstantiateIssueTemplate() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: ({ id, input }: { id: string; input?: InstantiateIssueTemplateRequest }) =>
      api.instantiateIssueTemplate(id, input),
    onSuccess: (issue) => reconcileCreatedIssue(qc, wsId, issue),
    onSettled: () => settleCreatedIssue(qc, wsId),
  });
}
