-- =============================================
-- 00000000000008_pr_submissions.sql
-- Peer Review Domain: Reviews and Author Responses
-- =============================================

-- Review submissions table
CREATE TABLE IF NOT EXISTS pr_review_submissions (
  submission_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  round_number INTEGER NOT NULL,
  file_reference TEXT NOT NULL,
  assessment JSONB,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(activity_id, reviewer_id, round_number)
);

COMMENT ON TABLE pr_review_submissions IS 'Files and assessments uploaded by reviewers for each round';
COMMENT ON COLUMN pr_review_submissions.submission_id IS 'Primary key for the submission';
COMMENT ON COLUMN pr_review_submissions.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_review_submissions.reviewer_id IS 'Foreign key to user_accounts (reviewer)';
COMMENT ON COLUMN pr_review_submissions.round_number IS 'Round number of the review';
COMMENT ON COLUMN pr_review_submissions.file_reference IS 'Reference to the review file in storage';
COMMENT ON COLUMN pr_review_submissions.assessment IS 'Free text and structured ratings';
COMMENT ON COLUMN pr_review_submissions.submitted_at IS 'When the review was submitted';

-- Author responses table
CREATE TABLE IF NOT EXISTS pr_author_responses (
  response_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  round_number INTEGER NOT NULL,
  file_reference TEXT NOT NULL,
  comments JSONB,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(activity_id, round_number)
);

COMMENT ON TABLE pr_author_responses IS 'Authors revised manuscripts and responses';
COMMENT ON COLUMN pr_author_responses.response_id IS 'Primary key for the response';
COMMENT ON COLUMN pr_author_responses.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_author_responses.user_id IS 'Foreign key to user_accounts (author)';
COMMENT ON COLUMN pr_author_responses.round_number IS 'Round number of the response';
COMMENT ON COLUMN pr_author_responses.file_reference IS 'Reference to the response file in storage';
COMMENT ON COLUMN pr_author_responses.comments IS 'Per-reviewer point-by-point responses';
COMMENT ON COLUMN pr_author_responses.submitted_at IS 'When the response was submitted';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_activity_id ON pr_review_submissions (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_reviewer_id ON pr_review_submissions (reviewer_id);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_round ON pr_review_submissions (round_number);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_submitted_at ON pr_review_submissions (submitted_at);

CREATE INDEX IF NOT EXISTS idx_pr_author_responses_activity_id ON pr_author_responses (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_user_id ON pr_author_responses (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_round ON pr_author_responses (round_number);
CREATE INDEX IF NOT EXISTS idx_pr_author_responses_submitted_at ON pr_author_responses (submitted_at); 