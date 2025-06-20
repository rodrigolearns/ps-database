-- =============================================
-- 00000000000008_pr_submissions.sql
-- Peer Review Domain: Reviews and Author Responses (Simplified)
-- =============================================

-- Review submissions table
CREATE TABLE IF NOT EXISTS pr_review_submissions (
  submission_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  round_number INTEGER NOT NULL,
  review_content TEXT NOT NULL, -- Pure text review, no file uploads
  is_initial_evaluation BOOLEAN DEFAULT false, -- For 72-hour commitment check
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, reviewer_id, round_number)
);

COMMENT ON TABLE pr_review_submissions IS 'Text-based reviews submitted by reviewers';
COMMENT ON COLUMN pr_review_submissions.submission_id IS 'Primary key for the submission';
COMMENT ON COLUMN pr_review_submissions.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_review_submissions.reviewer_id IS 'Foreign key to user_accounts (reviewer)';
COMMENT ON COLUMN pr_review_submissions.round_number IS 'Round number of the review (0 = initial evaluation)';
COMMENT ON COLUMN pr_review_submissions.review_content IS 'Qualitative text review content';
COMMENT ON COLUMN pr_review_submissions.is_initial_evaluation IS 'True for 72-hour commitment evaluations';
COMMENT ON COLUMN pr_review_submissions.submitted_at IS 'When the review was submitted';

-- Author responses table
CREATE TABLE IF NOT EXISTS pr_author_responses (
  response_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  round_number INTEGER NOT NULL,
  response_content TEXT NOT NULL, -- Point-by-point responses
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
COMMENT ON COLUMN pr_author_responses.round_number IS 'Round number of the response';
COMMENT ON COLUMN pr_author_responses.response_content IS 'Point-by-point responses to reviewers';
COMMENT ON COLUMN pr_author_responses.cover_letter IS 'General cover letter response';
COMMENT ON COLUMN pr_author_responses.paper_version_id IS 'Reference to revised paper version';
COMMENT ON COLUMN pr_author_responses.submitted_at IS 'When the response was submitted';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_activity_id ON pr_review_submissions (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_reviewer_id ON pr_review_submissions (reviewer_id);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_round ON pr_review_submissions (round_number);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_initial_eval ON pr_review_submissions (is_initial_evaluation);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_submitted_at ON pr_review_submissions (submitted_at);

CREATE INDEX IF NOT EXISTS idx_pr_author_responses_activity_id ON pr_author_responses (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_user_id ON pr_author_responses (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_round ON pr_author_responses (round_number);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_submitted_at ON pr_author_responses (submitted_at);

-- Triggers
CREATE TRIGGER update_pr_review_submissions_updated_at
  BEFORE UPDATE ON pr_review_submissions
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_pr_author_responses_updated_at
  BEFORE UPDATE ON pr_author_responses
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at(); 