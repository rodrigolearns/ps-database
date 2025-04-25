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

-- Create templates table for peer review configurations
CREATE TABLE IF NOT EXISTS "Peer_Review_Templates" (
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
COMMENT ON TABLE "Peer_Review_Templates" IS 'Pre‑configured templates for peer review workflows';

-- Seed the two example templates
INSERT INTO "Peer_Review_Templates" (name, reviewer_count, review_rounds, total_tokens, tokens_by_rank, extra_tokens)
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

-- Main Peer Review Activities table
CREATE TABLE IF NOT EXISTS "Peer_Review_Activities" (
  activity_id SERIAL PRIMARY KEY,
  activity_uuid UUID NOT NULL DEFAULT gen_random_uuid(), -- Universal identifier across activity types
  paper_id INTEGER NOT NULL REFERENCES "Papers"(paper_id) ON DELETE CASCADE,
  creator_id INTEGER REFERENCES "User_Accounts"(user_id) ON DELETE SET NULL,
  template_id INTEGER NOT NULL REFERENCES "Peer_Review_Templates"(template_id),
  funding_amount INTEGER NOT NULL,
  escrow_balance INTEGER NOT NULL,
  current_state activity_state NOT NULL DEFAULT 'submitted',
  stage_deadline TIMESTAMPTZ, -- Deadline for the current stage
  flag_history JSONB DEFAULT '[]'::jsonb, -- Array of flags with type, timestamp, status, etc.
  moderation_state moderation_state NOT NULL DEFAULT 'none',
  posted_at TIMESTAMPTZ, -- When the activity was posted to the feed
  start_date TIMESTAMPTZ, -- When reviewer team reached full size and review begins
  completed_at TIMESTAMPTZ, -- When the activity was finalized
  super_admin_id INTEGER REFERENCES "User_Accounts"(user_id) ON DELETE SET NULL, -- Admin receiving leftover tokens
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON TABLE "Peer_Review_Activities" IS 'Peer review activities for papers submitted to the platform.';
COMMENT ON COLUMN "Peer_Review_Activities".activity_id IS 'Primary key for the peer review activity';
COMMENT ON COLUMN "Peer_Review_Activities".activity_uuid IS 'Universal UUID for linking to the activity across activity types';
COMMENT ON COLUMN "Peer_Review_Activities".paper_id IS 'Foreign key to Papers table';
COMMENT ON COLUMN "Peer_Review_Activities".creator_id IS 'User who created the activity (corresponding author)';
COMMENT ON COLUMN "Peer_Review_Activities".template_id IS 'Which review template configuration this activity uses';
COMMENT ON COLUMN "Peer_Review_Activities".funding_amount IS 'Initial token escrow amount for the activity';
COMMENT ON COLUMN "Peer_Review_Activities".escrow_balance IS 'Current token balance in the activity escrow';
COMMENT ON COLUMN "Peer_Review_Activities".current_state IS 'Current stage of the peer review activity';
COMMENT ON COLUMN "Peer_Review_Activities".stage_deadline IS 'Deadline for the current activity stage';
COMMENT ON COLUMN "Peer_Review_Activities".flag_history IS 'History of flags raised during the activity';
COMMENT ON COLUMN "Peer_Review_Activities".moderation_state IS 'Moderation status of the activity';
COMMENT ON COLUMN "Peer_Review_Activities".posted_at IS 'When the activity was posted to the feed';
COMMENT ON COLUMN "Peer_Review_Activities".start_date IS 'Timestamp when reviewer team reached full size and review begins';
COMMENT ON COLUMN "Peer_Review_Activities".completed_at IS 'When the activity was finalized';
COMMENT ON COLUMN "Peer_Review_Activities".super_admin_id IS 'Super admin who receives leftover tokens upon activity completion';
COMMENT ON COLUMN "Peer_Review_Activities".updated_at IS 'When the activity record was last updated';

-- Function update_activities_updated_at removed, using generic set_updated_at
DROP TRIGGER IF EXISTS update_activities_updated_at_trigger ON "Peer_Review_Activities";
CREATE TRIGGER update_activities_updated_at_trigger
BEFORE UPDATE ON "Peer_Review_Activities"
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- Function update_template_updated_at removed, using generic set_updated_at
DROP TRIGGER IF EXISTS update_template_updated_at_trigger ON "Peer_Review_Templates";
CREATE TRIGGER update_template_updated_at_trigger
BEFORE UPDATE ON "Peer_Review_Templates"
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_pr_activities_activity_uuid ON "Peer_Review_Activities" (activity_uuid);
