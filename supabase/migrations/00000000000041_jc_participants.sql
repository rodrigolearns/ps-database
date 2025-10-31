-- =============================================
-- 00000000000041_jc_participants.sql
-- JC Activity Domain: Participants and Permissions
-- =============================================
-- Invitation-based participant system (no deadlines, no lock-in, creator can participate)

-- =============================================
-- ENUMs
-- =============================================
DO $$ BEGIN
  CREATE TYPE jc_activity_role AS ENUM (
    'creator',
    'participant',
    'reader'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON TYPE jc_activity_role IS 'Roles for JC activity permissions (simpler than PR)';

-- =============================================
-- 1. JC Participants Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_participants (
  participant_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES jc_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  
  -- Participant type
  is_creator BOOLEAN NOT NULL DEFAULT false,  -- True if this is the activity creator participating
  
  -- Invitation tracking (NULL if creator self-added)
  invited_at TIMESTAMPTZ,
  invited_by INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(activity_id, user_id)
);

COMMENT ON TABLE jc_participants IS 'Participants for JC activities (invitation-based, creator can participate, no lock-in mechanism)';
COMMENT ON COLUMN jc_participants.participant_id IS 'Primary key';
COMMENT ON COLUMN jc_participants.activity_id IS 'Foreign key to jc_activities';
COMMENT ON COLUMN jc_participants.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN jc_participants.is_creator IS 'True if this participant is the activity creator (can progress stages)';
COMMENT ON COLUMN jc_participants.invited_at IS 'When user was invited (NULL if creator self-added)';
COMMENT ON COLUMN jc_participants.invited_by IS 'Who invited this user (NULL if creator)';
COMMENT ON COLUMN jc_participants.joined_at IS 'When user joined/accepted invitation';

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
CREATE INDEX IF NOT EXISTS idx_jc_participants_activity ON jc_participants (activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_participants_user ON jc_participants (user_id);
CREATE INDEX IF NOT EXISTS idx_jc_participants_creator ON jc_participants (activity_id, is_creator) WHERE is_creator = true;
CREATE INDEX IF NOT EXISTS idx_jc_participants_joined ON jc_participants (joined_at DESC);

CREATE INDEX IF NOT EXISTS idx_jc_activity_permissions_activity ON jc_activity_permissions (activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_activity_permissions_user ON jc_activity_permissions (user_id);
CREATE INDEX IF NOT EXISTS idx_jc_activity_permissions_role ON jc_activity_permissions (role);

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_jc_participants_updated_at
  BEFORE UPDATE ON jc_participants
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Helper Functions (to avoid RLS recursion)
-- =============================================

-- Helper function to check if user is participant in activity (bypasses RLS)
CREATE OR REPLACE FUNCTION user_is_jc_participant(p_activity_id INTEGER, p_user_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM jc_participants
    WHERE activity_id = p_activity_id
    AND user_id = p_user_id
  );
END;
$$;

COMMENT ON FUNCTION user_is_jc_participant IS 'SECURITY DEFINER function to check participant status without RLS recursion';

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE jc_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE jc_activity_permissions ENABLE ROW LEVEL SECURITY;

-- Participants: Users can see all participants in activities they are part of
-- Uses helper function to avoid recursion
CREATE POLICY jc_participants_select_all_in_activity ON jc_participants
  FOR SELECT
  USING (
    -- Can see all participants in activities where you are a participant
    user_is_jc_participant(jc_participants.activity_id, (SELECT auth_user_id())) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY jc_participants_modify_service_role_only ON jc_participants
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Permissions: Users can see their own permissions
CREATE POLICY jc_activity_permissions_select_own ON jc_activity_permissions
  FOR SELECT
  USING (
    -- Users can only see their own permission entries
    user_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY jc_activity_permissions_modify_service_role_only ON jc_activity_permissions
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- =============================================
-- Extend JC Activities RLS Policy
-- =============================================
-- Now that jc_participants exists, extend jc_activities SELECT policy

DROP POLICY IF EXISTS jc_activities_select_creator_or_participant_or_service ON jc_activities;

CREATE POLICY jc_activities_select_participant_or_service ON jc_activities
  FOR SELECT
  USING (
    creator_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM jc_participants jp
      WHERE jp.activity_id = jc_activities.activity_id
      AND jp.user_id = (SELECT auth_user_id())
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
      SELECT 1 FROM jc_participants jp
      WHERE jp.activity_id = activity_stage_state.activity_id
      AND jp.user_id = (SELECT auth_user_id())
    )) OR
    (SELECT auth.role()) = 'service_role'
  );

-- =============================================
-- Extend Papers RLS Policy for JC
-- =============================================
-- Add JC participant access to papers

DROP POLICY IF EXISTS papers_select_own_or_contributor_or_participant_or_service ON papers;

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
    EXISTS (
      SELECT 1 FROM jc_participants jp
      JOIN jc_activities ja ON ja.activity_id = jp.activity_id
      WHERE ja.paper_id = papers.paper_id
      AND jp.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- =============================================
-- Extend File Storage RLS Policy for JC
-- =============================================
-- Add JC participant access to file_storage

DROP POLICY IF EXISTS file_storage_select_own_or_public_or_participant_or_service ON file_storage;

CREATE POLICY file_storage_select_own_or_public_or_participant_or_service ON file_storage
  FOR SELECT
  USING (
    uploaded_by = (SELECT auth_user_id()) OR
    is_public = true OR
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      JOIN pr_activities pa ON pa.activity_id = pap.activity_id
      WHERE pa.paper_id = file_storage.related_paper_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    EXISTS (
      SELECT 1 FROM jc_participants jp
      JOIN jc_activities ja ON ja.activity_id = jp.activity_id
      WHERE ja.paper_id = file_storage.related_paper_id
      AND jp.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

