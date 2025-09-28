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
    'submission_choice',
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
  ('awarding', 'submission_choice'),
  ('submission_choice', 'published_on_ps'),
  ('submission_choice', 'submitted_externally'),
  ('submission_choice', 'made_private')
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
  ('awarding','submission_choice'),
  ('submission_choice','published_on_ps'),
  ('submission_choice','submitted_externally'),
  ('submission_choice','made_private')
ON CONFLICT DO NOTHING;

-- =============================================
-- Simplified RLS Policies
-- =============================================

-- Papers table policies
ALTER TABLE papers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view public papers"
    ON papers FOR SELECT
    USING (true);

CREATE POLICY "Authenticated users can create papers"
    ON papers FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM user_accounts ua
            WHERE ua.auth_id = (SELECT auth.uid())
            AND ua.user_id = papers.uploaded_by
        )
    );

CREATE POLICY "Paper creators can update their papers"
    ON papers FOR UPDATE TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM user_accounts ua
            WHERE ua.auth_id = (SELECT auth.uid()) 
            AND ua.user_id = papers.uploaded_by
        )
    );

-- PR Activities table policies
ALTER TABLE pr_activities ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view PR activities"
    ON pr_activities FOR SELECT
    USING (true);

CREATE POLICY "Authenticated users can create PR activities"
    ON pr_activities FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM user_accounts ua
            WHERE ua.auth_id = (SELECT auth.uid())
            AND ua.user_id = pr_activities.creator_id
        )
    );

CREATE POLICY "Activity creators can update their PR activities"
    ON pr_activities FOR UPDATE TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM user_accounts ua
            WHERE ua.auth_id = (SELECT auth.uid())
            AND ua.user_id = pr_activities.creator_id
        )
    );

-- Authors table policies
ALTER TABLE authors ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view authors"
    ON authors FOR SELECT
    USING (true);

CREATE POLICY "Users can manage their own author profiles"
    ON authors FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM user_accounts ua
            WHERE ua.auth_id = (SELECT auth.uid())
            AND ua.user_id = authors.user_id
        )
    );

CREATE POLICY "Users can update their own author profiles"
    ON authors FOR UPDATE TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM user_accounts ua
            WHERE ua.auth_id = (SELECT auth.uid())
            AND ua.user_id = authors.user_id
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM user_accounts ua
            WHERE ua.auth_id = (SELECT auth.uid())
            AND ua.user_id = authors.user_id
        )
    );

CREATE POLICY "Users can delete their own author profiles"
    ON authors FOR DELETE TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM user_accounts ua
            WHERE ua.auth_id = (SELECT auth.uid())
            AND ua.user_id = authors.user_id
        )
    );

-- Paper Authors table policies
ALTER TABLE paper_authors ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view paper authors"
    ON paper_authors FOR SELECT
    USING (true);

CREATE POLICY "Paper creators can add paper authors"
    ON paper_authors FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM papers p
            JOIN user_accounts ua ON p.uploaded_by = ua.user_id
            WHERE p.paper_id = paper_authors.paper_id
            AND ua.auth_id = (SELECT auth.uid())
        )
    );

CREATE POLICY "Paper creators can update paper authors"
    ON paper_authors FOR UPDATE TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM papers p
            JOIN user_accounts ua ON p.uploaded_by = ua.user_id
            WHERE p.paper_id = paper_authors.paper_id
            AND ua.auth_id = (SELECT auth.uid())
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM papers p
            JOIN user_accounts ua ON p.uploaded_by = ua.user_id
            WHERE p.paper_id = paper_authors.paper_id
            AND ua.auth_id = (SELECT auth.uid())
        )
    );

CREATE POLICY "Paper creators can remove paper authors"
    ON paper_authors FOR DELETE TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM papers p
            JOIN user_accounts ua ON p.uploaded_by = ua.user_id
            WHERE p.paper_id = paper_authors.paper_id
            AND ua.auth_id = (SELECT auth.uid())
        )
    );

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
AS $$
BEGIN
  -- Simple atomic update - no overengineering
  UPDATE pr_activities 
  SET current_state = p_new_state, updated_at = NOW()
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
