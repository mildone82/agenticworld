package handler

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/multica-ai/multica/server/internal/middleware"
	db "github.com/multica-ai/multica/server/pkg/db/generated"
)

func TestIssueTemplateModeValidation(t *testing.T) {
	serial, swarm, scheduler := "serial", "swarm", "scheduler"
	squad := pgtype.Text{String: "squad", Valid: true}
	agent := pgtype.Text{String: "agent", Valid: true}
	parent := pgtype.UUID{Valid: true}
	stage := pgtype.Int4{Int32: 2, Valid: true}

	tests := []struct {
		name      string
		mode      *string
		status    string
		assignee  pgtype.Text
		parent    pgtype.UUID
		stage     pgtype.Int4
		wantError bool
	}{
		{name: "ordinary template", mode: nil, status: "done", wantError: false},
		{name: "serial current stage", mode: &serial, status: "todo", assignee: squad, parent: parent, stage: stage},
		{name: "serial parked later stage", mode: &serial, status: "backlog", assignee: squad, parent: parent, stage: stage},
		{name: "swarm todo sibling", mode: &swarm, status: "todo", assignee: squad, parent: parent, stage: stage},
		{name: "no scheduler mode", mode: &scheduler, status: "todo", assignee: squad, parent: parent, stage: stage, wantError: true},
		{name: "serial rejects terminal", mode: &serial, status: "done", assignee: squad, parent: parent, stage: stage, wantError: true},
		{name: "swarm rejects backlog", mode: &swarm, status: "backlog", assignee: squad, parent: parent, stage: stage, wantError: true},
		{name: "mode requires squad", mode: &serial, status: "todo", assignee: agent, parent: parent, stage: stage, wantError: true},
		{name: "mode requires parent", mode: &serial, status: "todo", assignee: squad, stage: stage, wantError: true},
		{name: "mode requires stage", mode: &serial, status: "todo", assignee: squad, parent: parent, wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := issueTemplateModeError(tt.mode, tt.status, tt.assignee, tt.parent, tt.stage)
			if (got != "") != tt.wantError {
				t.Fatalf("issueTemplateModeError() = %q, wantError=%v", got, tt.wantError)
			}
		})
	}
}

func issueTemplateTestBody(name, title string) map[string]any {
	return map[string]any{
		"name": name, "title": title, "description": "",
		"priority": "none", "status": "todo",
		"project_id": nil, "assignee_type": nil, "assignee_id": nil,
		"parent_issue_id": nil, "stage": nil, "work_mode": nil,
	}
}

func issueTemplateTestRequest(method, path, userID, workspaceID string, body any) *http.Request {
	req := newRequest(method, path, body)
	req.Header.Set("X-User-ID", userID)
	req.Header.Set("X-Workspace-ID", workspaceID)
	return req
}

func createIssueTemplateForTest(t *testing.T, body map[string]any) IssueTemplateResponse {
	t.Helper()
	w := httptest.NewRecorder()
	req := issueTemplateTestRequest(http.MethodPost, "/api/issue-templates", testUserID, testWorkspaceID, body)
	testHandler.CreateIssueTemplate(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("CreateIssueTemplate: expected 201, got %d: %s", w.Code, w.Body.String())
	}
	var created IssueTemplateResponse
	if err := json.NewDecoder(w.Body).Decode(&created); err != nil {
		t.Fatalf("decode created issue template: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testPool.Exec(context.Background(), `DELETE FROM issue_template WHERE id = $1`, created.ID)
	})
	return created
}

func createIssueTemplateParent(t *testing.T, title string) string {
	t.Helper()
	var id string
	if err := testPool.QueryRow(context.Background(), `
		INSERT INTO issue (workspace_id, title, creator_type, creator_id)
		VALUES ($1, $2, 'member', $3)
		RETURNING id
	`, testWorkspaceID, title, testUserID).Scan(&id); err != nil {
		t.Fatalf("create parent issue: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testPool.Exec(context.Background(), `DELETE FROM agent_task_queue WHERE issue_id = $1`, id)
		_, _ = testPool.Exec(context.Background(), `DELETE FROM issue WHERE id = $1`, id)
	})
	return id
}

func createIssueTemplateSquad(t *testing.T, name string) (string, string) {
	t.Helper()
	leaderID := createHandlerTestAgent(t, name+" Leader", []byte("null"))
	var squadID string
	if err := testPool.QueryRow(context.Background(), `
		INSERT INTO squad (workspace_id, name, description, leader_id, creator_id)
		VALUES ($1, $2, '', $3, $4)
		RETURNING id
	`, testWorkspaceID, name, leaderID, testUserID).Scan(&squadID); err != nil {
		t.Fatalf("create squad: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testPool.Exec(context.Background(), `DELETE FROM squad WHERE id = $1`, squadID)
	})
	return squadID, leaderID
}

func TestIssueTemplateCRUDAndWorkspaceIsolation(t *testing.T) {
	ctx := context.Background()
	suffix := time.Now().UnixNano()

	var projectID string
	if err := testPool.QueryRow(ctx, `
		INSERT INTO project (workspace_id, title) VALUES ($1, $2) RETURNING id
	`, testWorkspaceID, fmt.Sprintf("Template project %d", suffix)).Scan(&projectID); err != nil {
		t.Fatalf("create project: %v", err)
	}
	t.Cleanup(func() { _, _ = testPool.Exec(context.Background(), `DELETE FROM project WHERE id = $1`, projectID) })
	parentID := createIssueTemplateParent(t, fmt.Sprintf("Template parent %d", suffix))
	squadID, _ := createIssueTemplateSquad(t, fmt.Sprintf("Template squad %d", suffix))

	body := issueTemplateTestBody("  Backend review  ", "  Review implementation  ")
	body["description"] = "Check tenancy and tests"
	body["priority"] = "high"
	body["status"] = "backlog"
	body["project_id"] = projectID
	body["assignee_type"] = "squad"
	body["assignee_id"] = squadID
	body["parent_issue_id"] = parentID
	body["stage"] = 2
	body["work_mode"] = "serial"
	created := createIssueTemplateForTest(t, body)
	if created.Name != "Backend review" || created.Title != "Review implementation" {
		t.Fatalf("create did not trim catalog fields: name=%q title=%q", created.Name, created.Title)
	}
	if created.ProjectID == nil || *created.ProjectID != projectID || created.AssigneeID == nil || *created.AssigneeID != squadID || created.Stage == nil || *created.Stage != 2 || created.WorkMode == nil || *created.WorkMode != "serial" {
		t.Fatalf("create did not preserve full template fields: %+v", created)
	}

	listW := httptest.NewRecorder()
	testHandler.ListIssueTemplates(listW, issueTemplateTestRequest(http.MethodGet, "/api/issue-templates", testUserID, testWorkspaceID, nil))
	if listW.Code != http.StatusOK {
		t.Fatalf("ListIssueTemplates: expected 200, got %d: %s", listW.Code, listW.Body.String())
	}
	var listed struct {
		IssueTemplates []IssueTemplateResponse `json:"issue_templates"`
	}
	if err := json.NewDecoder(listW.Body).Decode(&listed); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	found := false
	for _, item := range listed.IssueTemplates {
		found = found || item.ID == created.ID
	}
	if !found {
		t.Fatalf("created template %s missing from workspace list", created.ID)
	}

	replacement := issueTemplateTestBody("Renamed", "Replacement issue")
	replacement["description"] = "Replacement description"
	replacement["priority"] = "low"
	replacement["status"] = "in_review"
	replaceW := httptest.NewRecorder()
	replaceReq := issueTemplateTestRequest(http.MethodPut, "/api/issue-templates/"+created.ID, testUserID, testWorkspaceID, replacement)
	replaceReq = withURLParam(replaceReq, "id", created.ID)
	testHandler.ReplaceIssueTemplate(replaceW, replaceReq)
	if replaceW.Code != http.StatusOK {
		t.Fatalf("ReplaceIssueTemplate: expected 200, got %d: %s", replaceW.Code, replaceW.Body.String())
	}
	var replaced IssueTemplateResponse
	if err := json.NewDecoder(replaceW.Body).Decode(&replaced); err != nil {
		t.Fatalf("decode replacement: %v", err)
	}
	if replaced.Name != "Renamed" || replaced.Status != "in_review" || replaced.ProjectID != nil || replaced.AssigneeID != nil || replaced.ParentIssueID != nil || replaced.Stage != nil || replaced.WorkMode != nil {
		t.Fatalf("PUT did not replace and clear nullable fields: %+v", replaced)
	}

	var foreignWorkspaceID, foreignTemplateID string
	foreignSlug := fmt.Sprintf("template-foreign-%d", suffix)
	if err := testPool.QueryRow(ctx, `
		INSERT INTO workspace (name, slug, description) VALUES ('Template Foreign', $1, '') RETURNING id
	`, foreignSlug).Scan(&foreignWorkspaceID); err != nil {
		t.Fatalf("create foreign workspace: %v", err)
	}
	if err := testPool.QueryRow(ctx, `
		INSERT INTO issue_template (workspace_id, name, title, created_by_id)
		VALUES ($1, 'Foreign template', 'Foreign issue', $2) RETURNING id
	`, foreignWorkspaceID, testUserID).Scan(&foreignTemplateID); err != nil {
		t.Fatalf("create foreign template: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testPool.Exec(context.Background(), `DELETE FROM issue_template WHERE workspace_id = $1`, foreignWorkspaceID)
		_, _ = testPool.Exec(context.Background(), `DELETE FROM workspace WHERE id = $1`, foreignWorkspaceID)
	})

	for _, tc := range []struct {
		name   string
		method string
		body   any
		call   func(http.ResponseWriter, *http.Request)
	}{
		{name: "replace", method: http.MethodPut, body: issueTemplateTestBody("Nope", "Nope"), call: testHandler.ReplaceIssueTemplate},
		{name: "delete", method: http.MethodDelete, call: testHandler.DeleteIssueTemplate},
		{name: "instantiate", method: http.MethodPost, body: map[string]any{}, call: testHandler.InstantiateIssueTemplate},
	} {
		t.Run("cross workspace "+tc.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			req := issueTemplateTestRequest(tc.method, "/api/issue-templates/"+foreignTemplateID, testUserID, testWorkspaceID, tc.body)
			req = withURLParam(req, "id", foreignTemplateID)
			tc.call(w, req)
			if w.Code != http.StatusNotFound {
				t.Fatalf("expected tenant-scoped 404, got %d: %s", w.Code, w.Body.String())
			}
		})
	}

	deleteW := httptest.NewRecorder()
	deleteReq := issueTemplateTestRequest(http.MethodDelete, "/api/issue-templates/"+created.ID, testUserID, testWorkspaceID, nil)
	deleteReq = withURLParam(deleteReq, "id", created.ID)
	testHandler.DeleteIssueTemplate(deleteW, deleteReq)
	if deleteW.Code != http.StatusNoContent {
		t.Fatalf("DeleteIssueTemplate: expected 204, got %d: %s", deleteW.Code, deleteW.Body.String())
	}
	var count int
	if err := testPool.QueryRow(ctx, `SELECT count(*) FROM issue_template WHERE id = $1`, created.ID).Scan(&count); err != nil {
		t.Fatalf("count deleted template: %v", err)
	}
	if count != 0 {
		t.Fatalf("deleted template still exists: count=%d", count)
	}
}

func TestIssueTemplateManagementRolesAndMemberInstantiation(t *testing.T) {
	ctx := context.Background()
	suffix := time.Now().UnixNano()
	var memberUserID string
	if err := testPool.QueryRow(ctx, `
		INSERT INTO "user" (name, email) VALUES ('Template Member', $1) RETURNING id
	`, fmt.Sprintf("template-member-%d@example.test", suffix)).Scan(&memberUserID); err != nil {
		t.Fatalf("create member user: %v", err)
	}
	if _, err := testPool.Exec(ctx, `INSERT INTO member (workspace_id, user_id, role) VALUES ($1, $2, 'member')`, testWorkspaceID, memberUserID); err != nil {
		t.Fatalf("create member: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testPool.Exec(context.Background(), `DELETE FROM member WHERE workspace_id = $1 AND user_id = $2`, testWorkspaceID, memberUserID)
		_, _ = testPool.Exec(context.Background(), `DELETE FROM "user" WHERE id = $1`, memberUserID)
	})

	var templateID string
	if err := testPool.QueryRow(ctx, `
		INSERT INTO issue_template (workspace_id, name, title, description, priority, status, created_by_id)
		VALUES ($1, 'Member usable', 'Created by member use', 'ordinary fields', 'medium', 'todo', $2)
		RETURNING id
	`, testWorkspaceID, testUserID).Scan(&templateID); err != nil {
		t.Fatalf("seed template: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testPool.Exec(context.Background(), `DELETE FROM issue_template WHERE id = $1`, templateID)
	})

	listW := httptest.NewRecorder()
	testHandler.ListIssueTemplates(listW, issueTemplateTestRequest(http.MethodGet, "/api/issue-templates", memberUserID, testWorkspaceID, nil))
	if listW.Code != http.StatusOK {
		t.Fatalf("member list: expected 200, got %d: %s", listW.Code, listW.Body.String())
	}

	forbiddenW := httptest.NewRecorder()
	testHandler.CreateIssueTemplate(forbiddenW, issueTemplateTestRequest(http.MethodPost, "/api/issue-templates", memberUserID, testWorkspaceID, issueTemplateTestBody("Forbidden", "Forbidden")))
	if forbiddenW.Code != http.StatusForbidden {
		t.Fatalf("member management: expected 403, got %d: %s", forbiddenW.Code, forbiddenW.Body.String())
	}

	instantiateW := httptest.NewRecorder()
	instantiateReq := issueTemplateTestRequest(http.MethodPost, "/api/issue-templates/"+templateID+"/instantiate", memberUserID, testWorkspaceID, map[string]any{})
	instantiateReq = withURLParam(instantiateReq, "id", templateID)
	testHandler.InstantiateIssueTemplate(instantiateW, instantiateReq)
	if instantiateW.Code != http.StatusCreated {
		t.Fatalf("member instantiate: expected 201, got %d: %s", instantiateW.Code, instantiateW.Body.String())
	}
	var issue IssueResponse
	if err := json.NewDecoder(instantiateW.Body).Decode(&issue); err != nil {
		t.Fatalf("decode instantiated issue: %v", err)
	}
	if issue.Title != "Created by member use" || issue.Description == nil || *issue.Description != "ordinary fields" || issue.Priority != "medium" || issue.Status != "todo" {
		t.Fatalf("ordinary fields were not passed through: %+v", issue)
	}
	t.Cleanup(func() { _, _ = testPool.Exec(context.Background(), `DELETE FROM issue WHERE id = $1`, issue.ID) })

	if _, err := testPool.Exec(ctx, `UPDATE member SET role = 'admin' WHERE workspace_id = $1 AND user_id = $2`, testWorkspaceID, memberUserID); err != nil {
		t.Fatalf("promote member to admin: %v", err)
	}
	adminW := httptest.NewRecorder()
	testHandler.CreateIssueTemplate(adminW, issueTemplateTestRequest(http.MethodPost, "/api/issue-templates", memberUserID, testWorkspaceID, issueTemplateTestBody("Admin template", "Admin issue")))
	if adminW.Code != http.StatusCreated {
		t.Fatalf("admin management: expected 201, got %d: %s", adminW.Code, adminW.Body.String())
	}
	var adminTemplate IssueTemplateResponse
	_ = json.NewDecoder(adminW.Body).Decode(&adminTemplate)
	t.Cleanup(func() {
		_, _ = testPool.Exec(context.Background(), `DELETE FROM issue_template WHERE id = $1`, adminTemplate.ID)
	})

	var actingAgentID string
	if err := testPool.QueryRow(ctx, `SELECT id FROM agent WHERE workspace_id = $1 ORDER BY created_at ASC LIMIT 1`, testWorkspaceID).Scan(&actingAgentID); err != nil {
		t.Fatalf("load acting agent: %v", err)
	}
	taskID := createHandlerTestTaskForAgent(t, actingAgentID)
	agentReq := issueTemplateTestRequest(http.MethodPost, "/api/issue-templates", testUserID, testWorkspaceID, issueTemplateTestBody("Agent forbidden", "Agent forbidden"))
	agentReq.Header.Set("X-Agent-ID", actingAgentID)
	agentReq.Header.Set("X-Task-ID", taskID)
	agentW := httptest.NewRecorder()
	testHandler.CreateIssueTemplate(agentW, agentReq)
	if agentW.Code != http.StatusForbidden {
		t.Fatalf("task agent management: expected 403, got %d: %s", agentW.Code, agentW.Body.String())
	}
}

func TestIssueTemplateAssociationValidation(t *testing.T) {
	ctx := context.Background()
	suffix := time.Now().UnixNano()
	var foreignWorkspaceID, foreignUserID, foreignProjectID, foreignParentID, foreignAgentID, foreignSquadID string
	if err := testPool.QueryRow(ctx, `INSERT INTO "user" (name, email) VALUES ('Foreign Template User', $1) RETURNING id`, fmt.Sprintf("foreign-template-%d@example.test", suffix)).Scan(&foreignUserID); err != nil {
		t.Fatalf("create foreign user: %v", err)
	}
	if err := testPool.QueryRow(ctx, `INSERT INTO workspace (name, slug, description) VALUES ('Foreign Template WS', $1, '') RETURNING id`, fmt.Sprintf("foreign-template-%d", suffix)).Scan(&foreignWorkspaceID); err != nil {
		t.Fatalf("create foreign workspace: %v", err)
	}
	if _, err := testPool.Exec(ctx, `INSERT INTO member (workspace_id, user_id, role) VALUES ($1, $2, 'owner')`, foreignWorkspaceID, foreignUserID); err != nil {
		t.Fatalf("create foreign member: %v", err)
	}
	if err := testPool.QueryRow(ctx, `INSERT INTO project (workspace_id, title) VALUES ($1, 'Foreign project') RETURNING id`, foreignWorkspaceID).Scan(&foreignProjectID); err != nil {
		t.Fatalf("create foreign project: %v", err)
	}
	if err := testPool.QueryRow(ctx, `INSERT INTO issue (workspace_id, title, creator_type, creator_id) VALUES ($1, 'Foreign parent', 'member', $2) RETURNING id`, foreignWorkspaceID, foreignUserID).Scan(&foreignParentID); err != nil {
		t.Fatalf("create foreign parent: %v", err)
	}
	if err := testPool.QueryRow(ctx, `INSERT INTO agent (workspace_id, name, owner_id, runtime_mode, runtime_config) VALUES ($1, 'Foreign leader', $2, 'cloud', '{}'::jsonb) RETURNING id`, foreignWorkspaceID, foreignUserID).Scan(&foreignAgentID); err != nil {
		t.Fatalf("create foreign agent: %v", err)
	}
	if err := testPool.QueryRow(ctx, `INSERT INTO squad (workspace_id, name, leader_id, creator_id) VALUES ($1, 'Foreign squad', $2, $3) RETURNING id`, foreignWorkspaceID, foreignAgentID, foreignUserID).Scan(&foreignSquadID); err != nil {
		t.Fatalf("create foreign squad: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx := context.Background()
		_, _ = testPool.Exec(cleanupCtx, `DELETE FROM issue_template WHERE workspace_id = $1`, foreignWorkspaceID)
		_, _ = testPool.Exec(cleanupCtx, `DELETE FROM squad WHERE id = $1`, foreignSquadID)
		_, _ = testPool.Exec(cleanupCtx, `DELETE FROM agent WHERE id = $1`, foreignAgentID)
		_, _ = testPool.Exec(cleanupCtx, `DELETE FROM issue WHERE id = $1`, foreignParentID)
		_, _ = testPool.Exec(cleanupCtx, `DELETE FROM project WHERE id = $1`, foreignProjectID)
		_, _ = testPool.Exec(cleanupCtx, `DELETE FROM member WHERE workspace_id = $1 AND user_id = $2`, foreignWorkspaceID, foreignUserID)
		_, _ = testPool.Exec(cleanupCtx, `DELETE FROM workspace WHERE id = $1`, foreignWorkspaceID)
		_, _ = testPool.Exec(cleanupCtx, `DELETE FROM "user" WHERE id = $1`, foreignUserID)
	})

	tests := []struct {
		name  string
		patch map[string]any
	}{
		{name: "foreign project", patch: map[string]any{"project_id": foreignProjectID}},
		{name: "foreign parent", patch: map[string]any{"parent_issue_id": foreignParentID}},
		{name: "foreign member", patch: map[string]any{"assignee_type": "member", "assignee_id": foreignUserID}},
		{name: "foreign agent", patch: map[string]any{"assignee_type": "agent", "assignee_id": foreignAgentID}},
		{name: "foreign squad", patch: map[string]any{"assignee_type": "squad", "assignee_id": foreignSquadID}},
		{name: "unpaired assignee", patch: map[string]any{"assignee_type": "squad"}},
		{name: "stage without parent", patch: map[string]any{"stage": 1}},
		{name: "invalid work mode", patch: map[string]any{"work_mode": "scheduler"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			body := issueTemplateTestBody("Invalid relation", "Invalid relation")
			for key, value := range tc.patch {
				body[key] = value
			}
			w := httptest.NewRecorder()
			testHandler.CreateIssueTemplate(w, issueTemplateTestRequest(http.MethodPost, "/api/issue-templates", testUserID, testWorkspaceID, body))
			if w.Code != http.StatusBadRequest {
				t.Fatalf("expected 400, got %d: %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestInstantiateIssueTemplateUsesExistingStageAndSquadScheduling(t *testing.T) {
	ctx := context.Background()
	suffix := time.Now().UnixNano()
	parentID := createIssueTemplateParent(t, fmt.Sprintf("Scheduling parent %d", suffix))
	squadID, leaderID := createIssueTemplateSquad(t, fmt.Sprintf("Scheduling squad %d", suffix))

	serialBody := issueTemplateTestBody(fmt.Sprintf("Serial %d", suffix), fmt.Sprintf("Serial parked %d", suffix))
	serialBody["status"] = "backlog"
	serialBody["assignee_type"] = "squad"
	serialBody["assignee_id"] = squadID
	serialBody["parent_issue_id"] = parentID
	serialBody["stage"] = 2
	serialBody["work_mode"] = "serial"
	serialTemplate := createIssueTemplateForTest(t, serialBody)

	var beforeIssues int
	if err := testPool.QueryRow(ctx, `SELECT count(*) FROM issue WHERE workspace_id = $1`, testWorkspaceID).Scan(&beforeIssues); err != nil {
		t.Fatalf("count issues before serial instantiate: %v", err)
	}
	serialW := httptest.NewRecorder()
	serialReq := issueTemplateTestRequest(http.MethodPost, "/api/issue-templates/"+serialTemplate.ID+"/instantiate", testUserID, testWorkspaceID, map[string]any{})
	serialReq = withURLParam(serialReq, "id", serialTemplate.ID)
	testHandler.InstantiateIssueTemplate(serialW, serialReq)
	if serialW.Code != http.StatusCreated {
		t.Fatalf("serial instantiate: expected 201, got %d: %s", serialW.Code, serialW.Body.String())
	}
	var serialIssue IssueResponse
	if err := json.NewDecoder(serialW.Body).Decode(&serialIssue); err != nil {
		t.Fatalf("decode serial issue: %v", err)
	}
	if serialIssue.Status != "backlog" || serialIssue.Stage == nil || *serialIssue.Stage != 2 || serialIssue.ParentIssueID == nil || *serialIssue.ParentIssueID != parentID || serialIssue.AssigneeType == nil || *serialIssue.AssigneeType != "squad" {
		t.Fatalf("serial template semantics not passed to ordinary issue: %+v", serialIssue)
	}
	t.Cleanup(func() {
		_, _ = testPool.Exec(context.Background(), `DELETE FROM agent_task_queue WHERE issue_id = $1`, serialIssue.ID)
		_, _ = testPool.Exec(context.Background(), `DELETE FROM issue WHERE id = $1`, serialIssue.ID)
	})
	var afterSerial, serialTasks int
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM issue WHERE workspace_id = $1`, testWorkspaceID).Scan(&afterSerial)
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM agent_task_queue WHERE issue_id = $1`, serialIssue.ID).Scan(&serialTasks)
	if afterSerial != beforeIssues+1 {
		t.Fatalf("serial instantiate created %d issues, want exactly 1", afterSerial-beforeIssues)
	}
	if serialTasks != 0 {
		t.Fatalf("backlog serial issue enqueued %d tasks, want 0", serialTasks)
	}

	swarmBody := issueTemplateTestBody(fmt.Sprintf("Swarm %d", suffix), fmt.Sprintf("Swarm sibling %d", suffix))
	swarmBody["status"] = "todo"
	swarmBody["assignee_type"] = "squad"
	swarmBody["assignee_id"] = squadID
	swarmBody["parent_issue_id"] = parentID
	swarmBody["stage"] = 3
	swarmBody["work_mode"] = "swarm"
	swarmTemplate := createIssueTemplateForTest(t, swarmBody)
	swarmW := httptest.NewRecorder()
	swarmReq := issueTemplateTestRequest(http.MethodPost, "/api/issue-templates/"+swarmTemplate.ID+"/instantiate", testUserID, testWorkspaceID, map[string]any{})
	swarmReq = withURLParam(swarmReq, "id", swarmTemplate.ID)
	testHandler.InstantiateIssueTemplate(swarmW, swarmReq)
	if swarmW.Code != http.StatusCreated {
		t.Fatalf("swarm instantiate: expected 201, got %d: %s", swarmW.Code, swarmW.Body.String())
	}
	var swarmIssue IssueResponse
	if err := json.NewDecoder(swarmW.Body).Decode(&swarmIssue); err != nil {
		t.Fatalf("decode swarm issue: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testPool.Exec(context.Background(), `DELETE FROM agent_task_queue WHERE issue_id = $1`, swarmIssue.ID)
		_, _ = testPool.Exec(context.Background(), `DELETE FROM issue WHERE id = $1`, swarmIssue.ID)
	})
	if swarmIssue.Status != "todo" || swarmIssue.Stage == nil || *swarmIssue.Stage != 3 {
		t.Fatalf("swarm status/stage not preserved: %+v", swarmIssue)
	}
	var taskCount int
	var queuedLeaderID, queuedSquadID string
	var isLeader bool
	if err := testPool.QueryRow(ctx, `
		SELECT count(*) OVER (), agent_id::text, squad_id::text, is_leader_task
		FROM agent_task_queue
		WHERE issue_id = $1 AND status = 'queued'
	`, swarmIssue.ID).Scan(&taskCount, &queuedLeaderID, &queuedSquadID, &isLeader); err != nil {
		t.Fatalf("load swarm leader task: %v", err)
	}
	if taskCount != 1 || queuedLeaderID != leaderID || queuedSquadID != squadID || !isLeader {
		t.Fatalf("swarm should reuse one existing squad-leader enqueue: count=%d leader=%s squad=%s isLeader=%v", taskCount, queuedLeaderID, queuedSquadID, isLeader)
	}

	var issueCount int
	if err := testPool.QueryRow(ctx, `SELECT count(*) FROM issue WHERE id IN ($1, $2)`, serialIssue.ID, swarmIssue.ID).Scan(&issueCount); err != nil {
		t.Fatalf("count instantiated issues: %v", err)
	}
	if issueCount != 2 {
		t.Fatalf("two template uses should produce two ordinary issues, got %d", issueCount)
	}
}

func TestInstantiateIssueTemplateRevalidatesStaleProject(t *testing.T) {
	ctx := context.Background()
	var projectID string
	if err := testPool.QueryRow(ctx, `INSERT INTO project (workspace_id, title) VALUES ($1, 'Stale template project') RETURNING id`, testWorkspaceID).Scan(&projectID); err != nil {
		t.Fatalf("create project: %v", err)
	}
	body := issueTemplateTestBody("Stale project", "Must not be created")
	body["project_id"] = projectID
	template := createIssueTemplateForTest(t, body)
	if _, err := testPool.Exec(ctx, `DELETE FROM project WHERE id = $1`, projectID); err != nil {
		t.Fatalf("delete project: %v", err)
	}

	var before int
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM issue WHERE workspace_id = $1 AND title = 'Must not be created'`, testWorkspaceID).Scan(&before)
	w := httptest.NewRecorder()
	req := issueTemplateTestRequest(http.MethodPost, "/api/issue-templates/"+template.ID+"/instantiate", testUserID, testWorkspaceID, map[string]any{})
	req = withURLParam(req, "id", template.ID)
	testHandler.InstantiateIssueTemplate(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("stale project instantiate: expected 400, got %d: %s", w.Code, w.Body.String())
	}
	var after int
	_ = testPool.QueryRow(ctx, `SELECT count(*) FROM issue WHERE workspace_id = $1 AND title = 'Must not be created'`, testWorkspaceID).Scan(&after)
	if after != before {
		t.Fatalf("stale template created an issue despite failed relation validation: before=%d after=%d", before, after)
	}
}

func createIssueTemplateRaceWorkspace(t *testing.T, label string) (string, db.Member) {
	t.Helper()
	ctx := context.Background()
	slug := fmt.Sprintf("issue-template-race-%s-%d", label, time.Now().UnixNano())
	var workspaceID string
	if err := testPool.QueryRow(ctx, `
		INSERT INTO workspace (name, slug, description)
		VALUES ('Issue template race', $1, '')
		RETURNING id
	`, slug).Scan(&workspaceID); err != nil {
		t.Fatalf("create issue template race workspace: %v", err)
	}
	if _, err := testPool.Exec(ctx, `
		INSERT INTO member (workspace_id, user_id, role)
		VALUES ($1, $2, 'owner')
	`, workspaceID, testUserID); err != nil {
		t.Fatalf("create issue template race owner: %v", err)
	}
	member, err := testHandler.Queries.GetMemberByUserAndWorkspace(ctx, db.GetMemberByUserAndWorkspaceParams{
		UserID:      parseUUID(testUserID),
		WorkspaceID: parseUUID(workspaceID),
	})
	if err != nil {
		t.Fatalf("load issue template race owner: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testPool.Exec(context.Background(), `DELETE FROM issue_template WHERE workspace_id = $1`, workspaceID)
		_, _ = testPool.Exec(context.Background(), `DELETE FROM member WHERE workspace_id = $1`, workspaceID)
		_, _ = testPool.Exec(context.Background(), `DELETE FROM workspace WHERE id = $1`, workspaceID)
	})
	return workspaceID, member
}

func issueTemplateRaceCreateRequest(workspaceID string, member db.Member) *http.Request {
	req := issueTemplateTestRequest(http.MethodPost, "/api/issue-templates", testUserID, workspaceID, issueTemplateTestBody("Race template", "Race issue"))
	return req.WithContext(middleware.SetMemberContext(req.Context(), workspaceID, member))
}

func TestCreateIssueTemplate_DeleteCommitsFirstReturnsNotFoundWithoutOrphan(t *testing.T) {
	if testHandler == nil {
		t.Skip("database not available")
	}
	ctx := context.Background()
	workspaceID, member := createIssueTemplateRaceWorkspace(t, "delete-first")

	deleteTx, err := testPool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin workspace delete lock: %v", err)
	}
	defer deleteTx.Rollback(ctx)
	if _, err := deleteTx.Exec(ctx, `SELECT id FROM workspace WHERE id = $1 FOR UPDATE`, workspaceID); err != nil {
		t.Fatalf("lock workspace for delete: %v", err)
	}

	type handlerResult struct {
		code int
		body string
	}
	result := make(chan handlerResult, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		w := httptest.NewRecorder()
		testHandler.CreateIssueTemplate(w, issueTemplateRaceCreateRequest(workspaceID, member))
		result <- handlerResult{code: w.Code, body: w.Body.String()}
	}()

	if !waitForBlockedBackend(t, done) {
		t.Fatal("CreateIssueTemplate returned while workspace delete lock was held; creator did not take the required FOR KEY SHARE lock")
	}
	if _, err := deleteTx.Exec(ctx, `DELETE FROM member WHERE workspace_id = $1`, workspaceID); err != nil {
		t.Fatalf("delete race workspace member: %v", err)
	}
	if _, err := deleteTx.Exec(ctx, `DELETE FROM workspace WHERE id = $1`, workspaceID); err != nil {
		t.Fatalf("delete race workspace: %v", err)
	}
	if err := deleteTx.Commit(ctx); err != nil {
		t.Fatalf("commit workspace delete: %v", err)
	}

	<-done
	got := <-result
	if got.code != http.StatusNotFound {
		t.Fatalf("CreateIssueTemplate after workspace delete: got %d (%s), want 404", got.code, got.body)
	}
	var count int
	if err := testPool.QueryRow(ctx, `SELECT COUNT(*) FROM issue_template WHERE workspace_id = $1`, workspaceID).Scan(&count); err != nil {
		t.Fatalf("count orphan issue templates: %v", err)
	}
	if count != 0 {
		t.Fatalf("workspace delete left %d orphan issue templates", count)
	}
}

func TestCreateIssueTemplate_LockFirstMakesDeleteWaitAndSweepTemplate(t *testing.T) {
	if testHandler == nil {
		t.Skip("database not available")
	}
	ctx := context.Background()
	workspaceID, member := createIssueTemplateRaceWorkspace(t, "create-first")

	createTx, err := testPool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin issue template create transaction: %v", err)
	}
	defer createTx.Rollback(ctx)
	qtx := testHandler.Queries.WithTx(createTx)
	if _, err := qtx.LockWorkspaceForChatSessionCreate(ctx, parseUUID(workspaceID)); err != nil {
		t.Fatalf("lock workspace for issue template create: %v", err)
	}
	created, err := qtx.CreateIssueTemplate(ctx, db.CreateIssueTemplateParams{
		WorkspaceID: parseUUID(workspaceID),
		Name:        "Create first",
		Title:       "Created before workspace delete",
		Description: "",
		Priority:    "none",
		Status:      "todo",
		CreatedByID: parseUUID(testUserID),
	})
	if err != nil {
		t.Fatalf("insert issue template while holding workspace lock: %v", err)
	}

	type handlerResult struct {
		code int
		body string
	}
	result := make(chan handlerResult, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		w := httptest.NewRecorder()
		req := issueTemplateTestRequest(http.MethodDelete, "/api/workspaces/"+workspaceID, testUserID, workspaceID, nil)
		req = withURLParam(req, "id", workspaceID)
		req = req.WithContext(middleware.SetMemberContext(req.Context(), workspaceID, member))
		testHandler.DeleteWorkspace(w, req)
		result <- handlerResult{code: w.Code, body: w.Body.String()}
	}()

	if !waitForBlockedBackend(t, done) {
		t.Fatal("DeleteWorkspace returned while issue template create held FOR KEY SHARE; delete/create protocol was bypassed")
	}
	if err := createTx.Commit(ctx); err != nil {
		t.Fatalf("commit issue template create: %v", err)
	}

	<-done
	got := <-result
	if got.code != http.StatusNoContent {
		t.Fatalf("DeleteWorkspace after template create: got %d (%s), want 204", got.code, got.body)
	}
	var count int
	if err := testPool.QueryRow(ctx, `SELECT COUNT(*) FROM issue_template WHERE id = $1`, created.ID).Scan(&count); err != nil {
		t.Fatalf("count swept issue template: %v", err)
	}
	if count != 0 {
		t.Fatalf("workspace delete did not sweep committed issue template %s", uuidToString(created.ID))
	}
}
