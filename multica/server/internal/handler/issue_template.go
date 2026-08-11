package handler

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/multica-ai/multica/server/internal/logger"
	db "github.com/multica-ai/multica/server/pkg/db/generated"
)

const (
	issueTemplateNameMaxRunes        = 64
	issueTemplateTitleMaxRunes       = 1024
	issueTemplateDescriptionMaxRunes = 100000
)

type IssueTemplateRequest struct {
	Name          string  `json:"name"`
	Title         string  `json:"title"`
	Description   string  `json:"description"`
	Priority      string  `json:"priority"`
	Status        string  `json:"status"`
	ProjectID     *string `json:"project_id"`
	AssigneeType  *string `json:"assignee_type"`
	AssigneeID    *string `json:"assignee_id"`
	ParentIssueID *string `json:"parent_issue_id"`
	Stage         *int32  `json:"stage"`
	WorkMode      *string `json:"work_mode"`
}

type IssueTemplateResponse struct {
	ID            string  `json:"id"`
	WorkspaceID   string  `json:"workspace_id"`
	Name          string  `json:"name"`
	Title         string  `json:"title"`
	Description   string  `json:"description"`
	Priority      string  `json:"priority"`
	Status        string  `json:"status"`
	ProjectID     *string `json:"project_id"`
	AssigneeType  *string `json:"assignee_type"`
	AssigneeID    *string `json:"assignee_id"`
	ParentIssueID *string `json:"parent_issue_id"`
	Stage         *int32  `json:"stage"`
	WorkMode      *string `json:"work_mode"`
	CreatedByID   string  `json:"created_by_id"`
	CreatedAt     string  `json:"created_at"`
	UpdatedAt     string  `json:"updated_at"`
}

type issueTemplateValues struct {
	Name          string
	Title         string
	Description   string
	Priority      string
	Status        string
	ProjectID     pgtype.UUID
	AssigneeType  pgtype.Text
	AssigneeID    pgtype.UUID
	ParentIssueID pgtype.UUID
	Stage         pgtype.Int4
	WorkMode      pgtype.Text
}

func issueTemplateToResponse(t db.IssueTemplate) IssueTemplateResponse {
	return IssueTemplateResponse{
		ID: uuidToString(t.ID), WorkspaceID: uuidToString(t.WorkspaceID),
		Name: t.Name, Title: t.Title, Description: t.Description,
		Priority: t.Priority, Status: t.Status, ProjectID: uuidToPtr(t.ProjectID),
		AssigneeType: textToPtr(t.AssigneeType), AssigneeID: uuidToPtr(t.AssigneeID),
		ParentIssueID: uuidToPtr(t.ParentIssueID), Stage: int4ToPtr(t.Stage),
		WorkMode: textToPtr(t.WorkMode), CreatedByID: uuidToString(t.CreatedByID),
		CreatedAt: timestampToString(t.CreatedAt), UpdatedAt: timestampToString(t.UpdatedAt),
	}
}

func issueTemplateModeError(mode *string, status string, assigneeType pgtype.Text, parentIssueID pgtype.UUID, stage pgtype.Int4) string {
	if mode == nil {
		return ""
	}
	if *mode != "serial" && *mode != "swarm" {
		return "work_mode must be 'serial' or 'swarm'"
	}
	if !assigneeType.Valid || assigneeType.String != "squad" || !parentIssueID.Valid || !stage.Valid {
		return "work_mode requires a squad assignee, parent_issue_id, and stage"
	}
	if *mode == "serial" && status != "todo" && status != "backlog" {
		return "serial templates require todo or backlog status"
	}
	if *mode == "swarm" && status != "todo" {
		return "swarm templates require todo status"
	}
	return ""
}

func decodeIssueTemplateRequest(w http.ResponseWriter, r *http.Request) (IssueTemplateRequest, bool) {
	var req IssueTemplateRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return req, false
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "request body must contain one JSON object")
		return req, false
	}
	return req, true
}

func (h *Handler) requireIssueTemplateManager(w http.ResponseWriter, r *http.Request) (string, pgtype.UUID, string, bool) {
	workspaceID := h.resolveWorkspaceID(r)
	wsUUID, ok := parseUUIDOrBadRequest(w, workspaceID, "workspace_id")
	if !ok {
		return "", pgtype.UUID{}, "", false
	}
	userID, ok := requireUserID(w, r)
	if !ok {
		return "", pgtype.UUID{}, "", false
	}
	actorType, _ := h.resolveActor(r, userID, workspaceID)
	if actorType != "member" {
		writeError(w, http.StatusForbidden, "agents cannot manage issue templates")
		return "", pgtype.UUID{}, "", false
	}
	if _, ok := h.requireWorkspaceRole(w, r, workspaceID, "workspace not found", "owner", "admin"); !ok {
		return "", pgtype.UUID{}, "", false
	}
	return workspaceID, wsUUID, userID, true
}

func (h *Handler) validateIssueTemplateRequest(w http.ResponseWriter, r *http.Request, workspaceID string, wsUUID pgtype.UUID, req IssueTemplateRequest) (issueTemplateValues, bool) {
	v := issueTemplateValues{
		Name: strings.TrimSpace(req.Name), Title: strings.TrimSpace(req.Title),
		Description: req.Description, Priority: req.Priority, Status: req.Status,
	}
	if v.Name == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return v, false
	}
	if len([]rune(v.Name)) > issueTemplateNameMaxRunes {
		writeError(w, http.StatusBadRequest, "name must be at most 64 characters")
		return v, false
	}
	if v.Title == "" {
		writeError(w, http.StatusBadRequest, "title is required")
		return v, false
	}
	if len([]rune(v.Title)) > issueTemplateTitleMaxRunes {
		writeError(w, http.StatusBadRequest, "title is too long")
		return v, false
	}
	if len([]rune(v.Description)) > issueTemplateDescriptionMaxRunes {
		writeError(w, http.StatusBadRequest, "description is too long")
		return v, false
	}
	if v.Priority == "" {
		v.Priority = "none"
	}
	if v.Status == "" {
		v.Status = "todo"
	}
	if !validateIssueEnum(w, "priority", v.Priority, validIssuePriorities) || !validateIssueEnum(w, "status", v.Status, validIssueStatuses) {
		return v, false
	}

	if req.ProjectID != nil {
		id, ok := parseUUIDOrBadRequest(w, *req.ProjectID, "project_id")
		if !ok {
			return v, false
		}
		if _, err := h.Queries.GetProjectInWorkspace(r.Context(), db.GetProjectInWorkspaceParams{ID: id, WorkspaceID: wsUUID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				writeError(w, http.StatusBadRequest, "project not found in this workspace")
			} else {
				writeError(w, http.StatusInternalServerError, "failed to validate project")
			}
			return v, false
		}
		v.ProjectID = id
	}
	if req.ParentIssueID != nil {
		id, ok := parseUUIDOrBadRequest(w, *req.ParentIssueID, "parent_issue_id")
		if !ok {
			return v, false
		}
		if _, err := h.Queries.GetIssueInWorkspace(r.Context(), db.GetIssueInWorkspaceParams{ID: id, WorkspaceID: wsUUID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				writeError(w, http.StatusBadRequest, "parent issue not found in this workspace")
			} else {
				writeError(w, http.StatusInternalServerError, "failed to validate parent issue")
			}
			return v, false
		}
		v.ParentIssueID = id
	}
	if req.AssigneeType != nil {
		v.AssigneeType = pgtype.Text{String: *req.AssigneeType, Valid: true}
	}
	if req.AssigneeID != nil {
		id, ok := parseUUIDOrBadRequest(w, *req.AssigneeID, "assignee_id")
		if !ok {
			return v, false
		}
		v.AssigneeID = id
	}
	if status, msg := h.validateAssigneePair(r.Context(), r, workspaceID, v.AssigneeType, v.AssigneeID); status != 0 {
		writeError(w, status, msg)
		return v, false
	}

	if req.Stage != nil {
		if *req.Stage < 1 {
			writeError(w, http.StatusBadRequest, "stage must be >= 1")
			return v, false
		}
		if !v.ParentIssueID.Valid {
			writeError(w, http.StatusBadRequest, "stage requires parent_issue_id")
			return v, false
		}
		v.Stage = pgtype.Int4{Int32: *req.Stage, Valid: true}
	}
	if msg := issueTemplateModeError(req.WorkMode, v.Status, v.AssigneeType, v.ParentIssueID, v.Stage); msg != "" {
		writeError(w, http.StatusBadRequest, msg)
		return v, false
	}
	if req.WorkMode != nil {
		v.WorkMode = pgtype.Text{String: *req.WorkMode, Valid: true}
	}
	return v, true
}

func (h *Handler) ListIssueTemplates(w http.ResponseWriter, r *http.Request) {
	workspaceID := h.resolveWorkspaceID(r)
	wsUUID, ok := parseUUIDOrBadRequest(w, workspaceID, "workspace_id")
	if !ok {
		return
	}
	rows, err := h.Queries.ListIssueTemplates(r.Context(), wsUUID)
	if err != nil {
		slog.Warn("list issue templates failed", append(logger.RequestAttrs(r), "error", err)...)
		writeError(w, http.StatusInternalServerError, "failed to list issue templates")
		return
	}
	items := make([]IssueTemplateResponse, 0, len(rows))
	for _, row := range rows {
		items = append(items, issueTemplateToResponse(row))
	}
	writeJSON(w, http.StatusOK, map[string]any{"issue_templates": items})
}

func (h *Handler) CreateIssueTemplate(w http.ResponseWriter, r *http.Request) {
	workspaceID, wsUUID, userID, ok := h.requireIssueTemplateManager(w, r)
	if !ok {
		return
	}
	req, ok := decodeIssueTemplateRequest(w, r)
	if !ok {
		return
	}
	v, ok := h.validateIssueTemplateRequest(w, r, workspaceID, wsUUID, req)
	if !ok {
		return
	}
	// issue_template intentionally has no foreign keys. Take the creator side of
	// the workspace delete/create protocol explicitly so the delete sweep cannot
	// commit between authorization and this insert, leaving an unreachable row.
	tx, err := h.TxStarter.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to start transaction")
		return
	}
	defer tx.Rollback(r.Context())
	qtx := h.Queries.WithTx(tx)
	if _, err := qtx.LockWorkspaceForChatSessionCreate(r.Context(), wsUUID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "workspace not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to lock workspace")
		return
	}
	row, err := qtx.CreateIssueTemplate(r.Context(), db.CreateIssueTemplateParams{WorkspaceID: wsUUID, Name: v.Name, Title: v.Title, Description: v.Description, Priority: v.Priority, Status: v.Status, ProjectID: v.ProjectID, AssigneeType: v.AssigneeType, AssigneeID: v.AssigneeID, ParentIssueID: v.ParentIssueID, Stage: v.Stage, WorkMode: v.WorkMode, CreatedByID: parseUUID(userID)})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create issue template")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create issue template")
		return
	}
	writeJSON(w, http.StatusCreated, issueTemplateToResponse(row))
}

func (h *Handler) ReplaceIssueTemplate(w http.ResponseWriter, r *http.Request) {
	workspaceID, wsUUID, _, ok := h.requireIssueTemplateManager(w, r)
	if !ok {
		return
	}
	id, ok := parseUUIDOrBadRequest(w, chi.URLParam(r, "id"), "id")
	if !ok {
		return
	}
	if _, err := h.Queries.GetIssueTemplate(r.Context(), db.GetIssueTemplateParams{ID: id, WorkspaceID: wsUUID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "issue template not found")
		} else {
			writeError(w, http.StatusInternalServerError, "failed to load issue template")
		}
		return
	}
	req, ok := decodeIssueTemplateRequest(w, r)
	if !ok {
		return
	}
	v, ok := h.validateIssueTemplateRequest(w, r, workspaceID, wsUUID, req)
	if !ok {
		return
	}
	row, err := h.Queries.ReplaceIssueTemplate(r.Context(), db.ReplaceIssueTemplateParams{ID: id, WorkspaceID: wsUUID, Name: v.Name, Title: v.Title, Description: v.Description, Priority: v.Priority, Status: v.Status, ProjectID: v.ProjectID, AssigneeType: v.AssigneeType, AssigneeID: v.AssigneeID, ParentIssueID: v.ParentIssueID, Stage: v.Stage, WorkMode: v.WorkMode})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to update issue template")
		return
	}
	writeJSON(w, http.StatusOK, issueTemplateToResponse(row))
}

func (h *Handler) DeleteIssueTemplate(w http.ResponseWriter, r *http.Request) {
	_, wsUUID, _, ok := h.requireIssueTemplateManager(w, r)
	if !ok {
		return
	}
	id, ok := parseUUIDOrBadRequest(w, chi.URLParam(r, "id"), "id")
	if !ok {
		return
	}
	if _, err := h.Queries.GetIssueTemplate(r.Context(), db.GetIssueTemplateParams{ID: id, WorkspaceID: wsUUID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "issue template not found")
		} else {
			writeError(w, http.StatusInternalServerError, "failed to load issue template")
		}
		return
	}
	if err := h.Queries.DeleteIssueTemplate(r.Context(), db.DeleteIssueTemplateParams{ID: id, WorkspaceID: wsUUID}); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete issue template")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type instantiateIssueTemplateRequest struct {
	AllowDuplicate bool `json:"allow_duplicate"`
}

func (h *Handler) InstantiateIssueTemplate(w http.ResponseWriter, r *http.Request) {
	workspaceID := h.resolveWorkspaceID(r)
	wsUUID, ok := parseUUIDOrBadRequest(w, workspaceID, "workspace_id")
	if !ok {
		return
	}
	id, ok := parseUUIDOrBadRequest(w, chi.URLParam(r, "id"), "id")
	if !ok {
		return
	}
	var req instantiateIssueTemplateRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "request body must contain one JSON object")
		return
	}
	tmpl, err := h.Queries.GetIssueTemplate(r.Context(), db.GetIssueTemplateParams{ID: id, WorkspaceID: wsUUID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "issue template not found")
		} else {
			writeError(w, http.StatusInternalServerError, "failed to load issue template")
		}
		return
	}
	// Re-run assignee validation at instantiation time because membership,
	// archival state, and private invocation permissions can drift after save.
	if status, msg := h.validateAssigneePair(r.Context(), r, workspaceID, tmpl.AssigneeType, tmpl.AssigneeID); status != 0 {
		writeError(w, status, msg)
		return
	}
	createReq := CreateIssueRequest{Title: tmpl.Title, Description: stringPtr(tmpl.Description), Status: tmpl.Status, Priority: tmpl.Priority, AssigneeType: textToPtr(tmpl.AssigneeType), AssigneeID: uuidToPtr(tmpl.AssigneeID), ParentIssueID: uuidToPtr(tmpl.ParentIssueID), ProjectID: uuidToPtr(tmpl.ProjectID), Stage: int4ToPtr(tmpl.Stage), AllowDuplicate: req.AllowDuplicate}
	// One template instantiation always creates exactly one ordinary issue.
	// serial/swarm are catalog intent only; existing status+stage scheduling
	// handles parking or same-stage concurrency without a new scheduler.
	h.createIssueFromRequest(w, r, createReq)
}

func stringPtr(value string) *string { return &value }
