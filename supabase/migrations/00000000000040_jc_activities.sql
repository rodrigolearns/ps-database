-- =============================================
-- 00000000000040_jc_activities.sql
-- JC Activity Domain: Activities, Templates, and Invitations
-- =============================================
-- Free journal club activities with manual progression (no tokens, no deadlines)

-- =============================================
-- 1. JC Templates Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_templates (
  template_id SERIAL PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,  -- Internal identifier: jc_standard_v1
  user_facing_name TEXT NOT NULL,  -- Display name: "Standard Journal Club"
  description TEXT,
  
  -- Configuration (no participant count limit by default)
  max_participants INTEGER DEFAULT 999,  -- Optional limit (999 = unlimited)
  
  -- Template metadata
  is_active BOOLEAN DEFAULT true,
  is_public BOOLEAN DEFAULT true,
  display_order INTEGER DEFAULT 0,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE jc_templates IS 'Templates for JC activities (workflow graphs defined in template_stage_graph)';
COMMENT ON COLUMN jc_templates.template_id IS 'Primary key for the template';
COMMENT ON COLUMN jc_templates.name IS 'Internal template identifier (format: jc_{description}_v{N})';
COMMENT ON COLUMN jc_templates.user_facing_name IS 'Display name shown to users (e.g., "Standard Journal Club")';
COMMENT ON COLUMN jc_templates.description IS 'User-facing description of the template';
COMMENT ON COLUMN jc_templates.max_participants IS 'Maximum participants allowed (999 = unlimited)';
COMMENT ON COLUMN jc_templates.is_active IS 'Whether template is active';
COMMENT ON COLUMN jc_templates.is_public IS 'Whether users can select this template';
COMMENT ON COLUMN jc_templates.display_order IS 'Order in template selection UI';

-- =============================================
-- 2. JC Activities Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_activities (
  activity_id SERIAL PRIMARY KEY,
  activity_uuid UUID NOT NULL DEFAULT gen_random_uuid(),
  
  -- Paper and ownership
  paper_id INTEGER NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  creator_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  
  -- Template configuration
  template_id INTEGER NOT NULL REFERENCES jc_templates(template_id) ON DELETE RESTRICT,
  
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
COMMENT ON COLUMN jc_activities.template_id IS 'Template defining the workflow graph';
COMMENT ON COLUMN jc_activities.created_at IS 'When journal club was created';
COMMENT ON COLUMN jc_activities.completed_at IS 'When journal club completed';

-- =============================================
-- 3. JC Invitations Table
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
CREATE INDEX IF NOT EXISTS idx_jc_templates_name ON jc_templates (name);
CREATE INDEX IF NOT EXISTS idx_jc_templates_active_public ON jc_templates (is_active, is_public, display_order) WHERE is_active = true AND is_public = true;

CREATE INDEX IF NOT EXISTS idx_jc_activities_paper ON jc_activities (paper_id);
CREATE INDEX IF NOT EXISTS idx_jc_activities_creator ON jc_activities (creator_id);
CREATE INDEX IF NOT EXISTS idx_jc_activities_template ON jc_activities (template_id);
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
CREATE TRIGGER update_jc_templates_updated_at
  BEFORE UPDATE ON jc_templates
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_jc_activities_updated_at
  BEFORE UPDATE ON jc_activities
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================

-- JC Templates: Read-only for authenticated users
ALTER TABLE jc_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY jc_templates_select_authenticated ON jc_templates
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY jc_templates_modify_service_role_only ON jc_templates
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

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

-- =============================================
-- Helper Functions
-- =============================================

-- Function: Create JC activity with initial stage setup
CREATE OR REPLACE FUNCTION create_jc_activity(
  p_paper_id INTEGER,
  p_creator_id INTEGER,
  p_template_id INTEGER
) RETURNS JSONB AS $$
DECLARE
  v_activity_id INTEGER;
  v_activity_uuid UUID;
  v_initial_stage_key TEXT;
  v_timeline_event_id INTEGER;
BEGIN
  -- 1. Get initial stage key from template
  SELECT stage_key INTO v_initial_stage_key
  FROM template_stage_graph
  WHERE template_id = p_template_id
    AND activity_type = 'jc-activity'
    AND is_initial_stage = true
  LIMIT 1;
  
  IF v_initial_stage_key IS NULL THEN
    RAISE EXCEPTION 'Template % has no initial stage defined for jc-activity', p_template_id;
  END IF;
  
  -- 2. Insert activity
  INSERT INTO jc_activities (
    paper_id,
    creator_id,
    template_id,
    created_at
  )
  VALUES (
    p_paper_id,
    p_creator_id,
    p_template_id,
    NOW()
  )
  RETURNING activity_id, activity_uuid INTO v_activity_id, v_activity_uuid;
  
  -- 3. Initialize stage state (jc_created stage has no deadline)
  INSERT INTO activity_stage_state (
    activity_type,
    activity_id,
    current_stage_key,
    stage_entered_at,
    stage_deadline
  )
  VALUES (
    'jc-activity',
    v_activity_id,
    v_initial_stage_key,
    NOW(),
    NULL  -- JC activities have no deadlines
  );
  
  -- 4. Add creator as participant (CRITICAL: required for get_user_jc_activities)
  INSERT INTO jc_participants (
    activity_id,
    user_id,
    is_creator,
    invited_at,
    joined_at
  )
  VALUES (
    v_activity_id,
    p_creator_id,
    true,
    NOW(),
    NOW()
  )
  ON CONFLICT (activity_id, user_id) DO NOTHING;  -- Handle duplicate gracefully
  
  -- 5. Create permission for creator (CRITICAL: required for RLS access)
  INSERT INTO jc_activity_permissions (
    activity_id,
    user_id,
    role,
    granted_at
  )
  VALUES (
    v_activity_id,
    p_creator_id,
    'creator',
    NOW()
  )
  ON CONFLICT (activity_id, user_id) DO NOTHING;  -- Handle duplicate gracefully
  
  -- 6. Create initial timeline event
  INSERT INTO jc_timeline_events (
    activity_id,
    event_type,
    stage_key,
    user_id,
    title,
    description
  )
  VALUES (
    v_activity_id,
    'activity_created',
    v_initial_stage_key,
    p_creator_id,
    'Journal Club Created',
    'Journal club activity created, sending invitations'
  )
  RETURNING event_id INTO v_timeline_event_id;
  
  -- 7. Return result
  RETURN jsonb_build_object(
    'activity_id', v_activity_id,
    'activity_uuid', v_activity_uuid,
    'initial_stage_key', v_initial_stage_key,
    'timeline_event_id', v_timeline_event_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION create_jc_activity IS 'Atomically creates JC activity with initial stage state, creator permission, and timeline event';

-- Grant permissions
GRANT EXECUTE ON FUNCTION create_jc_activity TO authenticated;

