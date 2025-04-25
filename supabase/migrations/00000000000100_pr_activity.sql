-- =============================================
-- 00000000000004_pr_activities.sql
-- Migration for Peer Review Activities Table
-- =============================================

-- Create ENUM type for current_state of activities
DO $$ BEGIN
  CREATE TYPE activity_state AS ENUM (
    'submitted',
    'review_round_1',
    'author_response_1',
    'review_round_2',
    'author_response_2',
    'review_round_3',
    'awarding',
    'completed'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON TYPE activity_state IS 'Current stage of the peer review activity';

-- Create ENUM type for moderation state
DO $$ BEGIN
  CREATE TYPE moderation_state AS ENUM ('none', 'pending', 'resolved');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON TYPE moderation_state IS 'Moderation state of the activity';

-- Create peer_review_templates table for peer review configurations
CREATE TABLE IF NOT EXISTS peer_review_templates (
  template_id       SERIAL PRIMARY KEY,
  name              TEXT NOT NULL UNIQUE,
  reviewer_count    INTEGER NOT NULL,
  review_rounds     INTEGER NOT NULL,
  total_tokens      INTEGER NOT NULL,
  tokens_by_rank    JSONB NOT NULL,    -- e.g. [3,3,2] or [4,4,3,2]
  extra_tokens      INTEGER NOT NULL DEFAULT 2,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON TABLE peer_review_templates IS 'Pre‑configured templates for peer review workflows';

-- Seed the two example templates
INSERT INTO peer_review_templates (name, reviewer_count, review_rounds, total_tokens, tokens_by_rank, extra_tokens)
VALUES
  ('2-round, 3-reviewers, 10-tokens', 3, 2, 10, '[3,3,2]'::jsonb, 2),
  ('3-round, 4-reviewers, 15-tokens', 4, 3, 15, '[4,4,3,2]'::jsonb, 2)
ON CONFLICT (name) DO UPDATE SET
  reviewer_count = EXCLUDED.reviewer_count,
  review_rounds = EXCLUDED.review_rounds,
  total_tokens = EXCLUDED.total_tokens,
  tokens_by_rank = EXCLUDED.tokens_by_rank,
  extra_tokens = EXCLUDED.extra_tokens,
  updated_at = NOW();

-- Main peer_review_activities table
CREATE TABLE IF NOT EXISTS peer_review_activities (
  activity_id SERIAL PRIMARY KEY,
  activity_uuid UUID NOT NULL DEFAULT gen_random_uuid(), -- Universal identifier across activity types
  paper_id INTEGER NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  creator_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  template_id INTEGER NOT NULL REFERENCES peer_review_templates(template_id),
  funding_amount INTEGER NOT NULL,
  escrow_balance INTEGER NOT NULL,
  current_state activity_state NOT NULL DEFAULT 'submitted',
  stage_deadline TIMESTAMPTZ, -- Deadline for the current stage
  flag_history JSONB DEFAULT '[]'::jsonb, -- Array of flags with type, timestamp, status, etc.
  moderation_state moderation_state NOT NULL DEFAULT 'none',
  posted_at TIMESTAMPTZ, -- When the activity was posted to the feed
  start_date TIMESTAMPTZ, -- When reviewer team reached full size and review begins
  completed_at TIMESTAMPTZ, -- When the activity was finalized
  super_admin_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL, -- Admin receiving leftover tokens
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON TABLE peer_review_activities IS 'Peer review activities for papers submitted to the platform.';
COMMENT ON COLUMN peer_review_activities.activity_id IS 'Primary key for the peer review activity';
COMMENT ON COLUMN peer_review_activities.activity_uuid IS 'Universal UUID for linking to the activity across activity types';
COMMENT ON COLUMN peer_review_activities.paper_id IS 'Foreign key to papers table';
COMMENT ON COLUMN peer_review_activities.creator_id IS 'User who created the activity (corresponding author)';
COMMENT ON COLUMN peer_review_activities.template_id IS 'Which review template configuration this activity uses';
COMMENT ON COLUMN peer_review_activities.funding_amount IS 'Initial token escrow amount for the activity';
COMMENT ON COLUMN peer_review_activities.escrow_balance IS 'Current token balance in the activity escrow';
COMMENT ON COLUMN peer_review_activities.current_state IS 'Current stage of the peer review activity';
COMMENT ON COLUMN peer_review_activities.stage_deadline IS 'Deadline for the current activity stage';
COMMENT ON COLUMN peer_review_activities.flag_history IS 'History of flags raised during the activity';
COMMENT ON COLUMN peer_review_activities.moderation_state IS 'Moderation status of the activity';
COMMENT ON COLUMN peer_review_activities.posted_at IS 'When the activity was posted to the feed';
COMMENT ON COLUMN peer_review_activities.start_date IS 'Timestamp when reviewer team reached full size and review begins';
COMMENT ON COLUMN peer_review_activities.completed_at IS 'When the activity was finalized';
COMMENT ON COLUMN peer_review_activities.super_admin_id IS 'Super admin who receives leftover tokens upon activity completion';
COMMENT ON COLUMN peer_review_activities.updated_at IS 'When the activity record was last updated';

-- Function update_activities_updated_at removed, using generic set_updated_at
DROP TRIGGER IF EXISTS update_activities_updated_at_trigger ON peer_review_activities;
CREATE TRIGGER update_activities_updated_at_trigger
BEFORE UPDATE ON peer_review_activities
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- Function update_template_updated_at removed, using generic set_updated_at
DROP TRIGGER IF EXISTS update_template_updated_at_trigger ON peer_review_templates;
CREATE TRIGGER update_template_updated_at_trigger
BEFORE UPDATE ON peer_review_templates
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_pr_activities_activity_uuid ON peer_review_activities (activity_uuid);
