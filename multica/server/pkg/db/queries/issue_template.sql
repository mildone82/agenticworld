-- name: ListIssueTemplates :many
SELECT * FROM issue_template
WHERE workspace_id = $1
ORDER BY updated_at DESC, lower(name) ASC;

-- name: GetIssueTemplate :one
SELECT * FROM issue_template
WHERE id = $1 AND workspace_id = $2;

-- name: CreateIssueTemplate :one
INSERT INTO issue_template (
    workspace_id, name, title, description, priority, status,
    project_id, assignee_type, assignee_id, parent_issue_id, stage,
    work_mode, created_by_id
) VALUES (
    $1, $2, $3, $4, $5, $6,
    $7, $8, $9, $10, $11,
    $12, $13
) RETURNING *;

-- name: ReplaceIssueTemplate :one
UPDATE issue_template SET
    name = $3,
    title = $4,
    description = $5,
    priority = $6,
    status = $7,
    project_id = $8,
    assignee_type = $9,
    assignee_id = $10,
    parent_issue_id = $11,
    stage = $12,
    work_mode = $13,
    updated_at = now()
WHERE id = $1 AND workspace_id = $2
RETURNING *;

-- name: DeleteIssueTemplate :exec
DELETE FROM issue_template
WHERE id = $1 AND workspace_id = $2;
