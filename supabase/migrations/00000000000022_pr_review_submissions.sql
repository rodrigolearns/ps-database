-- =============================================
-- 00000000000022_pr_review_submissions.sql
-- PR Activity Domain: Review Submissions
-- =============================================
-- Individual markdown reviews submitted by reviewers

-- =============================================
-- PR Review Submissions Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_review_submissions (
  submission_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  round_number INTEGER NOT NULL,
  review_content TEXT NOT NULL,
  is_initial_assessment BOOLEAN DEFAULT false,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, reviewer_id, round_number)
);

COMMENT ON TABLE pr_review_submissions IS 'Individual markdown reviews submitted by reviewers';
COMMENT ON COLUMN pr_review_submissions.submission_id IS 'Primary key';
COMMENT ON COLUMN pr_review_submissions.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_review_submissions.reviewer_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN pr_review_submissions.round_number IS 'Round number (1, 2, 3, etc.)';
COMMENT ON COLUMN pr_review_submissions.review_content IS 'Markdown review content';
COMMENT ON COLUMN pr_review_submissions.is_initial_assessment IS 'True for 72-hour commitment assessments';
COMMENT ON COLUMN pr_review_submissions.submitted_at IS 'When the review was submitted';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_activity ON pr_review_submissions (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_reviewer ON pr_review_submissions (reviewer_id);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_round ON pr_review_submissions (round_number);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_submitted ON pr_review_submissions (submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_activity_round ON pr_review_submissions (activity_id, round_number);

-- Covering index for review lookups
CREATE INDEX IF NOT EXISTS idx_pr_review_submissions_activity_reviewer_covering
ON pr_review_submissions (activity_id, reviewer_id)
INCLUDE (round_number, submitted_at, is_initial_assessment, submission_id, review_content);

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_pr_review_submissions_updated_at
  BEFORE UPDATE ON pr_review_submissions
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================
-- Reviewers see own reviews always
-- Authors see all reviews
-- During assessment, all reviewers can see all reviews

ALTER TABLE pr_review_submissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY pr_review_submissions_select_own_or_participant ON pr_review_submissions
  FOR SELECT
  USING (
    -- Reviewer can see own review
    reviewer_id = (SELECT auth_user_id()) OR
    -- Activity participants can see reviews
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_review_submissions.activity_id
      AND pap.user_id = (SELECT auth_user_id())
      AND pap.role IN ('corresponding_author', 'spectating_author', 'spectating_admin')
    ) OR
    -- During assessment, all reviewers can see all reviews
    EXISTS (
      SELECT 1 
      FROM pr_activity_permissions pap
      JOIN activity_stage_state ass ON ass.activity_id = pap.activity_id AND ass.activity_type = 'pr-activity'
      WHERE pap.activity_id = pr_review_submissions.activity_id
      AND pap.user_id = (SELECT auth_user_id())
      AND pap.role = 'reviewer'
      AND ass.current_stage_key = 'assessment'
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can insert/update (via API routes)
CREATE POLICY pr_review_submissions_modify_service_role_only ON pr_review_submissions
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_review_submissions_select_own_or_participant ON pr_review_submissions IS
  'Reviewers see own, authors see all, reviewers see all during assessment stage';

