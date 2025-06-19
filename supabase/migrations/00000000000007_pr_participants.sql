-- =============================================
-- 00000000000007_pr_participants.sql
-- Peer Review Domain: Reviewers and Teams
-- =============================================

-- Create ENUMs for reviewer system
DO $$ BEGIN
  CREATE TYPE reviewer_status AS ENUM ('invited', 'joined', 'declined', 'removed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE reviewer_status IS 'Status of reviewer in a team';

DO $$ BEGIN
  CREATE TYPE penalty_type AS ENUM ('late_submission', 'no_submission', 'poor_quality', 'misconduct');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE penalty_type IS 'Types of penalties for reviewers';

-- Reviewer team members table
CREATE TABLE IF NOT EXISTS pr_reviewer_teams (
  team_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  status reviewer_status NOT NULL DEFAULT 'invited',
  invited_at TIMESTAMPTZ DEFAULT NOW(),
  joined_at TIMESTAMPTZ,
  declined_at TIMESTAMPTZ,
  removed_at TIMESTAMPTZ,
  invited_by INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  UNIQUE(activity_id, user_id)
);

COMMENT ON TABLE pr_reviewer_teams IS 'Reviewer team members for peer review activities';
COMMENT ON COLUMN pr_reviewer_teams.team_id IS 'Primary key for the team membership';
COMMENT ON COLUMN pr_reviewer_teams.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_reviewer_teams.user_id IS 'Foreign key to user_accounts (reviewer)';
COMMENT ON COLUMN pr_reviewer_teams.status IS 'Current status of the reviewer';
COMMENT ON COLUMN pr_reviewer_teams.invited_at IS 'When the reviewer was invited';
COMMENT ON COLUMN pr_reviewer_teams.joined_at IS 'When the reviewer joined';
COMMENT ON COLUMN pr_reviewer_teams.declined_at IS 'When the reviewer declined';
COMMENT ON COLUMN pr_reviewer_teams.removed_at IS 'When the reviewer was removed';
COMMENT ON COLUMN pr_reviewer_teams.invited_by IS 'Who invited this reviewer';

-- Reviewer penalties table
CREATE TABLE IF NOT EXISTS pr_reviewer_penalties (
  penalty_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  penalty_type penalty_type NOT NULL,
  amount INTEGER NOT NULL DEFAULT 0,
  description TEXT,
  applied_by INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE pr_reviewer_penalties IS 'Penalties applied to reviewers';
COMMENT ON COLUMN pr_reviewer_penalties.penalty_id IS 'Primary key for the penalty';
COMMENT ON COLUMN pr_reviewer_penalties.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_reviewer_penalties.user_id IS 'Foreign key to user_accounts (penalized reviewer)';
COMMENT ON COLUMN pr_reviewer_penalties.penalty_type IS 'Type of penalty applied';
COMMENT ON COLUMN pr_reviewer_penalties.amount IS 'Token amount of penalty';
COMMENT ON COLUMN pr_reviewer_penalties.description IS 'Description of the penalty';
COMMENT ON COLUMN pr_reviewer_penalties.applied_by IS 'Who applied the penalty';
COMMENT ON COLUMN pr_reviewer_penalties.created_at IS 'When the penalty was applied';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_activity_id ON pr_reviewer_teams (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_user_id ON pr_reviewer_teams (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_status ON pr_reviewer_teams (status);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_joined_at ON pr_reviewer_teams (joined_at);

CREATE INDEX IF NOT EXISTS idx_pr_reviewer_penalties_activity_id ON pr_reviewer_penalties (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_penalties_user_id ON pr_reviewer_penalties (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_penalties_penalty_type ON pr_reviewer_penalties (penalty_type);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_penalties_created_at ON pr_reviewer_penalties (created_at); 