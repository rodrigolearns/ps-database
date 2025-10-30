-- =============================================
-- 00000000000042_jc_review_submissions.sql
-- JC Activity Domain: Review Submissions
-- =============================================
-- Review submissions for journal club activities (no rounds, simpler than PR)

-- =============================================
-- JC Review Submissions Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_review_submissions (
  submission_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES jc_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  review_content TEXT NOT NULL,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(activity_id, reviewer_id)  -- One review per reviewer (no rounds)
);

COMMENT ON TABLE jc_review_submissions IS 'Review submissions for JC activities (no rounds, one review per reviewer)';
COMMENT ON COLUMN jc_review_submissions.submission_id IS 'Primary key';
COMMENT ON COLUMN jc_review_submissions.activity_id IS 'Foreign key to jc_activities';
COMMENT ON COLUMN jc_review_submissions.reviewer_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN jc_review_submissions.review_content IS 'Markdown review content';
COMMENT ON COLUMN jc_review_submissions.submitted_at IS 'When review was submitted';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_jc_review_submissions_activity ON jc_review_submissions (activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_review_submissions_reviewer ON jc_review_submissions (reviewer_id);
CREATE INDEX IF NOT EXISTS idx_jc_review_submissions_submitted ON jc_review_submissions (submitted_at DESC);

-- Covering index
CREATE INDEX IF NOT EXISTS idx_jc_review_submissions_activity_covering
ON jc_review_submissions (activity_id)
INCLUDE (submission_id, reviewer_id, review_content, submitted_at, created_at);

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_jc_review_submissions_updated_at
  BEFORE UPDATE ON jc_review_submissions
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE jc_review_submissions ENABLE ROW LEVEL SECURITY;

-- Participants can see all reviews in their activities
CREATE POLICY jc_review_submissions_select_participant ON jc_review_submissions
  FOR SELECT
  USING (
    reviewer_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM jc_participants jp
      WHERE jp.activity_id = jc_review_submissions.activity_id
      AND jp.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify
CREATE POLICY jc_review_submissions_modify_service_role_only ON jc_review_submissions
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

