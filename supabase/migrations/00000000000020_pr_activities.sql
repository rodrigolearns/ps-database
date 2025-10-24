-- =============================================
-- 00000000000020_pr_activities.sql
-- PR Activity Domain: Activities and Templates
-- =============================================
-- Token-based peer review activities with automatic progression

-- =============================================
-- 1. PR Templates Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_templates (
  template_id SERIAL PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,  -- Internal identifier: quick_review_1_round_3_reviewers_10_tokens_v1
  user_facing_name TEXT NOT NULL,  -- Display name: "Quick Review"
  description TEXT,
  
  -- Basic configuration
  reviewer_count INTEGER NOT NULL,
  total_tokens INTEGER NOT NULL,
  insurance_tokens INTEGER NOT NULL,  -- Tokens reserved for platform insurance (typically 10%)
  
  -- Template metadata
  is_active BOOLEAN DEFAULT true,
  is_public BOOLEAN DEFAULT true,
  display_order INTEGER DEFAULT 0,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE pr_templates IS 'Templates for PR activities (workflow graphs defined in template_stage_graph)';
COMMENT ON COLUMN pr_templates.template_id IS 'Primary key for the template';
COMMENT ON COLUMN pr_templates.name IS 'Internal template identifier (format: {pace}_review_{X}_rounds_{Y}_reviewers_{Z}_tokens_v{N})';
COMMENT ON COLUMN pr_templates.user_facing_name IS 'Display name shown to users (e.g., "Quick Review", "Thorough Review")';
COMMENT ON COLUMN pr_templates.description IS 'User-facing description of the template';
COMMENT ON COLUMN pr_templates.reviewer_count IS 'Number of reviewers required';
COMMENT ON COLUMN pr_templates.total_tokens IS 'Total tokens for distribution (including insurance)';
COMMENT ON COLUMN pr_templates.insurance_tokens IS 'Tokens reserved for platform insurance/conflict resolution (~10% of total)';
COMMENT ON COLUMN pr_templates.is_active IS 'Whether template is active';
COMMENT ON COLUMN pr_templates.is_public IS 'Whether users can select this template';
COMMENT ON COLUMN pr_templates.display_order IS 'Order in template selection UI';

-- Template token ranks (token distribution by rank)
CREATE TABLE IF NOT EXISTS pr_template_ranks (
  template_id INTEGER NOT NULL REFERENCES pr_templates(template_id) ON DELETE CASCADE,
  rank_position INTEGER NOT NULL,
  tokens INTEGER NOT NULL,
  PRIMARY KEY (template_id, rank_position)
);

COMMENT ON TABLE pr_template_ranks IS 'Token distribution by rank for each template';
COMMENT ON COLUMN pr_template_ranks.template_id IS 'Foreign key to pr_templates';
COMMENT ON COLUMN pr_template_ranks.rank_position IS 'Rank position (1st, 2nd, 3rd, etc.)';
COMMENT ON COLUMN pr_template_ranks.tokens IS 'Tokens awarded for this rank';

-- =============================================
-- 2. PR Activities Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_activities (
  activity_id SERIAL PRIMARY KEY,
  activity_uuid UUID NOT NULL DEFAULT gen_random_uuid(),
  
  -- Paper and ownership
  paper_id INTEGER NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  creator_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  
  -- Template configuration
  template_id INTEGER NOT NULL REFERENCES pr_templates(template_id) ON DELETE RESTRICT,
  
  -- Token economics
  funding_amount INTEGER NOT NULL,
  escrow_balance INTEGER NOT NULL,
  
  -- Timestamps
  posted_at TIMESTAMPTZ DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  CONSTRAINT chk_escrow_nonnegative CHECK (escrow_balance >= 0),
  CONSTRAINT chk_escrow_not_exceed_funding CHECK (escrow_balance <= funding_amount)
);

COMMENT ON TABLE pr_activities IS 'Token-based peer review activities with automatic progression';
COMMENT ON COLUMN pr_activities.activity_id IS 'Primary key for the activity';
COMMENT ON COLUMN pr_activities.activity_uuid IS 'UUID for cross-system references';
COMMENT ON COLUMN pr_activities.paper_id IS 'Foreign key to papers';
COMMENT ON COLUMN pr_activities.creator_id IS 'User who created the activity (corresponding author)';
COMMENT ON COLUMN pr_activities.template_id IS 'Template defining the workflow graph';
COMMENT ON COLUMN pr_activities.funding_amount IS 'Total tokens allocated for this activity';
COMMENT ON COLUMN pr_activities.escrow_balance IS 'Remaining tokens in escrow (decreases as awards distributed)';
COMMENT ON COLUMN pr_activities.posted_at IS 'When activity was posted to feed';
COMMENT ON COLUMN pr_activities.completed_at IS 'When activity completed its workflow';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_pr_templates_name ON pr_templates (name);
CREATE INDEX IF NOT EXISTS idx_pr_templates_active_public ON pr_templates (is_active, is_public, display_order) WHERE is_active = true AND is_public = true;
CREATE INDEX IF NOT EXISTS idx_pr_template_ranks_template ON pr_template_ranks (template_id);

CREATE INDEX IF NOT EXISTS idx_pr_activities_paper ON pr_activities (paper_id);
CREATE INDEX IF NOT EXISTS idx_pr_activities_creator ON pr_activities (creator_id);
CREATE INDEX IF NOT EXISTS idx_pr_activities_template ON pr_activities (template_id);
CREATE INDEX IF NOT EXISTS idx_pr_activities_posted ON pr_activities (posted_at DESC);
CREATE INDEX IF NOT EXISTS idx_pr_activities_uuid ON pr_activities (activity_uuid);
CREATE INDEX IF NOT EXISTS idx_pr_activities_active ON pr_activities (activity_id, posted_at DESC) WHERE completed_at IS NULL;

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_pr_templates_updated_at
  BEFORE UPDATE ON pr_templates
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_pr_activities_updated_at
  BEFORE UPDATE ON pr_activities
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================

-- PR Templates: Read-only for authenticated users
ALTER TABLE pr_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE pr_template_ranks ENABLE ROW LEVEL SECURITY;

CREATE POLICY pr_templates_select_authenticated ON pr_templates
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY pr_templates_modify_service_role_only ON pr_templates
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY pr_template_ranks_select_authenticated ON pr_template_ranks
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY pr_template_ranks_modify_service_role_only ON pr_template_ranks
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- PR Activities: Users see activities they created or participate in
ALTER TABLE pr_activities ENABLE ROW LEVEL SECURITY;

-- Basic policy: Users see activities they created
-- This will be extended after pr_activity_permissions table exists
CREATE POLICY pr_activities_select_creator_or_service ON pr_activities
  FOR SELECT
  USING (
    creator_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify activities (via API routes)
CREATE POLICY pr_activities_insert_service_role_only ON pr_activities
  FOR INSERT
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY pr_activities_update_service_role_only ON pr_activities
  FOR UPDATE
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY pr_activities_delete_service_role_only ON pr_activities
  FOR DELETE
  USING ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_activities_select_creator_or_service ON pr_activities IS
  'Users see activities they created (participant access added in migration 21)';

-- =============================================
-- Helper Functions
-- =============================================

-- Function: Create PR activity with initial stage setup
CREATE OR REPLACE FUNCTION create_pr_activity(
  p_paper_id INTEGER,
  p_creator_id INTEGER,
  p_template_id INTEGER,
  p_funding_amount INTEGER
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
    AND activity_type = 'pr-activity'
    AND is_initial_stage = true
  LIMIT 1;
  
  IF v_initial_stage_key IS NULL THEN
    RAISE EXCEPTION 'Template % has no initial stage defined', p_template_id;
  END IF;
  
  -- 2. Insert activity
  INSERT INTO pr_activities (
    paper_id,
    creator_id,
    template_id,
    funding_amount,
    escrow_balance,
    posted_at
  )
  VALUES (
    p_paper_id,
    p_creator_id,
    p_template_id,
    p_funding_amount,
    p_funding_amount,  -- Initial escrow equals funding
    NOW()
  )
  RETURNING activity_id, activity_uuid INTO v_activity_id, v_activity_uuid;
  
  -- 3. Initialize stage state (posted stage has no deadline)
  INSERT INTO activity_stage_state (
    activity_type,
    activity_id,
    current_stage_key,
    stage_entered_at,
    stage_deadline
  )
  VALUES (
    'pr-activity',
    v_activity_id,
    v_initial_stage_key,
    NOW(),
    NULL  -- Posted stage has no deadline
  );
  
  -- 4. Create permission for creator (CRITICAL: required for RLS access)
  INSERT INTO pr_activity_permissions (
    activity_id,
    user_id,
    role,
    granted_at
  )
  VALUES (
    v_activity_id,
    p_creator_id,
    'corresponding_author',
    NOW()
  )
  ON CONFLICT (activity_id, user_id) DO NOTHING;  -- Handle duplicate gracefully
  
  -- 5. Create initial timeline event
  INSERT INTO pr_timeline_events (
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
    'Activity Created',
    'Peer review activity posted on feed'
  )
  RETURNING event_id INTO v_timeline_event_id;
  
  -- 6. Return result
  RETURN jsonb_build_object(
    'activity_id', v_activity_id,
    'activity_uuid', v_activity_uuid,
    'initial_stage_key', v_initial_stage_key,
    'timeline_event_id', v_timeline_event_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION create_pr_activity IS 'Atomically creates PR activity with initial stage state, creator permission, and timeline event';

-- Grant permissions
GRANT EXECUTE ON FUNCTION create_pr_activity TO authenticated;

