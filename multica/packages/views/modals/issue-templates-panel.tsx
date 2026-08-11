"use client";

import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { FileText, Pencil, Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";
import type {
  IssuePriority,
  IssueStatus,
  IssueTemplate,
  IssueTemplateInput,
  IssueTemplateWorkMode,
} from "@multica/core/types";
import { useWorkspaceId } from "@multica/core/hooks";
import { useCurrentMember } from "@multica/core/permissions";
import {
  issueTemplateListOptions,
  useCreateIssueTemplate,
  useDeleteIssueTemplate,
  useInstantiateIssueTemplate,
  useReplaceIssueTemplate,
} from "@multica/core/issue-templates";
import { useWorkspacePaths } from "@multica/core/paths";
import { Button } from "@multica/ui/components/ui/button";
import { Input } from "@multica/ui/components/ui/input";
import { Textarea } from "@multica/ui/components/ui/textarea";
import { Label } from "@multica/ui/components/ui/label";
import { Badge } from "@multica/ui/components/ui/badge";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@multica/ui/components/ui/alert-dialog";
import { PriorityPicker, AssigneePicker, StagePicker } from "../issues/components";
import { ProjectPicker } from "../projects/components/project-picker";
import { PillButton } from "../common/pill-button";
import { IssuePickerModal } from "./issue-picker-modal";
import { useNavigation } from "../navigation";
import { useT } from "../i18n";

const EMPTY_INPUT: IssueTemplateInput = {
  name: "",
  title: "",
  description: "",
  priority: "none",
  status: "todo",
  project_id: null,
  assignee_type: null,
  assignee_id: null,
  parent_issue_id: null,
  stage: null,
  work_mode: null,
};

function toInput(template: IssueTemplate): IssueTemplateInput {
  const { name, title, description, priority, status, project_id, assignee_type, assignee_id, parent_issue_id, stage, work_mode } = template;
  return { name, title, description, priority, status, project_id, assignee_type, assignee_id, parent_issue_id, stage, work_mode };
}

export function IssueTemplatesPanel({ onClose }: { onClose: () => void }) {
  const { t } = useT("modals");
  const wsId = useWorkspaceId();
  const { role } = useCurrentMember(wsId);
  const canManage = role === "owner" || role === "admin";
  const query = useQuery(issueTemplateListOptions(wsId));
  const createMutation = useCreateIssueTemplate();
  const replaceMutation = useReplaceIssueTemplate();
  const deleteMutation = useDeleteIssueTemplate();
  const instantiateMutation = useInstantiateIssueTemplate();
  const router = useNavigation();
  const paths = useWorkspacePaths();
  const [editing, setEditing] = useState<IssueTemplate | "new" | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<IssueTemplate | null>(null);

  const save = async (input: IssueTemplateInput) => {
    try {
      if (editing === "new") await createMutation.mutateAsync(input);
      else if (editing) await replaceMutation.mutateAsync({ id: editing.id, input });
      setEditing(null);
    } catch (error) {
      toast.error(error instanceof Error && error.message ? error.message : t(($) => $.issue_templates.save_error));
    }
  };

  const handleUseTemplate = async (template: IssueTemplate) => {
    try {
      const issue = await instantiateMutation.mutateAsync({ id: template.id });
      toast.success(t(($) => $.issue_templates.created), {
        action: {
          label: t(($) => $.issue_templates.view_issue),
          onClick: () => {
            onClose();
            router.push(paths.issueDetail(issue.id));
          },
        },
      });
    } catch (error) {
      toast.error(error instanceof Error && error.message ? error.message : t(($) => $.issue_templates.use_error));
    }
  };

  if (editing) {
    return (
      <IssueTemplateEditor
        initial={editing === "new" ? EMPTY_INPUT : toInput(editing)}
        saving={createMutation.isPending || replaceMutation.isPending}
        onCancel={() => setEditing(null)}
        onSave={save}
      />
    );
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
      <div className="flex items-start justify-between gap-3 border-b px-5 py-4">
        <div>
          <h2 className="text-lg font-semibold">{t(($) => $.issue_templates.title)}</h2>
          <p className="mt-1 text-caption text-muted-foreground">{t(($) => $.issue_templates.subtitle)}</p>
        </div>
        {canManage ? (
          <Button size="sm" onClick={() => setEditing("new")}>
            <Plus className="size-4" /> {t(($) => $.issue_templates.create)}
          </Button>
        ) : null}
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto p-5">
        {!canManage ? <p className="mb-4 text-caption text-muted-foreground">{t(($) => $.issue_templates.member_hint)}</p> : null}
        {query.isLoading ? (
          <p className="py-12 text-center text-muted-foreground">{t(($) => $.issue_templates.loading)}</p>
        ) : query.isError ? (
          <div className="py-12 text-center">
            <p className="text-destructive">{t(($) => $.issue_templates.error)}</p>
            <Button className="mt-3" variant="outline" onClick={() => void query.refetch()}>{t(($) => $.issue_templates.retry)}</Button>
          </div>
        ) : (query.data?.length ?? 0) === 0 ? (
          <div className="py-12 text-center text-muted-foreground"><FileText className="mx-auto mb-3 size-7" /><p>{t(($) => $.issue_templates.empty)}</p></div>
        ) : (
          <div className="space-y-3">
            {query.data?.map((template) => (
              <div key={template.id} className="rounded-lg border p-4">
                <div className="flex items-start justify-between gap-4">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-medium">{template.name}</span>
                      <Badge variant="secondary">{template.status}</Badge>
                      <Badge variant="outline">{template.priority}</Badge>
                      {template.work_mode ? <Badge>{template.work_mode}</Badge> : null}
                    </div>
                    <p className="mt-1 truncate text-body">{template.title}</p>
                    <p className="mt-2 text-caption text-muted-foreground">
                      {template.assignee_type && template.assignee_id ? `${template.assignee_type}: ${template.assignee_id}` : "—"}
                      {template.parent_issue_id ? ` · parent ${template.parent_issue_id}` : ""}
                      {template.stage ? ` · stage ${template.stage}` : ""}
                      {template.project_id ? ` · project ${template.project_id}` : ""}
                    </p>
                  </div>
                  <div className="flex shrink-0 flex-wrap gap-2">
                    <Button size="sm" disabled={instantiateMutation.isPending} onClick={() => void handleUseTemplate(template)}>{t(($) => $.issue_templates.use)}</Button>
                    {canManage ? <Button size="icon-sm" variant="ghost" aria-label={t(($) => $.issue_templates.edit)} onClick={() => setEditing(template)}><Pencil className="size-4" /></Button> : null}
                    {canManage ? <Button size="icon-sm" variant="ghost" aria-label={t(($) => $.issue_templates.delete)} onClick={() => setDeleteTarget(template)}><Trash2 className="size-4" /></Button> : null}
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      <AlertDialog open={deleteTarget !== null} onOpenChange={(open) => !open && setDeleteTarget(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t(($) => $.issue_templates.delete_title)}</AlertDialogTitle>
            <AlertDialogDescription>{t(($) => $.issue_templates.delete_description)}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t(($) => $.issue_templates.cancel)}</AlertDialogCancel>
            <AlertDialogAction
              disabled={deleteMutation.isPending}
              onClick={async (event) => {
                event.preventDefault();
                if (!deleteTarget) return;
                try { await deleteMutation.mutateAsync(deleteTarget.id); setDeleteTarget(null); }
                catch (error) { toast.error(error instanceof Error ? error.message : String(error)); }
              }}
            >{t(($) => $.issue_templates.delete)}</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

function IssueTemplateEditor({ initial, saving, onCancel, onSave }: { initial: IssueTemplateInput; saving: boolean; onCancel: () => void; onSave: (input: IssueTemplateInput) => Promise<void> }) {
  const { t } = useT("modals");
  const [form, setForm] = useState(initial);
  const [parentPickerOpen, setParentPickerOpen] = useState(false);

  useEffect(() => setForm(initial), [initial]);
  const modeReady = form.work_mode === null || (form.assignee_type === "squad" && !!form.assignee_id && !!form.parent_issue_id && form.stage !== null);
  const canSave = form.name.trim().length > 0 && form.title.trim().length > 0 && modeReady;
  const statuses = useMemo<IssueStatus[]>(() => form.work_mode === "serial" ? ["todo", "backlog"] : form.work_mode === "swarm" ? ["todo"] : ["backlog", "todo", "in_progress", "in_review", "done", "blocked", "cancelled"], [form.work_mode]);

  const setMode = (mode: IssueTemplateWorkMode | null) => {
    setForm((current) => ({ ...current, work_mode: mode, status: mode === "swarm" ? "todo" : mode === "serial" && !["todo", "backlog"].includes(current.status) ? "todo" : current.status }));
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
      <div className="border-b px-5 py-4"><h2 className="text-lg font-semibold">{t(($) => $.issue_templates.save)}</h2></div>
      <div className="min-h-0 flex-1 space-y-5 overflow-y-auto p-5">
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-1.5"><Label htmlFor="template-name">{t(($) => $.issue_templates.name)}</Label><Input id="template-name" maxLength={64} value={form.name} onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} /></div>
          <div className="space-y-1.5"><Label htmlFor="template-title">{t(($) => $.issue_templates.issue_title)}</Label><Input id="template-title" value={form.title} onChange={(e) => setForm((f) => ({ ...f, title: e.target.value }))} /></div>
        </div>
        <div className="space-y-1.5"><Label htmlFor="template-description">{t(($) => $.issue_templates.description)}</Label><Textarea id="template-description" rows={4} value={form.description} onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))} /></div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-1.5"><Label>{t(($) => $.issue_templates.status)}</Label><select className="h-9 w-full rounded-md border bg-background px-3 text-sm" value={form.status} onChange={(e) => setForm((f) => ({ ...f, status: e.target.value as IssueStatus }))}>{statuses.map((status) => <option key={status} value={status}>{status}</option>)}</select></div>
          <div className="space-y-1.5"><Label>{t(($) => $.issue_templates.priority)}</Label><PriorityPicker priority={form.priority} onUpdate={(u) => u.priority && setForm((f) => ({ ...f, priority: u.priority as IssuePriority }))} triggerRender={<Button type="button" variant="outline" className="w-full justify-start" />} /></div>
          <div className="space-y-1.5"><Label>{t(($) => $.issue_templates.assignee)}</Label><AssigneePicker assigneeType={form.assignee_type} assigneeId={form.assignee_id} onUpdate={(u) => setForm((f) => ({ ...f, assignee_type: u.assignee_type ?? null, assignee_id: u.assignee_id ?? null, work_mode: u.assignee_type === "squad" ? f.work_mode : null }))} triggerRender={<Button type="button" variant="outline" className="w-full justify-start" />} /></div>
          <div className="space-y-1.5"><Label>{t(($) => $.issue_templates.project)}</Label><ProjectPicker projectId={form.project_id} onUpdate={(u) => setForm((f) => ({ ...f, project_id: u.project_id ?? null }))} triggerRender={<Button type="button" variant="outline" className="w-full justify-start" />} /></div>
          <div className="space-y-1.5"><Label>{t(($) => $.issue_templates.parent)}</Label><div className="flex gap-2"><Button type="button" variant="outline" className="min-w-0 flex-1 justify-start truncate" onClick={() => setParentPickerOpen(true)}>{form.parent_issue_id ?? t(($) => $.issue_templates.select_parent)}</Button>{form.parent_issue_id ? <Button type="button" variant="ghost" onClick={() => setForm((f) => ({ ...f, parent_issue_id: null, stage: null, work_mode: null }))}>{t(($) => $.issue_templates.clear_parent)}</Button> : null}</div></div>
          <div className="space-y-1.5"><Label>{t(($) => $.issue_templates.stage)}</Label>{form.parent_issue_id ? <StagePicker stage={form.stage} onUpdate={(u) => setForm((f) => ({ ...f, stage: u.stage ?? null, work_mode: u.stage == null ? null : f.work_mode }))} triggerRender={<PillButton className="w-full justify-start" />} /> : <Button type="button" variant="outline" className="w-full justify-start" disabled>—</Button>}</div>
          {form.assignee_type === "squad" ? <div className="space-y-1.5 sm:col-span-2"><Label>{t(($) => $.issue_templates.work_mode)}</Label><select className="h-9 w-full rounded-md border bg-background px-3 text-sm" value={form.work_mode ?? ""} onChange={(e) => setMode((e.target.value || null) as IssueTemplateWorkMode | null)}><option value="">{t(($) => $.issue_templates.none)}</option><option value="serial">{t(($) => $.issue_templates.serial)}</option><option value="swarm">{t(($) => $.issue_templates.swarm)}</option></select></div> : null}
        </div>
        {form.work_mode ? <p className="rounded-md bg-muted p-3 text-caption text-muted-foreground">{form.work_mode === "serial" ? t(($) => $.issue_templates.serial_help) : t(($) => $.issue_templates.swarm_help)}</p> : null}
        {form.work_mode === "serial" && form.status === "backlog" ? <p className="text-caption text-warning">{t(($) => $.issue_templates.parked_warning)}</p> : null}
        {!modeReady ? <p className="text-caption text-destructive">{t(($) => $.issue_templates.mode_requirements)}</p> : null}
      </div>
      <div className="flex justify-end gap-2 border-t px-5 py-3"><Button type="button" variant="outline" onClick={onCancel}>{t(($) => $.issue_templates.cancel)}</Button><Button disabled={!canSave || saving} onClick={() => void onSave({ ...form, name: form.name.trim(), title: form.title.trim() })}>{t(($) => $.issue_templates.save)}</Button></div>
      <IssuePickerModal open={parentPickerOpen} onOpenChange={setParentPickerOpen} title={t(($) => $.issue_templates.select_parent)} description={t(($) => $.issue_templates.select_parent)} excludeIds={form.parent_issue_id ? [form.parent_issue_id] : []} onSelect={(issue) => setForm((f) => ({ ...f, parent_issue_id: issue.id }))} />
    </div>
  );
}
