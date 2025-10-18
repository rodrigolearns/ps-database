-- =============================================
-- 00000000000006_pr_core.sql
-- Core PR Functions and Policies (Simplified)
-- =============================================

-- Simple function to deduct tokens for activities (KEEP - Essential for atomicity)
CREATE OR REPLACE FUNCTION activity_deduct_tokens(
  p_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT,
  p_activity_id INTEGER,
  p_activity_uuid UUID
) RETURNS BOOLEAN AS $$
DECLARE
  v_current_balance INTEGER;
BEGIN
  -- Get current balance with row lock
  SELECT balance INTO v_current_balance
  FROM wallet_balances
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_current_balance IS NULL OR v_current_balance < p_amount THEN
    RETURN FALSE;
  END IF;

  -- Record transaction (trigger will update wallet balance automatically)
  INSERT INTO wallet_transactions (
    user_id, amount, transaction_type,
    description, related_activity_id, related_activity_uuid
  ) VALUES (
    p_user_id, -p_amount, 'debit',
    p_description, p_activity_id, p_activity_uuid
  );

  RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION activity_deduct_tokens(INTEGER, INTEGER, TEXT, INTEGER, UUID) IS 'Deducts tokens from a user wallet for PR activities';

-- =============================================
-- Peer Review Domain: Core Activities and Templates
-- =============================================

-- Create ENUMs for peer review system
DO $$ BEGIN
  CREATE TYPE activity_state AS ENUM (
    'submitted',
    'review_round_1',
    'author_response_1',
    'review_round_2',
    'author_response_2',
    'assessment',
    'awarding',
    'publication_choice',
    'published_on_ps',
    'submitted_externally',
    'made_private'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE activity_state IS 'Current stage of the peer review activity';

DO $$ BEGIN
  CREATE TYPE moderation_state AS ENUM ('none','pending','resolved');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE moderation_state IS 'Moderation state of the activity';

-- Stage types for the abstracted system
DO $$ BEGIN
  CREATE TYPE stage_type AS ENUM (
    'simple_form',
    'collaborative_assessment',
    'awards_distribution',
    'display',
    'custom'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE stage_type IS 'Type of stage determining its behavior';

-- Peer review templates table
CREATE TABLE IF NOT EXISTS pr_templates (
  template_id SERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  reviewer_count INTEGER NOT NULL,
  review_rounds INTEGER NOT NULL,
  total_tokens INTEGER NOT NULL,
  extra_tokens INTEGER NOT NULL DEFAULT 2,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE pr_templates IS 'Templates for peer review activities';
COMMENT ON COLUMN pr_templates.template_id IS 'Primary key for the template';
COMMENT ON COLUMN pr_templates.name IS 'Name of the template';
COMMENT ON COLUMN pr_templates.reviewer_count IS 'Number of reviewers required';
COMMENT ON COLUMN pr_templates.review_rounds IS 'Number of review rounds';
COMMENT ON COLUMN pr_templates.total_tokens IS 'Total tokens available for distribution';
COMMENT ON COLUMN pr_templates.extra_tokens IS 'Extra tokens for top performers';
COMMENT ON COLUMN pr_templates.created_at IS 'When the template was created';
COMMENT ON COLUMN pr_templates.updated_at IS 'When the template was last updated';

-- Template token ranks table
CREATE TABLE IF NOT EXISTS pr_template_ranks (
  template_id INTEGER NOT NULL REFERENCES pr_templates(template_id) ON DELETE CASCADE,
  rank_position INTEGER NOT NULL,
  tokens INTEGER NOT NULL,
  PRIMARY KEY (template_id, rank_position)
);

COMMENT ON TABLE pr_template_ranks IS 'Token distribution by rank for each template';
COMMENT ON COLUMN pr_template_ranks.template_id IS 'Foreign key to pr_templates';
COMMENT ON COLUMN pr_template_ranks.rank_position IS 'Rank position (1st, 2nd, etc.)';
COMMENT ON COLUMN pr_template_ranks.tokens IS 'Tokens awarded for this rank';

-- Stage configuration removed - logic moved to TypeScript (DEVELOPMENT_PRINCIPLES.md)
-- All stage behavior is now defined in application layer, not database

-- Peer review activities table
CREATE TABLE IF NOT EXISTS pr_activities (
  activity_id SERIAL PRIMARY KEY,
  activity_uuid UUID NOT NULL DEFAULT gen_random_uuid(),
  paper_id INTEGER NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  creator_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  template_id INTEGER NOT NULL REFERENCES pr_templates(template_id),
  funding_amount INTEGER NOT NULL,
  escrow_balance INTEGER NOT NULL,
  current_state activity_state NOT NULL DEFAULT 'submitted',
  stage_deadline TIMESTAMPTZ,
  moderation_state moderation_state NOT NULL DEFAULT 'none',
  posted_at TIMESTAMPTZ DEFAULT NOW(),
  start_date TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  super_admin_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  stage_config_override JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_escrow_nonnegative CHECK (escrow_balance >= 0),
  CONSTRAINT chk_escrow_not_exceed_funding CHECK (escrow_balance <= funding_amount)
);

COMMENT ON TABLE pr_activities IS 'Peer review activities for papers';
COMMENT ON COLUMN pr_activities.activity_id IS 'Primary key for the activity';
COMMENT ON COLUMN pr_activities.activity_uuid IS 'UUID for the activity';
COMMENT ON COLUMN pr_activities.paper_id IS 'Foreign key to papers';
COMMENT ON COLUMN pr_activities.creator_id IS 'User who created the activity';
COMMENT ON COLUMN pr_activities.template_id IS 'Template used for this activity';
COMMENT ON COLUMN pr_activities.funding_amount IS 'Total funding amount for the activity';
COMMENT ON COLUMN pr_activities.escrow_balance IS 'Current escrow balance';
COMMENT ON COLUMN pr_activities.current_state IS 'Current state of the activity';
COMMENT ON COLUMN pr_activities.stage_deadline IS 'Deadline for current stage';
COMMENT ON COLUMN pr_activities.moderation_state IS 'Moderation state of the activity';
COMMENT ON COLUMN pr_activities.posted_at IS 'When the activity was posted';
COMMENT ON COLUMN pr_activities.start_date IS 'When the activity started';
COMMENT ON COLUMN pr_activities.completed_at IS 'When the activity was completed';
COMMENT ON COLUMN pr_activities.super_admin_id IS 'Super admin overseeing the activity';
COMMENT ON COLUMN pr_activities.stage_config_override IS 'Activity-specific stage configuration overrides';
COMMENT ON COLUMN pr_activities.created_at IS 'When the activity was created';
COMMENT ON COLUMN pr_activities.updated_at IS 'When the activity was last updated';

-- State transitions table (for validation) - KEEP as reference data
CREATE TABLE IF NOT EXISTS pr_state_transitions (
  from_state activity_state NOT NULL,
  to_state activity_state NOT NULL,
  PRIMARY KEY (from_state, to_state)
);

COMMENT ON TABLE pr_state_transitions IS 'Valid state transitions for peer review activities';
COMMENT ON COLUMN pr_state_transitions.from_state IS 'Starting state';
COMMENT ON COLUMN pr_state_transitions.to_state IS 'Target state';

-- Insert valid state transitions FIRST (before creating foreign key constraint)
INSERT INTO pr_state_transitions (from_state, to_state) VALUES
  ('submitted', 'review_round_1'),
  ('review_round_1', 'author_response_1'),
  ('author_response_1', 'review_round_2'), 
  ('review_round_2', 'assessment'),
  ('assessment', 'awarding'),
  ('awarding', 'publication_choice'),
  ('publication_choice', 'published_on_ps'),
  ('publication_choice', 'submitted_externally'),
  ('publication_choice', 'made_private')
ON CONFLICT DO NOTHING;

-- Stage transition rules removed - logic moved to TypeScript (DEVELOPMENT_PRINCIPLES.md)
-- All progression rules are now defined in ProgressionRules.ts, not database

-- State change audit log - KEEP for audit trail
CREATE TABLE IF NOT EXISTS pr_state_log (
  log_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  old_state activity_state,
  new_state activity_state NOT NULL,
  changed_at TIMESTAMPTZ DEFAULT NOW(),
  changed_by INTEGER REFERENCES user_accounts(user_id), -- NULL for system changes
  reason TEXT,
  metadata JSONB DEFAULT '{}'::jsonb
);

COMMENT ON TABLE pr_state_log IS 'History of peer-review activity state transitions';
COMMENT ON COLUMN pr_state_log.log_id IS 'Primary key for the log entry';
COMMENT ON COLUMN pr_state_log.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_state_log.old_state IS 'Previous state (NULL for initial state)';
COMMENT ON COLUMN pr_state_log.new_state IS 'New state';
COMMENT ON COLUMN pr_state_log.changed_at IS 'When the state changed';
COMMENT ON COLUMN pr_state_log.changed_by IS 'User who triggered the state change (NULL for system changes)';
COMMENT ON COLUMN pr_state_log.reason IS 'Reason for the state change';
COMMENT ON COLUMN pr_state_log.metadata IS 'Additional metadata for the state change';

-- Stage-specific data storage (runtime data) - Must be created after pr_activities
CREATE TABLE IF NOT EXISTS pr_stage_data (
  data_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  stage_name activity_state NOT NULL,
  data_key TEXT NOT NULL,
  data_value JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(activity_id, stage_name, data_key)
);

COMMENT ON TABLE pr_stage_data IS 'Runtime data storage for stages';
COMMENT ON COLUMN pr_stage_data.data_id IS 'Primary key';
COMMENT ON COLUMN pr_stage_data.activity_id IS 'Associated PR activity';
COMMENT ON COLUMN pr_stage_data.stage_name IS 'Stage this data belongs to';
COMMENT ON COLUMN pr_stage_data.data_key IS 'Key for the data';
COMMENT ON COLUMN pr_stage_data.data_value IS 'Value stored as JSON';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_templates_name ON pr_templates (name);
CREATE INDEX IF NOT EXISTS idx_pr_template_ranks_template_id ON pr_template_ranks (template_id);

CREATE INDEX IF NOT EXISTS idx_pr_activities_paper_id ON pr_activities (paper_id);
CREATE INDEX IF NOT EXISTS idx_pr_activities_creator_id ON pr_activities (creator_id);
CREATE INDEX IF NOT EXISTS idx_pr_activities_template_id ON pr_activities (template_id);
CREATE INDEX IF NOT EXISTS idx_pr_activities_current_state ON pr_activities (current_state);
CREATE INDEX IF NOT EXISTS idx_pr_activities_posted_at ON pr_activities (posted_at);
CREATE INDEX IF NOT EXISTS idx_pr_activities_activity_uuid ON pr_activities (activity_uuid);

-- Add columns for progression tracking if they don't exist
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='pr_activities' AND column_name='state_changed_at') THEN
    ALTER TABLE pr_activities ADD COLUMN state_changed_at TIMESTAMPTZ DEFAULT NOW();
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='pr_activities' AND column_name='state_changed_by') THEN
    ALTER TABLE pr_activities ADD COLUMN state_changed_by INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL;
  END IF;
END $$;

-- Performance indexes for progression system
CREATE INDEX IF NOT EXISTS idx_pr_activities_state_user ON pr_activities (activity_id, current_state, state_changed_by);
CREATE INDEX IF NOT EXISTS idx_pr_activities_state_changed ON pr_activities (current_state, state_changed_at);

CREATE INDEX IF NOT EXISTS idx_pr_state_log_activity_id ON pr_state_log (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_state_log_changed_at ON pr_state_log (changed_at);

-- Indexes for removed stage configuration system - no longer needed
-- Stage logic moved to TypeScript (DEVELOPMENT_PRINCIPLES.md)

-- Basic triggers for updated_at fields
CREATE TRIGGER update_pr_templates_updated_at
  BEFORE UPDATE ON pr_templates
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_pr_activities_updated_at
  BEFORE UPDATE ON pr_activities
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- Triggers for removed stage configuration system - no longer needed
-- Stage logic moved to TypeScript (DEVELOPMENT_PRINCIPLES.md)

-- Seed data for templates
INSERT INTO pr_templates(name, reviewer_count, review_rounds, total_tokens, extra_tokens)
VALUES
  ('1-round,3-reviewers,10-tokens', 3, 1, 10, 2),
  ('2-round,4-reviewers,20-tokens', 4, 2, 20, 2)
ON CONFLICT (name) DO UPDATE
  SET reviewer_count=EXCLUDED.reviewer_count,
      review_rounds=EXCLUDED.review_rounds,
      total_tokens=EXCLUDED.total_tokens,
      extra_tokens=EXCLUDED.extra_tokens,
      updated_at=NOW();

-- Seed data for template token ranks
INSERT INTO pr_template_ranks(template_id, rank_position, tokens)
SELECT
  t.template_id,
  u.ordinality,
  u.val
FROM pr_templates t
JOIN LATERAL (
  SELECT ARRAY[3,3,2]::INTEGER[] AS arr WHERE t.name='1-round,3-reviewers,10-tokens'
  UNION ALL
  SELECT ARRAY[4,4,3,2]::INTEGER[] WHERE t.name='2-round,4-reviewers,15-tokens'
) AS cfg ON TRUE
JOIN LATERAL unnest(cfg.arr) WITH ORDINALITY AS u(val, ordinality) ON TRUE
ON CONFLICT DO NOTHING;

-- Seed data for valid state transitions
INSERT INTO pr_state_transitions(from_state, to_state) VALUES
  ('submitted','review_round_1'),
  ('review_round_1','author_response_1'),
  ('author_response_1','review_round_2'),
  ('review_round_2','author_response_2'),
          ('author_response_1','assessment'),
        ('author_response_2','assessment'),
        ('assessment','awarding'),
  ('awarding','publication_choice'),
  ('publication_choice','published_on_ps'),
  ('publication_choice','submitted_externally'),
  ('publication_choice','made_private')
ON CONFLICT DO NOTHING;

-- =============================================
-- RLS POLICIES MOVED TO PROPER MIGRATIONS
-- =============================================
-- Following DEVELOPMENT_PRINCIPLES.md: Clean, Stale-Free Code
-- RLS policies have been moved to their proper migration files:
-- - papers: 00000000000004_papers.sql
-- - paper_contributors: 00000000000004_papers.sql
-- - authors: 00000000000004_papers.sql (legacy table)
-- - pr_activities: Defined later in activity-specific migrations
--
-- This migration only defines core tables and state machine logic.
-- No RLS policies defined here to avoid conflicts and maintain clean separation.
-- All RLS policies for papers, authors, and paper_authors are in 00000000000004_papers.sql

-- =============================================
-- STAGE TRANSITION RULES REMOVED
-- =============================================
-- Following DEVELOPMENT_PRINCIPLES.md: "Database as Source of Truth"
-- All progression rules are now defined in TypeScript (ProgressionRules.ts)
-- Database only stores state and configuration, not business logic

-- =============================================
-- SECURITY AUDIT LOG
-- =============================================
-- Security audit log for progression system operations
-- Critical for security monitoring and compliance

CREATE TABLE IF NOT EXISTS pr_security_audit_log (
  log_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  user_action TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('SUCCESS', 'SECURITY_FAILURE')),
  progression_occurred BOOLEAN NOT NULL DEFAULT false,
  from_state activity_state,
  to_state activity_state,
  session_id TEXT,
  ip_address INET,
  user_agent TEXT,
  request_id UUID,
  error_message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE pr_security_audit_log IS 'Security audit trail for progression system operations';
COMMENT ON COLUMN pr_security_audit_log.log_id IS 'Primary key for the audit log entry';
COMMENT ON COLUMN pr_security_audit_log.activity_id IS 'PR activity ID (not foreign key to allow logging even if activity deleted)';
COMMENT ON COLUMN pr_security_audit_log.user_id IS 'User ID who attempted the progression (not foreign key for audit integrity)';
COMMENT ON COLUMN pr_security_audit_log.user_action IS 'Action that was attempted (e.g., reviewer_locked_in)';
COMMENT ON COLUMN pr_security_audit_log.status IS 'Result of security validation (SUCCESS or SECURITY_FAILURE)';
COMMENT ON COLUMN pr_security_audit_log.progression_occurred IS 'Whether progression actually occurred';
COMMENT ON COLUMN pr_security_audit_log.from_state IS 'Activity state before progression';
COMMENT ON COLUMN pr_security_audit_log.to_state IS 'Activity state after progression (if successful)';
COMMENT ON COLUMN pr_security_audit_log.session_id IS 'User session identifier for tracking';
COMMENT ON COLUMN pr_security_audit_log.ip_address IS 'IP address of the request';
COMMENT ON COLUMN pr_security_audit_log.user_agent IS 'User agent string from the request';
COMMENT ON COLUMN pr_security_audit_log.request_id IS 'Unique request identifier for correlation';
COMMENT ON COLUMN pr_security_audit_log.error_message IS 'Error message if security validation failed';
COMMENT ON COLUMN pr_security_audit_log.created_at IS 'When the audit log entry was created';

-- Indexes for security monitoring and analysis
CREATE INDEX IF NOT EXISTS idx_security_audit_activity_id ON pr_security_audit_log (activity_id);
CREATE INDEX IF NOT EXISTS idx_security_audit_user_id ON pr_security_audit_log (user_id);
CREATE INDEX IF NOT EXISTS idx_security_audit_status ON pr_security_audit_log (status);
CREATE INDEX IF NOT EXISTS idx_security_audit_created_at ON pr_security_audit_log (created_at);
CREATE INDEX IF NOT EXISTS idx_security_audit_user_action ON pr_security_audit_log (user_action);

-- Composite index for security analysis queries
CREATE INDEX IF NOT EXISTS idx_security_audit_user_status_time 
ON pr_security_audit_log (user_id, status, created_at);

-- Index for IP-based security monitoring
CREATE INDEX IF NOT EXISTS idx_security_audit_ip_status_time 
ON pr_security_audit_log (ip_address, status, created_at) 
WHERE ip_address IS NOT NULL;

-- =============================================
-- ATOMIC PROGRESSION TRANSACTION FUNCTION
-- =============================================
-- Atomic function for progression operations to prevent race conditions
-- Following DEVELOPMENT_PRINCIPLES.md: Database as Source of Truth for transactions

CREATE OR REPLACE FUNCTION update_activity_state(
  p_activity_id INTEGER,
  p_old_state activity_state,
  p_new_state activity_state,
  p_user_id INTEGER,
  p_reason TEXT
) RETURNS BOOLEAN 
LANGUAGE plpgsql 
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Simple atomic update - no overengineering
  -- Set stage_transition_at to track when new stage began (for deadline calculation)
  UPDATE public.pr_activities 
  SET 
    current_state = p_new_state, 
    stage_transition_at = NOW(),
    updated_at = NOW()
  WHERE activity_id = p_activity_id AND current_state = p_old_state;
  
  -- Return true if update worked, false if state mismatch
  RETURN FOUND;
END;
$$;

-- =============================================
-- PERFORMANCE OPTIMIZATION INDEXES
-- =============================================
-- Following DEVELOPMENT_PRINCIPLES.md: Database as Source of Truth for performance
-- Indexes optimized for progression system queries

-- Partial index for active activities (performance optimization)
-- This table exists in this migration, so we can create the index here
CREATE INDEX IF NOT EXISTS idx_pr_activities_active_state 
ON pr_activities(activity_id, current_state, template_id) 
WHERE current_state NOT IN ('published_on_ps', 'submitted_externally', 'made_private');

-- =============================================
-- PERFORMANCE OPTIMIZATION INDEXES - PR Activity Page
-- =============================================
-- Following DEVELOPMENT_PRINCIPLES.md: Database as Source of Truth for performance
-- Indexes optimized for the main PR activity data loading query

-- Composite index for main activity query with related data lookup
CREATE INDEX IF NOT EXISTS idx_pr_activities_comprehensive_lookup 
ON pr_activities (activity_id, paper_id, template_id, creator_id, current_state);

-- Covering index for activity basic info (avoids table lookup for common fields)
CREATE INDEX IF NOT EXISTS idx_pr_activities_basic_info_covering 
ON pr_activities (activity_id) 
INCLUDE (current_state, stage_deadline, posted_at, escrow_balance, activity_uuid, created_at, updated_at);

-- =============================================
-- FUNCTION PERMISSIONS
-- =============================================
-- State transition function handles critical workflow logic
-- Only service role can execute this (via API routes with permission checks)

REVOKE EXECUTE ON FUNCTION update_activity_state(INTEGER, activity_state, activity_state, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_activity_state(INTEGER, activity_state, activity_state, INTEGER, TEXT) TO service_role;

-- =============================================
-- RLS POLICIES FOR CORE PR TABLES
-- =============================================
-- Resolves security warnings: RLS disabled on pr_activities, pr_stage_data, pr_state_log, pr_processing_log
-- Access pattern: Users see activities they created or public activities (extended in migration 12)
-- Note: Activity participant access will be added in migration 12 after pr_activity_permissions is created
-- Used by: All PR activity routes, timeline, admin dashboard

-- =============================================
-- 1. pr_activities (CRITICAL - P0)
-- =============================================
ALTER TABLE pr_activities ENABLE ROW LEVEL SECURITY;

-- Basic policy: Users can see activities they created or public activities
-- This will be extended in migration 12 with activity participant access
CREATE POLICY pr_activities_select_creator_or_public ON pr_activities
  FOR SELECT
  USING (
    creator_id = (SELECT auth_user_id()) OR
    current_state = 'published_on_ps' OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify activities (managed by progression orchestrator)
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

COMMENT ON POLICY pr_activities_select_creator_or_public ON pr_activities IS
  'Users see activities they created or public activities (extended with participant access in migration 12)';

-- =============================================
-- 2. pr_stage_data (CRITICAL - P0)
-- =============================================
ALTER TABLE pr_stage_data ENABLE ROW LEVEL SECURITY;

-- Basic policy: Only service role can access (will be extended in migration 12)
CREATE POLICY pr_stage_data_service_role_only ON pr_stage_data
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_stage_data_service_role_only ON pr_stage_data IS
  'Service role only (extended with participant access in migration 12)';

-- =============================================
-- 3. pr_state_log (MEDIUM - P2)
-- =============================================
ALTER TABLE pr_state_log ENABLE ROW LEVEL SECURITY;

-- Basic policy: Only service role can access (will be extended in migration 12)
CREATE POLICY pr_state_log_service_role_only ON pr_state_log
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_state_log_service_role_only ON pr_state_log IS
  'Service role only (extended with participant access in migration 12)';

-- =============================================
-- 4. pr_security_audit_log (MEDIUM - P2)
-- =============================================
ALTER TABLE pr_security_audit_log ENABLE ROW LEVEL SECURITY;

-- Basic policy: Only service role can access (will be extended in migration 12)
CREATE POLICY pr_security_audit_log_service_role_only ON pr_security_audit_log
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_security_audit_log_service_role_only ON pr_security_audit_log IS
  'Service role only (extended with participant access in migration 12)';

-- =============================================
-- 6. pr_templates (LOW - P3)
-- =============================================
ALTER TABLE pr_templates ENABLE ROW LEVEL SECURITY;

-- Templates are readable by all authenticated users (public reference data)
CREATE POLICY pr_templates_select_authenticated ON pr_templates
  FOR SELECT
  USING (
    (SELECT auth.role()) IN ('authenticated', 'service_role')
  );

-- Only service role can modify templates
CREATE POLICY pr_templates_modify_service_role_only ON pr_templates
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_templates_select_authenticated ON pr_templates IS
  'Templates are public reference data readable by all authenticated users';

-- =============================================
-- 7. pr_template_ranks (LOW - P3)
-- =============================================
ALTER TABLE pr_template_ranks ENABLE ROW LEVEL SECURITY;

-- Template ranks are readable by all authenticated users (public reference data)
CREATE POLICY pr_template_ranks_select_authenticated ON pr_template_ranks
  FOR SELECT
  USING (
    (SELECT auth.role()) IN ('authenticated', 'service_role')
  );

-- Only service role can modify template ranks
CREATE POLICY pr_template_ranks_modify_service_role_only ON pr_template_ranks
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_template_ranks_select_authenticated ON pr_template_ranks IS
  'Template ranks are public reference data readable by all authenticated users';

-- =============================================
-- 8. pr_state_transitions (LOW - P3)
-- =============================================
ALTER TABLE pr_state_transitions ENABLE ROW LEVEL SECURITY;

-- State transitions are readable by all authenticated users (public reference data)
CREATE POLICY pr_state_transitions_select_authenticated ON pr_state_transitions
  FOR SELECT
  USING (
    (SELECT auth.role()) IN ('authenticated', 'service_role')
  );

-- Only service role can modify state transitions
CREATE POLICY pr_state_transitions_modify_service_role_only ON pr_state_transitions
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_state_transitions_select_authenticated ON pr_state_transitions IS
  'State transitions are public reference data readable by all authenticated users';
