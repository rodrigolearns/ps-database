-- =============================================
-- 00000000000040_jc_activities.sql
-- JC Activity Domain: Activities and Invitations
-- =============================================
-- Free journal club activities with manual progression (no tokens, no deadlines)

-- =============================================
-- 1. JC Activities Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_activities (
  activity_id SERIAL PRIMARY KEY,
  activity_uuid UUID NOT NULL DEFAULT gen_random_uuid(),
  
  -- Paper and ownership
  paper_id INTEGER NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  creator_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  
  -- Configuration (no template system for JC - simpler)
  max_reviewers INTEGER DEFAULT 999,  -- Optional limit (999 = unlimited)
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE jc_activities IS 'Free journal club activities with manual progression (no deadlines, invitation-only)';
COMMENT ON COLUMN jc_activities.activity_id IS 'Primary key';
COMMENT ON COLUMN jc_activities.activity_uuid IS 'UUID for cross-system references';
COMMENT ON COLUMN jc_activities.paper_id IS 'Foreign key to papers';
COMMENT ON COLUMN jc_activities.creator_id IS 'User who created the journal club';
COMMENT ON COLUMN jc_activities.max_reviewers IS 'Optional limit on participants (999 = unlimited)';
COMMENT ON COLUMN jc_activities.created_at IS 'When journal club was created';
COMMENT ON COLUMN jc_activities.completed_at IS 'When journal club completed';

-- =============================================
-- 2. JC Invitations Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_invitations (
  invitation_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES jc_activities(activity_id) ON DELETE CASCADE,
  inviter_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  invitee_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'declined', 'expired')) DEFAULT 'pending',
  invited_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  responded_at TIMESTAMPTZ,
  
  UNIQUE(activity_id, invitee_id)
);

COMMENT ON TABLE jc_invitations IS 'Invitation tracking for journal club activities';
COMMENT ON COLUMN jc_invitations.invitation_id IS 'Primary key';
COMMENT ON COLUMN jc_invitations.activity_id IS 'Foreign key to jc_activities';
COMMENT ON COLUMN jc_invitations.inviter_id IS 'User who sent the invitation (creator)';
COMMENT ON COLUMN jc_invitations.invitee_id IS 'User who was invited';
COMMENT ON COLUMN jc_invitations.status IS 'Invitation status (pending, accepted, declined, expired)';
COMMENT ON COLUMN jc_invitations.invited_at IS 'When invitation was sent';
COMMENT ON COLUMN jc_invitations.responded_at IS 'When invitee responded';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_jc_activities_paper ON jc_activities (paper_id);
CREATE INDEX IF NOT EXISTS idx_jc_activities_creator ON jc_activities (creator_id);
CREATE INDEX IF NOT EXISTS idx_jc_activities_created ON jc_activities (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_jc_activities_uuid ON jc_activities (activity_uuid);
CREATE INDEX IF NOT EXISTS idx_jc_activities_active ON jc_activities (activity_id, created_at DESC) WHERE completed_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_jc_invitations_activity ON jc_invitations (activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_invitations_invitee ON jc_invitations (invitee_id);
CREATE INDEX IF NOT EXISTS idx_jc_invitations_status ON jc_invitations (status);
CREATE INDEX IF NOT EXISTS idx_jc_invitations_invitee_pending ON jc_invitations (invitee_id, status) WHERE status = 'pending';

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_jc_activities_updated_at
  BEFORE UPDATE ON jc_activities
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================

-- JC Activities: Creator and participants can see
ALTER TABLE jc_activities ENABLE ROW LEVEL SECURITY;

CREATE POLICY jc_activities_select_creator_or_participant_or_service ON jc_activities
  FOR SELECT
  USING (
    creator_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify (via API routes)
CREATE POLICY jc_activities_modify_service_role_only ON jc_activities
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- JC Invitations: Inviter and invitee can see
ALTER TABLE jc_invitations ENABLE ROW LEVEL SECURITY;

CREATE POLICY jc_invitations_select_own ON jc_invitations
  FOR SELECT
  USING (
    inviter_id = (SELECT auth_user_id()) OR
    invitee_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify (via API routes)
CREATE POLICY jc_invitations_modify_service_role_only ON jc_invitations
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY jc_activities_select_creator_or_participant_or_service ON jc_activities IS
  'Creator and participants can see (participant access extended in migration 41)';

