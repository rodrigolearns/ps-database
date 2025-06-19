-- =============================================
-- 00000000000009_pr_evaluation.sql
-- Peer Review Domain: Collaborative Evaluations
-- =============================================

-- Collaborative evaluations table
CREATE TABLE IF NOT EXISTS pr_evaluations (
  evaluation_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  content JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id)
);

COMMENT ON TABLE pr_evaluations IS 'Collaborative evaluations for peer review activities';
COMMENT ON COLUMN pr_evaluations.evaluation_id IS 'Primary key for the evaluation';
COMMENT ON COLUMN pr_evaluations.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_evaluations.content IS 'JSONB content of the collaborative evaluation';
COMMENT ON COLUMN pr_evaluations.created_at IS 'When the evaluation was created';
COMMENT ON COLUMN pr_evaluations.updated_at IS 'When the evaluation was last updated';

-- Evaluation versions table (for tracking changes)
CREATE TABLE IF NOT EXISTS pr_evaluation_versions (
  version_id SERIAL PRIMARY KEY,
  evaluation_id INTEGER NOT NULL REFERENCES pr_evaluations(evaluation_id) ON DELETE CASCADE,
  version_number INTEGER NOT NULL,
  content JSONB NOT NULL,
  created_by INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(evaluation_id, version_number)
);

COMMENT ON TABLE pr_evaluation_versions IS 'Version history of collaborative evaluations';
COMMENT ON COLUMN pr_evaluation_versions.version_id IS 'Primary key for the version';
COMMENT ON COLUMN pr_evaluation_versions.evaluation_id IS 'Foreign key to pr_evaluations';
COMMENT ON COLUMN pr_evaluation_versions.version_number IS 'Version number';
COMMENT ON COLUMN pr_evaluation_versions.content IS 'JSONB content of this version';
COMMENT ON COLUMN pr_evaluation_versions.created_by IS 'User who created this version';
COMMENT ON COLUMN pr_evaluation_versions.created_at IS 'When this version was created';

-- Evaluation editing sessions table
CREATE TABLE IF NOT EXISTS pr_evaluation_sessions (
  session_id SERIAL PRIMARY KEY,
  evaluation_id INTEGER NOT NULL REFERENCES pr_evaluations(evaluation_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  session_token TEXT NOT NULL,
  started_at TIMESTAMPTZ DEFAULT NOW(),
  last_activity TIMESTAMPTZ DEFAULT NOW(),
  ended_at TIMESTAMPTZ
);

COMMENT ON TABLE pr_evaluation_sessions IS 'Active editing sessions for collaborative evaluations';
COMMENT ON COLUMN pr_evaluation_sessions.session_id IS 'Primary key for the session';
COMMENT ON COLUMN pr_evaluation_sessions.evaluation_id IS 'Foreign key to pr_evaluations';
COMMENT ON COLUMN pr_evaluation_sessions.user_id IS 'Foreign key to user_accounts (editor)';
COMMENT ON COLUMN pr_evaluation_sessions.session_token IS 'Unique session token';
COMMENT ON COLUMN pr_evaluation_sessions.started_at IS 'When the session started';
COMMENT ON COLUMN pr_evaluation_sessions.last_activity IS 'Last activity in the session';
COMMENT ON COLUMN pr_evaluation_sessions.ended_at IS 'When the session ended';

-- Evaluation comments table
CREATE TABLE IF NOT EXISTS pr_evaluation_comments (
  comment_id SERIAL PRIMARY KEY,
  evaluation_id INTEGER NOT NULL REFERENCES pr_evaluations(evaluation_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  comment_text TEXT NOT NULL,
  parent_comment_id INTEGER REFERENCES pr_evaluation_comments(comment_id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE pr_evaluation_comments IS 'Comments on collaborative evaluations';
COMMENT ON COLUMN pr_evaluation_comments.comment_id IS 'Primary key for the comment';
COMMENT ON COLUMN pr_evaluation_comments.evaluation_id IS 'Foreign key to pr_evaluations';
COMMENT ON COLUMN pr_evaluation_comments.user_id IS 'Foreign key to user_accounts (commenter)';
COMMENT ON COLUMN pr_evaluation_comments.comment_text IS 'Text of the comment';
COMMENT ON COLUMN pr_evaluation_comments.parent_comment_id IS 'Parent comment for threaded discussions';
COMMENT ON COLUMN pr_evaluation_comments.created_at IS 'When the comment was created';
COMMENT ON COLUMN pr_evaluation_comments.updated_at IS 'When the comment was last updated';

-- Reviewer finalization status table
CREATE TABLE IF NOT EXISTS pr_finalization_status (
  status_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  is_finalized BOOLEAN DEFAULT false,
  finalized_at TIMESTAMPTZ,
  UNIQUE(activity_id, reviewer_id)
);

COMMENT ON TABLE pr_finalization_status IS 'Finalization status of reviewers for evaluations';
COMMENT ON COLUMN pr_finalization_status.status_id IS 'Primary key for the status';
COMMENT ON COLUMN pr_finalization_status.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_finalization_status.reviewer_id IS 'Foreign key to user_accounts (reviewer)';
COMMENT ON COLUMN pr_finalization_status.is_finalized IS 'Whether the reviewer has finalized';
COMMENT ON COLUMN pr_finalization_status.finalized_at IS 'When the reviewer finalized';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_evaluations_activity_id ON pr_evaluations (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_evaluations_updated_at ON pr_evaluations (updated_at);

CREATE INDEX IF NOT EXISTS idx_pr_evaluation_versions_evaluation_id ON pr_evaluation_versions (evaluation_id);
CREATE INDEX IF NOT EXISTS idx_pr_evaluation_versions_created_by ON pr_evaluation_versions (created_by);
CREATE INDEX IF NOT EXISTS idx_pr_evaluation_versions_created_at ON pr_evaluation_versions (created_at);

CREATE INDEX IF NOT EXISTS idx_pr_evaluation_sessions_evaluation_id ON pr_evaluation_sessions (evaluation_id);
CREATE INDEX IF NOT EXISTS idx_pr_evaluation_sessions_user_id ON pr_evaluation_sessions (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_evaluation_sessions_last_activity ON pr_evaluation_sessions (last_activity);

CREATE INDEX IF NOT EXISTS idx_pr_evaluation_comments_evaluation_id ON pr_evaluation_comments (evaluation_id);
CREATE INDEX IF NOT EXISTS idx_pr_evaluation_comments_user_id ON pr_evaluation_comments (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_evaluation_comments_parent ON pr_evaluation_comments (parent_comment_id);
CREATE INDEX IF NOT EXISTS idx_pr_evaluation_comments_created_at ON pr_evaluation_comments (created_at);

CREATE INDEX IF NOT EXISTS idx_pr_finalization_status_activity_id ON pr_finalization_status (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_finalization_status_reviewer_id ON pr_finalization_status (reviewer_id);

-- Triggers
CREATE TRIGGER update_pr_evaluations_updated_at
  BEFORE UPDATE ON pr_evaluations
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_pr_evaluation_comments_updated_at
  BEFORE UPDATE ON pr_evaluation_comments
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at(); 