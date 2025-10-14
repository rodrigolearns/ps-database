-- =============================================
-- 00000000000014_pr_evaluation.sql
-- Reviewer Evaluations and Author Responses
-- =============================================

-- Review submissions table
-- Individual markdown reviews submitted by reviewers
CREATE TABLE IF NOT EXISTS pr_review_submissions (
  submission_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  round_number INTEGER NOT NULL,
  review_content TEXT NOT NULL, -- Pure markdown review, no file uploads
  is_initial_assessment BOOLEAN DEFAULT false, -- For 72-hour commitment check
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, reviewer_id, round_number)
);

COMMENT ON TABLE pr_review_submissions IS 'Individual markdown reviews submitted by reviewers';
COMMENT ON COLUMN pr_review_submissions.submission_id IS 'Primary key for the submission';
COMMENT ON COLUMN pr_review_submissions.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_review_submissions.reviewer_id IS 'Foreign key to user_accounts (reviewer)';
COMMENT ON COLUMN pr_review_submissions.round_number IS 'Round number of the review (1, 2, etc.)';
COMMENT ON COLUMN pr_review_submissions.review_content IS 'Markdown review content - no scores or ratings';
COMMENT ON COLUMN pr_review_submissions.is_initial_assessment IS 'True for 72-hour commitment assessments';
COMMENT ON COLUMN pr_review_submissions.submitted_at IS 'When the review was submitted';

-- Author responses table
-- Point-by-point responses to reviewer feedback
CREATE TABLE IF NOT EXISTS pr_author_responses (
  response_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  round_number INTEGER NOT NULL,
  response_content TEXT NOT NULL, -- Point-by-point responses to reviewer feedback
  cover_letter TEXT, -- General response to all reviewers
  paper_version_id INTEGER, -- Reference to new paper version if uploaded
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, round_number)
);

COMMENT ON TABLE pr_author_responses IS 'Author responses to reviewer feedback';
COMMENT ON COLUMN pr_author_responses.response_id IS 'Primary key for the response';
COMMENT ON COLUMN pr_author_responses.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_author_responses.user_id IS 'Foreign key to user_accounts (corresponding author)';
COMMENT ON COLUMN pr_author_responses.round_number IS 'Round number of the response (1, 2, etc.)';
COMMENT ON COLUMN pr_author_responses.response_content IS 'Point-by-point responses to reviewers';
COMMENT ON COLUMN pr_author_responses.cover_letter IS 'General cover letter response';
COMMENT ON COLUMN pr_author_responses.paper_version_id IS 'Reference to revised paper version';
COMMENT ON COLUMN pr_author_responses.submitted_at IS 'When the response was submitted';

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_activity_id ON pr_review_submissions (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_reviewer_id ON pr_review_submissions (reviewer_id);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_round ON pr_review_submissions (round_number);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_initial_assessment ON pr_review_submissions (is_initial_assessment);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_submitted_at ON pr_review_submissions (submitted_at);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_activity_id ON pr_author_responses (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_user_id ON pr_author_responses (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_round ON pr_author_responses (round_number);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_submitted_at ON pr_author_responses (submitted_at);

-- Performance optimization index for progression system queries
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_activity_round 
ON pr_author_responses(activity_id, round_number, submitted_at) 
WHERE response_content IS NOT NULL;

-- =============================================
-- PERFORMANCE OPTIMIZATION INDEXES - PR Activity Page
-- =============================================
-- Following DEVELOPMENT_PRINCIPLES.md: Database as Source of Truth for performance
-- Indexes optimized for the main PR activity data loading JOIN operations

-- Covering index for review submissions JOIN optimization (avoids table lookup)
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_activity_reviewer_covering
ON pr_review_submissions (activity_id, reviewer_id)
INCLUDE (round_number, submitted_at, is_initial_assessment, submission_id, review_content);

-- Covering index for author responses JOIN optimization (avoids table lookup) 
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_activity_round_covering
ON pr_author_responses (activity_id, round_number)
INCLUDE (response_id, user_id, submitted_at, response_content, cover_letter, paper_version_id);

-- Optimized index for review submissions ordering (most common query pattern)
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_activity_round_submitted
ON pr_review_submissions (activity_id, round_number ASC, submitted_at ASC);

-- Triggers for automatic timestamps
CREATE TRIGGER update_pr_review_submissions_updated_at
  BEFORE UPDATE ON pr_review_submissions
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_pr_author_responses_updated_at
  BEFORE UPDATE ON pr_author_responses
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- RLS (Row Level Security) policies

-- Reviews: Only reviewers and corresponding authors can access
ALTER TABLE pr_review_submissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "review_submissions_access" ON pr_review_submissions
  FOR ALL
  TO authenticated
  USING (
    -- Reviewer can access their own reviews
    reviewer_id = (
      SELECT user_id FROM user_accounts 
      WHERE auth_id = (SELECT auth.uid())
    )
    OR
    -- Corresponding author can access reviews for their activity
    EXISTS (
      SELECT 1 FROM pr_activities pa
      WHERE pa.activity_id = pr_review_submissions.activity_id
      AND pa.creator_id = (
        SELECT user_id FROM user_accounts 
        WHERE auth_id = (SELECT auth.uid())
      )
    )
    OR
    -- Other reviewers in the same activity can access reviews in assessment phase
    EXISTS (
      SELECT 1 FROM pr_activities pa
      JOIN pr_reviewer_teams prt ON pa.activity_id = prt.activity_id
      WHERE pa.activity_id = pr_review_submissions.activity_id
      AND pa.current_state = 'assessment'
      AND prt.user_id = (
        SELECT user_id FROM user_accounts 
        WHERE auth_id = (SELECT auth.uid())
      )
      AND prt.status = 'joined'
    )
  );

-- Author responses: Only corresponding author and reviewers can access
ALTER TABLE pr_author_responses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "author_responses_access" ON pr_author_responses
  FOR ALL
  TO authenticated
  USING (
    -- Corresponding author can access their own responses
    user_id = (
      SELECT user_id FROM user_accounts 
      WHERE auth_id = (SELECT auth.uid())
    )
    OR
    -- Reviewers in the same activity can access author responses
    EXISTS (
      SELECT 1 FROM pr_reviewer_teams prt
      WHERE prt.activity_id = pr_author_responses.activity_id
      AND prt.user_id = (
        SELECT user_id FROM user_accounts 
        WHERE auth_id = (SELECT auth.uid())
      )
      AND prt.status = 'joined'
    )
  );