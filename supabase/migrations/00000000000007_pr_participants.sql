-- =============================================
-- 00000000000007_pr_participants.sql
-- Peer Review Domain: Reviewers and Teams (Simplified)
-- =============================================

-- Create ENUMs for reviewer system
DO $$ BEGIN
  CREATE TYPE reviewer_status AS ENUM ('joined', 'locked_in', 'removed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE reviewer_status IS 'Status of reviewer in a team (simplified)';

-- Reviewer team members table
CREATE TABLE IF NOT EXISTS pr_reviewer_teams (
  team_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  status reviewer_status NOT NULL DEFAULT 'joined',
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  commitment_deadline TIMESTAMPTZ, -- 72 hours from joined_at
  locked_in_at TIMESTAMPTZ, -- When they submitted initial evaluation
  removed_at TIMESTAMPTZ,
  removal_reason TEXT, -- Why they were removed (timeout, etc.)
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, user_id)
);

COMMENT ON TABLE pr_reviewer_teams IS 'Reviewer team members for peer review activities';
COMMENT ON COLUMN pr_reviewer_teams.team_id IS 'Primary key for the team membership';
COMMENT ON COLUMN pr_reviewer_teams.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_reviewer_teams.user_id IS 'Foreign key to user_accounts (reviewer)';
COMMENT ON COLUMN pr_reviewer_teams.status IS 'Current status of the reviewer';
COMMENT ON COLUMN pr_reviewer_teams.joined_at IS 'When the reviewer joined the team';
COMMENT ON COLUMN pr_reviewer_teams.commitment_deadline IS '72 hours from join time for initial evaluation';
COMMENT ON COLUMN pr_reviewer_teams.locked_in_at IS 'When reviewer submitted initial evaluation and locked in';
COMMENT ON COLUMN pr_reviewer_teams.removed_at IS 'When the reviewer was removed';
COMMENT ON COLUMN pr_reviewer_teams.removal_reason IS 'Reason for removal (timeout, manual, etc.)';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_activity_id ON pr_reviewer_teams (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_user_id ON pr_reviewer_teams (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_status ON pr_reviewer_teams (status);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_commitment_deadline ON pr_reviewer_teams (commitment_deadline);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_joined_at ON pr_reviewer_teams (joined_at);

-- Simple trigger to set commitment deadline
CREATE OR REPLACE FUNCTION set_commitment_deadline()
RETURNS TRIGGER AS $$
BEGIN
  -- Set 72-hour deadline when joining
  IF NEW.status = 'joined' AND OLD.status IS DISTINCT FROM 'joined' THEN
    NEW.commitment_deadline = NEW.joined_at + INTERVAL '72 hours';
  END IF;
  
  -- Clear deadline when locked in
  IF NEW.status = 'locked_in' THEN
    NEW.locked_in_at = COALESCE(NEW.locked_in_at, NOW());
    NEW.commitment_deadline = NULL;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_reviewer_commitment_deadline
  BEFORE INSERT OR UPDATE ON pr_reviewer_teams
  FOR EACH ROW
  EXECUTE FUNCTION set_commitment_deadline();

-- Basic triggers
CREATE TRIGGER update_pr_reviewer_teams_updated_at
  BEFORE UPDATE ON pr_reviewer_teams
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at(); 