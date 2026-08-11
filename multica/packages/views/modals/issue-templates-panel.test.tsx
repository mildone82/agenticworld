import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiClient, setApiInstance } from "@multica/core/api";
import type { IssueTemplate } from "@multica/core/types";
import { renderWithI18n } from "../test/i18n";

const testApi = new ApiClient("https://api.example.test");
const state = vi.hoisted(() => ({ role: "owner" as "owner" | "admin" | "member" }));
const push = vi.hoisted(() => vi.fn());
const toastSuccess = vi.hoisted(() => vi.fn());
const toastError = vi.hoisted(() => vi.fn());

vi.mock("@multica/core/hooks", () => ({ useWorkspaceId: () => "ws-1" }));
vi.mock("@multica/core/permissions", () => ({
  useCurrentMember: () => ({ role: state.role }),
}));
vi.mock("@multica/core/paths", () => ({
  useWorkspacePaths: () => ({ issueDetail: (id: string) => `/acme/issues/${id}` }),
}));
vi.mock("../navigation", () => ({ useNavigation: () => ({ push }) }));
vi.mock("sonner", () => ({ toast: { success: toastSuccess, error: toastError } }));

vi.mock("../issues/components", () => ({
  PriorityPicker: ({ onUpdate }: { onUpdate: (value: { priority: string }) => void }) => (
    <button type="button" aria-label="Choose high priority" onClick={() => onUpdate({ priority: "high" })}>Choose high priority</button>
  ),
  AssigneePicker: ({ onUpdate }: { onUpdate: (value: { assignee_type: string | null; assignee_id: string | null }) => void }) => (
    <div>
      <button type="button" onClick={() => onUpdate({ assignee_type: "squad", assignee_id: "squad-1" })}>Choose squad</button>
      <button type="button" onClick={() => onUpdate({ assignee_type: "member", assignee_id: "member-1" })}>Choose member</button>
    </div>
  ),
  StagePicker: ({ onUpdate }: { onUpdate: (value: { stage: number }) => void }) => (
    <button type="button" onClick={() => onUpdate({ stage: 2 })}>Choose stage 2</button>
  ),
}));
vi.mock("../projects/components/project-picker", () => ({
  ProjectPicker: ({ onUpdate }: { onUpdate: (value: { project_id: string }) => void }) => (
    <button type="button" aria-label="Choose project" onClick={() => onUpdate({ project_id: "project-1" })}>Choose project</button>
  ),
}));
vi.mock("./issue-picker-modal", () => ({
  IssuePickerModal: ({ open, onSelect }: { open: boolean; onSelect: (issue: { id: string }) => void }) =>
    open ? <button type="button" onClick={() => onSelect({ id: "parent-1" })}>Choose parent fixture</button> : null,
}));

import { IssueTemplatesPanel } from "./issue-templates-panel";

const template: IssueTemplate = {
  id: "template-1",
  workspace_id: "ws-1",
  name: "Backend review",
  title: "Review backend implementation",
  description: "Check auth and tests",
  priority: "high",
  status: "backlog",
  project_id: "project-1",
  assignee_type: "squad",
  assignee_id: "squad-1",
  parent_issue_id: "parent-1",
  stage: 2,
  work_mode: "serial",
  created_by_id: "user-1",
  created_at: "2026-08-11T00:00:00Z",
  updated_at: "2026-08-11T00:00:00Z",
};

function renderPanel(onClose = vi.fn()) {
  const client = new QueryClient({
    defaultOptions: {
      queries: { retry: false },
      mutations: { retry: false },
    },
  });
  const result = renderWithI18n(
    <QueryClientProvider client={client}>
      <IssueTemplatesPanel onClose={onClose} />
    </QueryClientProvider>,
  );
  return { ...result, client, onClose };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function mockList(items: IssueTemplate[] = [template]) {
  return vi.spyOn(testApi, "listIssueTemplates").mockResolvedValue({ issue_templates: items });
}

describe("IssueTemplatesPanel", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    setApiInstance(testApi);
    state.role = "owner";
    push.mockReset();
    toastSuccess.mockReset();
    toastError.mockReset();
  });

  it("renders loading, empty, and server-error states with retry", async () => {
    const pending = deferred<{ issue_templates: IssueTemplate[] }>();
    vi.spyOn(testApi, "listIssueTemplates").mockReturnValue(pending.promise);
    const loading = renderPanel();
    expect(screen.getByText("Loading templates…")).toBeInTheDocument();
    loading.unmount();
    pending.resolve({ issue_templates: [] });

    vi.restoreAllMocks();
    vi.spyOn(testApi, "listIssueTemplates").mockResolvedValue({ issue_templates: [] });
    const empty = renderPanel();
    expect(await screen.findByText("No issue templates yet.")).toBeInTheDocument();
    empty.unmount();

    vi.restoreAllMocks();
    const list = vi.spyOn(testApi, "listIssueTemplates")
      .mockRejectedValueOnce(new Error("offline"))
      .mockResolvedValueOnce({ issue_templates: [] });
    renderPanel();
    expect(await screen.findByText("Templates could not be loaded.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Retry" }));
    await waitFor(() => expect(list).toHaveBeenCalledTimes(2));
    expect(await screen.findByText("No issue templates yet.")).toBeInTheDocument();
  });

  it("keeps management controls hidden for members while allowing single-flight use and navigation", async () => {
    state.role = "member";
    mockList();
    const instantiate = deferred<any>();
    const instantiateSpy = vi.spyOn(testApi, "instantiateIssueTemplate").mockReturnValue(instantiate.promise);
    const onClose = vi.fn();
    renderPanel(onClose);

    expect(await screen.findByText("Backend review")).toBeInTheDocument();
    expect(screen.getByText(/Workspace owners and admins manage templates/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Create template" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Delete" })).not.toBeInTheDocument();

    const use = screen.getByRole("button", { name: "Use template" });
    await userEvent.click(use);
    expect(use).toBeDisabled();
    fireEvent.click(use);
    expect(instantiateSpy).toHaveBeenCalledTimes(1);
    expect(instantiateSpy).toHaveBeenCalledWith("template-1", undefined);

    instantiate.resolve({
      id: "issue-1", workspace_id: "ws-1", title: template.title,
      description: template.description, status: "backlog", priority: "high",
      parent_issue_id: "parent-1", project_id: "project-1", labels: [],
    });
    await waitFor(() => expect(toastSuccess).toHaveBeenCalledTimes(1));
    const options = toastSuccess.mock.calls[0]?.[1];
    expect(options?.action?.label).toBe("View issue");
    options.action.onClick();
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(push).toHaveBeenCalledWith("/acme/issues/issue-1");
  });

  it("reports instantiate failure without closing or leaving the catalog", async () => {
    state.role = "member";
    mockList();
    vi.spyOn(testApi, "instantiateIssueTemplate").mockRejectedValue(new Error("stale squad"));
    const onClose = vi.fn();
    renderPanel(onClose);

    await userEvent.click(await screen.findByRole("button", { name: "Use template" }));
    await waitFor(() => expect(toastError).toHaveBeenCalledWith("stale squad"));
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByText("Backend review")).toBeInTheDocument();
  });

  it("creates a complete template and keeps the editor open when save fails", async () => {
    mockList([]);
    const create = vi.spyOn(testApi, "createIssueTemplate").mockRejectedValueOnce(new Error("save rejected"));
    renderPanel();

    await userEvent.click(await screen.findByRole("button", { name: "Create template" }));
    const save = screen.getByRole("button", { name: "Save template" });
    expect(save).toBeDisabled();
    await userEvent.type(screen.getByLabelText("Template name"), "  Review template  ");
    await userEvent.type(screen.getByLabelText("Issue title"), "  Review implementation  ");
    await userEvent.type(screen.getByLabelText("Description"), "Check tenancy");
    await userEvent.click(screen.getByRole("button", { name: "Choose high priority" }));
    await userEvent.click(screen.getByRole("button", { name: "Choose project" }));
    expect(save).toBeEnabled();
    await userEvent.click(save);

    await waitFor(() => expect(create).toHaveBeenCalledWith({
      name: "Review template",
      title: "Review implementation",
      description: "Check tenancy",
      priority: "high",
      status: "todo",
      project_id: "project-1",
      assignee_type: null,
      assignee_id: null,
      parent_issue_id: null,
      stage: null,
      work_mode: null,
    }));
    expect(toastError).toHaveBeenCalledWith("save rejected");
    expect(screen.getByLabelText("Template name")).toHaveValue("  Review template  ");
  });

  it("edits and deletes templates only after awaited mutations", async () => {
    mockList();
    const replace = vi.spyOn(testApi, "replaceIssueTemplate").mockResolvedValue({ ...template, name: "Updated template" });
    const remove = vi.spyOn(testApi, "deleteIssueTemplate").mockResolvedValue(undefined);
    renderPanel();

    await userEvent.click(await screen.findByRole("button", { name: "Edit" }));
    const name = screen.getByLabelText("Template name");
    await userEvent.clear(name);
    await userEvent.type(name, "Updated template");
    await userEvent.click(screen.getByRole("button", { name: "Save template" }));
    await waitFor(() => expect(replace).toHaveBeenCalledWith("template-1", expect.objectContaining({ name: "Updated template" })));

    await screen.findByText("Backend review");
    await userEvent.click(screen.getByRole("button", { name: "Delete" }));
    expect(screen.getByText("Delete issue template?")).toBeInTheDocument();
    const deleteButtons = screen.getAllByRole("button", { name: "Delete" });
    await userEvent.click(deleteButtons[deleteButtons.length - 1]!);
    await waitFor(() => expect(remove).toHaveBeenCalledWith("template-1"));
  });

  it("enforces squad-only serial and swarm semantics without inventing scheduling", async () => {
    mockList([]);
    const create = vi.spyOn(testApi, "createIssueTemplate").mockResolvedValue({ ...template, work_mode: "swarm", status: "todo" });
    renderPanel();
    await userEvent.click(await screen.findByRole("button", { name: "Create template" }));
    await userEvent.type(screen.getByLabelText("Template name"), "Squad stage");
    await userEvent.type(screen.getByLabelText("Issue title"), "Parallel review");

    expect(screen.queryByText("Work mode")).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Choose squad" }));
    expect(screen.getByText("Work mode")).toBeInTheDocument();
    const selects = screen.getAllByRole("combobox");
    const status = selects[0]!;
    const mode = selects[1]!;

    await userEvent.selectOptions(mode, "serial");
    expect(screen.getByText(/Creates only one ordinary child issue/)).toBeInTheDocument();
    expect(screen.getByText("A work mode requires a squad assignee, parent issue, and stage.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Save template" })).toBeDisabled();
    expect(Array.from(status.querySelectorAll("option")).map((option) => option.value)).toEqual(["todo", "backlog"]);

    await userEvent.selectOptions(status, "backlog");
    expect(screen.getByText(/stays parked in backlog/)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Select parent issue" }));
    await userEvent.click(screen.getByRole("button", { name: "Choose parent fixture" }));
    await userEvent.click(screen.getByText("Choose stage 2"));
    expect(screen.getByRole("button", { name: "Save template" })).toBeEnabled();

    await userEvent.selectOptions(mode, "swarm");
    expect(status).toHaveValue("todo");
    expect(status.querySelectorAll("option")).toHaveLength(1);
    expect(screen.getByText(/Concurrency exists only alongside other todo siblings/)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Save template" }));
    await waitFor(() => expect(create).toHaveBeenCalledWith(expect.objectContaining({
      assignee_type: "squad",
      assignee_id: "squad-1",
      parent_issue_id: "parent-1",
      stage: 2,
      status: "todo",
      work_mode: "swarm",
    })));
  });

  it("clears work mode when the assignee changes away from squad", async () => {
    mockList([]);
    renderPanel();
    await userEvent.click(await screen.findByRole("button", { name: "Create template" }));
    await userEvent.type(screen.getByLabelText("Template name"), "Clear mode");
    await userEvent.type(screen.getByLabelText("Issue title"), "Clear mode issue");
    await userEvent.click(screen.getByRole("button", { name: "Choose squad" }));
    await userEvent.selectOptions(screen.getAllByRole("combobox")[1]!, "serial");
    await userEvent.click(screen.getByRole("button", { name: "Choose member" }));
    expect(screen.queryByText("Work mode")).not.toBeInTheDocument();
    expect(screen.queryByText(/Creates only one ordinary child issue/)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Save template" })).toBeEnabled();
  });
});
