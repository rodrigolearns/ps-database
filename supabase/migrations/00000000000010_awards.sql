-- =============================================
-- 00000000000010_awards.sql
-- Award Domain: Awards and Rewards
-- =============================================

-- Award types table
CREATE TABLE IF NOT EXISTS award_types (
  type_id SERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  description TEXT,
  icon TEXT,
  color TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE award_types IS 'Types of awards that can be given';
COMMENT ON COLUMN award_types.type_id IS 'Primary key for the award type';
COMMENT ON COLUMN award_types.name IS 'Name of the award type';
COMMENT ON COLUMN award_types.description IS 'Description of the award';
COMMENT ON COLUMN award_types.icon IS 'Icon identifier for the award';
COMMENT ON COLUMN award_types.color IS 'Color theme for the award';
COMMENT ON COLUMN award_types.is_active IS 'Whether this award type is active';
COMMENT ON COLUMN award_types.created_at IS 'When the award type was created';
COMMENT ON COLUMN award_types.updated_at IS 'When the award type was last updated';

-- Awards given table
CREATE TABLE IF NOT EXISTS award_given (
  award_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  recipient_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  giver_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  award_type_id INTEGER NOT NULL REFERENCES award_types(type_id) ON DELETE CASCADE,
  token_amount INTEGER DEFAULT 0,
  rank_position INTEGER,
  reason TEXT,
  given_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE award_given IS 'Awards given to users for activities';
COMMENT ON COLUMN award_given.award_id IS 'Primary key for the award';
COMMENT ON COLUMN award_given.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN award_given.recipient_id IS 'Foreign key to user_accounts (recipient)';
COMMENT ON COLUMN award_given.giver_id IS 'Foreign key to user_accounts (giver)';
COMMENT ON COLUMN award_given.award_type_id IS 'Foreign key to award_types';
COMMENT ON COLUMN award_given.token_amount IS 'Number of tokens awarded';
COMMENT ON COLUMN award_given.rank_position IS 'Rank position (1st, 2nd, etc.)';
COMMENT ON COLUMN award_given.reason IS 'Reason for the award';
COMMENT ON COLUMN award_given.given_at IS 'When the award was given';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_award_types_name ON award_types (name);
CREATE INDEX IF NOT EXISTS idx_award_types_is_active ON award_types (is_active);

CREATE INDEX IF NOT EXISTS idx_award_given_activity_id ON award_given (activity_id);
CREATE INDEX IF NOT EXISTS idx_award_given_recipient_id ON award_given (recipient_id);
CREATE INDEX IF NOT EXISTS idx_award_given_giver_id ON award_given (giver_id);
CREATE INDEX IF NOT EXISTS idx_award_given_award_type_id ON award_given (award_type_id);
CREATE INDEX IF NOT EXISTS idx_award_given_given_at ON award_given (given_at);
CREATE INDEX IF NOT EXISTS idx_award_given_rank_position ON award_given (rank_position);

-- Triggers
CREATE TRIGGER update_award_types_updated_at
  BEFORE UPDATE ON award_types
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- Seed data for award types
INSERT INTO award_types (name, description, icon, color) VALUES
  ('Best Review', 'Outstanding review quality', 'star', 'gold'),
  ('Thorough Analysis', 'Comprehensive and detailed review', 'magnifying-glass', 'silver'),
  ('Constructive Feedback', 'Helpful and constructive comments', 'lightbulb', 'bronze'),
  ('Timely Submission', 'Submitted review on time', 'clock', 'blue'),
  ('Collaborative Spirit', 'Excellent collaboration in evaluation', 'handshake', 'green')
ON CONFLICT (name) DO UPDATE SET
  description = EXCLUDED.description,
  icon = EXCLUDED.icon,
  color = EXCLUDED.color,
  updated_at = NOW(); 