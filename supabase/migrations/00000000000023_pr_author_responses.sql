-- =============================================
-- 00000000000023_pr_author_responses.sql
-- PR Activity Domain: Author Responses
-- =============================================
-- Point-by-point responses to reviewer feedback

-- =============================================
-- PR Author Responses Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_author_responses (
  response_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  round_number INTEGER NOT NULL,
  response_content TEXT NOT NULL,
  cover_letter TEXT,
  paper_version_id INTEGER,  -- Reference to new paper version if uploaded
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, round_number)
);

COMMENT ON TABLE pr_author_responses IS 'Author responses to reviewer feedback';
COMMENT ON COLUMN pr_author_responses.response_id IS 'Primary key';
COMMENT ON COLUMN pr_author_responses.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_author_responses.user_id IS 'Foreign key to user_accounts (corresponding author)';
COMMENT ON COLUMN pr_author_responses.round_number IS 'Round number (1, 2, etc.)';
COMMENT ON COLUMN pr_author_responses.response_content IS 'Point-by-point responses to reviewers';
COMMENT ON COLUMN pr_author_responses.cover_letter IS 'General cover letter response';
COMMENT ON COLUMN pr_author_responses.paper_version_id IS 'Reference to revised paper version';
COMMENT ON COLUMN pr_author_responses.submitted_at IS 'When the response was submitted';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_activity ON pr_author_responses (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_user ON pr_author_responses (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_round ON pr_author_responses (round_number);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_submitted ON pr_author_responses (submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_activity_round ON pr_author_responses (activity_id, round_number);

-- Covering index for response lookups
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_activity_round_covering
ON pr_author_responses (activity_id, round_number)
INCLUDE (response_id, user_id, submitted_at, response_content, cover_letter, paper_version_id);

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_pr_author_responses_updated_at
  BEFORE UPDATE ON pr_author_responses
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================
-- Authors see own responses, reviewers see all responses

ALTER TABLE pr_author_responses ENABLE ROW LEVEL SECURITY;

CREATE POLICY pr_author_responses_select_participant ON pr_author_responses
  FOR SELECT
  USING (
    -- Author can see own response
    user_id = (SELECT auth_user_id()) OR
    -- Activity participants can see responses
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_author_responses.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can insert/update (via API routes)
CREATE POLICY pr_author_responses_modify_service_role_only ON pr_author_responses
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_author_responses_select_participant ON pr_author_responses IS
  'Authors see own, all participants see responses after submission';

