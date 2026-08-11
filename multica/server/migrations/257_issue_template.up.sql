CREATE TABLE issue_template (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL,
    name TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT 'none'
        CHECK (priority IN ('urgent', 'high', 'medium', 'low', 'none')),
    status TEXT NOT NULL DEFAULT 'todo'
        CHECK (status IN ('backlog', 'todo', 'in_progress', 'in_review', 'done', 'blocked', 'cancelled')),
    project_id UUID,
    assignee_type TEXT CHECK (assignee_type IS NULL OR assignee_type IN ('member', 'agent', 'squad')),
    assignee_id UUID,
    parent_issue_id UUID,
    stage INTEGER CHECK (stage IS NULL OR stage >= 1),
    work_mode TEXT CHECK (work_mode IS NULL OR work_mode IN ('serial', 'swarm')),
    created_by_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((assignee_type IS NULL) = (assignee_id IS NULL)),
    CHECK (stage IS NULL OR parent_issue_id IS NOT NULL),
    CHECK (work_mode IS NULL OR (assignee_type = 'squad' AND parent_issue_id IS NOT NULL AND stage IS NOT NULL)),
    CHECK (work_mode <> 'serial' OR status IN ('todo', 'backlog')),
    CHECK (work_mode <> 'swarm' OR status = 'todo')
);
