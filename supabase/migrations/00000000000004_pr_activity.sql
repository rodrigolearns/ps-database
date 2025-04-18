-- =============================================
-- 00000000000004_pr_activities.sql
-- Migration for Peer Review Activities Table
-- =============================================

-- Create ENUM type for activity_type
DO $$ BEGIN
  CREATE TYPE activity_type AS ENUM ('pr_activity', 'cn_activity');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON TYPE activity_type IS 'Type of activity: peer review or curation';

-- Create ENUM type for current_state of activities
DO $$ BEGIN
  CREATE TYPE activity_state AS ENUM (
    'submitted',
    'review_round_1',
    'author_response',
    'review_round_2',
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

CREATE TABLE IF NOT EXISTS "Peer_Review_Activities" (
  activity_id SERIAL PRIMARY KEY,
  activity_type activity_type NOT NULL,
  paper_id INTEGER NOT NULL REFERENCES "Papers"(paper_id) ON DELETE CASCADE,
  creator_id INTEGER REFERENCES "User_Accounts"(user_id) ON DELETE SET NULL,
  funding_amount INTEGER NOT NULL,
  escrow_balance INTEGER NOT NULL,
  current_state activity_state NOT NULL DEFAULT 'submitted',
  stage_deadline TIMESTAMPTZ, -- Deadline for the current stage
  flag_history JSONB DEFAULT '[]'::jsonb, -- Array of flags with type, timestamp, status, etc.
  moderation_state moderation_state NOT NULL DEFAULT 'none',
  reviewer_team_history JSONB DEFAULT '[]'::jsonb, -- Array of objects: each with userId, role, joinedAt, stageCompleted times
  reviewer_team INTEGER[] DEFAULT '{}'::INTEGER[], -- Array of user_ids who joined the review team from the feed
  posted_at TIMESTAMPTZ, -- When the activity was posted to the feed
  completed_at TIMESTAMPTZ, -- When the activity was finalized
  super_admin_id INTEGER REFERENCES "User_Accounts"(user_id) ON DELETE SET NULL, -- Admin receiving leftover tokens
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON TABLE "Peer_Review_Activities" IS 'Peer review activities for papers submitted to the platform.';
COMMENT ON COLUMN "Peer_Review_Activities".activity_id IS 'Primary key for the peer review activity';
COMMENT ON COLUMN "Peer_Review_Activities".activity_type IS 'Type of activity (peer review or curation)';
COMMENT ON COLUMN "Peer_Review_Activities".paper_id IS 'Foreign key to Papers table';
COMMENT ON COLUMN "Peer_Review_Activities".creator_id IS 'User who created the activity (corresponding author)';
COMMENT ON COLUMN "Peer_Review_Activities".funding_amount IS 'Initial token escrow amount for the activity';
COMMENT ON COLUMN "Peer_Review_Activities".escrow_balance IS 'Current token balance in the activity escrow';
COMMENT ON COLUMN "Peer_Review_Activities".current_state IS 'Current stage of the peer review activity';
COMMENT ON COLUMN "Peer_Review_Activities".stage_deadline IS 'Deadline for the current activity stage';
COMMENT ON COLUMN "Peer_Review_Activities".flag_history IS 'History of flags raised during the activity';
COMMENT ON COLUMN "Peer_Review_Activities".moderation_state IS 'Moderation status of the activity';
COMMENT ON COLUMN "Peer_Review_Activities".reviewer_team_history IS 'History of reviewer team participation, with timestamps for joining and stage completion';
COMMENT ON COLUMN "Peer_Review_Activities".reviewer_team IS 'Array of user_ids who have joined the reviewer team from the feed';
COMMENT ON COLUMN "Peer_Review_Activities".posted_at IS 'When the activity was posted to the feed';
COMMENT ON COLUMN "Peer_Review_Activities".completed_at IS 'When the activity was finalized';
COMMENT ON COLUMN "Peer_Review_Activities".super_admin_id IS 'Super admin who receives leftover tokens upon activity completion';
COMMENT ON COLUMN "Peer_Review_Activities".created_at IS 'When the activity record was created';
COMMENT ON COLUMN "Peer_Review_Activities".updated_at IS 'When the activity record was last updated';

-- Function to update updated_at on activity updates
CREATE OR REPLACE FUNCTION update_activities_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_activities_updated_at_trigger ON "Peer_Review_Activities";
CREATE TRIGGER update_activities_updated_at_trigger
BEFORE UPDATE ON "Peer_Review_Activities"
FOR EACH ROW
EXECUTE FUNCTION update_activities_updated_at();
