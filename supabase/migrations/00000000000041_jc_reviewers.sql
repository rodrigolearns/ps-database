-- =============================================
-- 00000000000041_jc_reviewers.sql
-- JC Activity Domain: Reviewers and Permissions
-- =============================================
-- Invitation-based reviewer system (no deadlines, no commitment tracking)

-- =============================================
-- ENUMs
-- =============================================
DO $$ BEGIN
  CREATE TYPE jc_activity_role AS ENUM (
    'creator',
    'reviewer',
    'reader'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON TYPE jc_activity_role IS 'Roles for JC activity permissions (simpler than PR)';

-- =============================================
-- 1. JC Reviewers Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_reviewers (
  reviewer_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES jc_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  
  -- Invitation tracking
  invited_at TIMESTAMPTZ,
  invited_by INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(activity_id, user_id)
);

COMMENT ON TABLE jc_reviewers IS 'Reviewer participants for JC activities (invitation-based, no deadlines)';
COMMENT ON COLUMN jc_reviewers.reviewer_id IS 'Primary key';
COMMENT ON COLUMN jc_reviewers.activity_id IS 'Foreign key to jc_activities';
COMMENT ON COLUMN jc_reviewers.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN jc_reviewers.invited_at IS 'When user was invited';
COMMENT ON COLUMN jc_reviewers.invited_by IS 'Who invited this user';
COMMENT ON COLUMN jc_reviewers.joined_at IS 'When user accepted invitation';

-- =============================================
-- 2. JC Activity Permissions Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_activity_permissions (
  permission_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES jc_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  role jc_activity_role NOT NULL,
  granted_at TIMESTAMPTZ DEFAULT NOW(),
  granted_by INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  
  UNIQUE(activity_id, user_id)
);

COMMENT ON TABLE jc_activity_permissions IS 'Permission system for JC activities';
COMMENT ON COLUMN jc_activity_permissions.permission_id IS 'Primary key';
COMMENT ON COLUMN jc_activity_permissions.activity_id IS 'Foreign key to jc_activities';
COMMENT ON COLUMN jc_activity_permissions.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN jc_activity_permissions.role IS 'User role in this JC activity';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_jc_reviewers_activity ON jc_reviewers (activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_reviewers_user ON jc_reviewers (user_id);
CREATE INDEX IF NOT EXISTS idx_jc_reviewers_joined ON jc_reviewers (joined_at DESC);

CREATE INDEX IF NOT EXISTS idx_jc_activity_permissions_activity ON jc_activity_permissions (activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_activity_permissions_user ON jc_activity_permissions (user_id);
CREATE INDEX IF NOT EXISTS idx_jc_activity_permissions_role ON jc_activity_permissions (role);

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_jc_reviewers_updated_at
  BEFORE UPDATE ON jc_reviewers
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE jc_reviewers ENABLE ROW LEVEL SECURITY;
ALTER TABLE jc_activity_permissions ENABLE ROW LEVEL SECURITY;

-- Reviewers: Own memberships + activity participants see all
CREATE POLICY jc_reviewers_select_own_or_participant ON jc_reviewers
  FOR SELECT
  USING (
    user_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM jc_activity_permissions jap
      WHERE jap.activity_id = jc_reviewers.activity_id
      AND jap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY jc_reviewers_modify_service_role_only ON jc_reviewers
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Permissions: Participants can see permissions for their activities
CREATE POLICY jc_activity_permissions_select_participant ON jc_activity_permissions
  FOR SELECT
  USING (
    user_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM jc_activity_permissions jap
      WHERE jap.activity_id = jc_activity_permissions.activity_id
      AND jap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY jc_activity_permissions_modify_service_role_only ON jc_activity_permissions
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- =============================================
-- Extend JC Activities RLS Policy
-- =============================================
-- Now that jc_activity_permissions exists, extend jc_activities SELECT policy

DROP POLICY IF EXISTS jc_activities_select_creator_or_participant_or_service ON jc_activities;

CREATE POLICY jc_activities_select_participant_or_service ON jc_activities
  FOR SELECT
  USING (
    creator_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM jc_activity_permissions jap
      WHERE jap.activity_id = jc_activities.activity_id
      AND jap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- =============================================
-- Extend Activity Stage State RLS Policy for JC
-- =============================================
-- Add JC participant access to stage state

DROP POLICY IF EXISTS activity_stage_state_select_participant_or_service ON activity_stage_state;

CREATE POLICY activity_stage_state_select_participant_or_service ON activity_stage_state
  FOR SELECT
  USING (
    (activity_type = 'pr-activity' AND EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = activity_stage_state.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    )) OR
    (activity_type = 'jc-activity' AND EXISTS (
      SELECT 1 FROM jc_activity_permissions jap
      WHERE jap.activity_id = activity_stage_state.activity_id
      AND jap.user_id = (SELECT auth_user_id())
    )) OR
    (SELECT auth.role()) = 'service_role'
  );

