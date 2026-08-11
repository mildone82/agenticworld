CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_issue_template_workspace_updated ON issue_template (workspace_id, updated_at DESC);
