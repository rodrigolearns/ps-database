-- =============================================
-- 00000000000021_pr_reviewers.sql
-- PR Activity Domain: Reviewers and Permissions
-- =============================================
-- Reviewer team management and unified permission system

-- =============================================
-- ENUMs
-- =============================================
DO $$ BEGIN
  CREATE TYPE reviewer_status AS ENUM ('joined', 'locked_in', 'removed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON TYPE reviewer_status IS 'Status of reviewer in a team';

DO $$ BEGIN
  CREATE TYPE pr_activity_role AS ENUM (
    'corresponding_author',
    'spectating_author', 
    'reviewer',
    'reader',
    'spectating_admin'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON TYPE pr_activity_role IS 'Unified roles for PR activity permissions';

-- =============================================
-- 1. PR Reviewers Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_reviewers (
  team_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  status reviewer_status NOT NULL DEFAULT 'joined',
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  commitment_deadline TIMESTAMPTZ,  -- 72 hours from joined_at
  locked_in_at TIMESTAMPTZ,  -- When they submitted initial evaluation
  removed_at TIMESTAMPTZ,
  removal_reason TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, user_id)
);

COMMENT ON TABLE pr_reviewers IS 'Reviewer team members for PR activities';
COMMENT ON COLUMN pr_reviewers.team_id IS 'Primary key';
COMMENT ON COLUMN pr_reviewers.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_reviewers.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN pr_reviewers.status IS 'Reviewer status (joined → locked_in after initial review)';
COMMENT ON COLUMN pr_reviewers.joined_at IS 'When reviewer joined';
COMMENT ON COLUMN pr_reviewers.commitment_deadline IS '72-hour deadline for initial evaluation';
COMMENT ON COLUMN pr_reviewers.locked_in_at IS 'When reviewer submitted initial evaluation';
COMMENT ON COLUMN pr_reviewers.removed_at IS 'When reviewer was removed';
COMMENT ON COLUMN pr_reviewers.removal_reason IS 'Reason for removal (timeout, etc.)';

-- =============================================
-- 2. PR Activity Permissions Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_activity_permissions (
  permission_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  role pr_activity_role NOT NULL,
  granted_at TIMESTAMPTZ DEFAULT NOW(),
  granted_by INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  UNIQUE(activity_id, user_id)
);

COMMENT ON TABLE pr_activity_permissions IS 'Unified permission system for PR activities';
COMMENT ON COLUMN pr_activity_permissions.permission_id IS 'Primary key';
COMMENT ON COLUMN pr_activity_permissions.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_activity_permissions.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN pr_activity_permissions.role IS 'User role in this activity';
COMMENT ON COLUMN pr_activity_permissions.granted_at IS 'When permission was granted';
COMMENT ON COLUMN pr_activity_permissions.granted_by IS 'Who granted this permission';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_pr_reviewers_activity ON pr_reviewers (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewers_user ON pr_reviewers (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewers_status ON pr_reviewers (status);
CREATE INDEX IF NOT EXISTS idx_pr_reviewers_commitment_deadline ON pr_reviewers (commitment_deadline) WHERE commitment_deadline IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pr_reviewers_activity_status ON pr_reviewers (activity_id, status) WHERE status IN ('joined', 'locked_in');

-- Covering index for reviewer lookups
CREATE INDEX IF NOT EXISTS idx_pr_reviewers_activity_user_covering
ON pr_reviewers (activity_id, user_id)
INCLUDE (status, joined_at, locked_in_at, team_id, commitment_deadline, removed_at, removal_reason);

CREATE INDEX IF NOT EXISTS idx_pr_activity_permissions_activity ON pr_activity_permissions (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_activity_permissions_user ON pr_activity_permissions (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_activity_permissions_role ON pr_activity_permissions (role);

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_pr_reviewers_updated_at
  BEFORE UPDATE ON pr_reviewers
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================

-- PR Reviewers: Reviewers see own memberships, activity participants see all
ALTER TABLE pr_reviewers ENABLE ROW LEVEL SECURITY;

CREATE POLICY pr_reviewers_select_own_or_participant ON pr_reviewers
  FOR SELECT
  USING (
    user_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_reviewers.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify (via API routes)
CREATE POLICY pr_reviewers_modify_service_role_only ON pr_reviewers
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- PR Activity Permissions: Users can see their own permissions
ALTER TABLE pr_activity_permissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY pr_activity_permissions_select_own ON pr_activity_permissions
  FOR SELECT
  USING (
    -- Users can only see their own permission entries
    user_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify permissions
CREATE POLICY pr_activity_permissions_modify_service_role_only ON pr_activity_permissions
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- =============================================
-- Extend PR Activities RLS Policy
-- =============================================
-- Now that pr_activity_permissions exists, extend pr_activities SELECT policy

DROP POLICY IF EXISTS pr_activities_select_creator_or_service ON pr_activities;

CREATE POLICY pr_activities_select_participant_or_service ON pr_activities
  FOR SELECT
  USING (
    creator_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_activities.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

COMMENT ON POLICY pr_activities_select_participant_or_service ON pr_activities IS
  'Users see activities they created or participate in';

-- =============================================
-- Extend Papers RLS Policy  
-- =============================================
-- Now that pr_activity_permissions exists, add activity participant access

DROP POLICY IF EXISTS papers_select_own_or_contributor_or_service ON papers;

CREATE POLICY papers_select_own_or_contributor_or_participant_or_service ON papers
  FOR SELECT
  USING (
    uploaded_by = (SELECT auth_user_id()) OR
    (SELECT is_paper_contributor(paper_id)) OR
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      JOIN pr_activities pa ON pa.activity_id = pap.activity_id
      WHERE pa.paper_id = papers.paper_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- =============================================
-- Extend File Storage RLS Policy
-- =============================================
-- Add activity participant access to file_storage

DROP POLICY IF EXISTS file_storage_select_own_or_public_or_service ON file_storage;

CREATE POLICY file_storage_select_own_or_public_or_participant_or_service ON file_storage
  FOR SELECT
  USING (
    uploaded_by = (SELECT auth_user_id()) OR
    is_public = true OR
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = file_storage.related_activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- =============================================
-- Extend Activity Stage State RLS Policy
-- =============================================
-- Add participant access to stage state

DROP POLICY IF EXISTS activity_stage_state_select_service_role ON activity_stage_state;

CREATE POLICY activity_stage_state_select_participant_or_service ON activity_stage_state
  FOR SELECT
  USING (
    (activity_type = 'pr-activity' AND EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = activity_stage_state.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    )) OR
    (SELECT auth.role()) = 'service_role'
  );

COMMENT ON POLICY activity_stage_state_select_participant_or_service ON activity_stage_state IS
  'Participants can see stage state for their activities (extended for JC in migration 41)';

