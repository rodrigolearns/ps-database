-- =============================================
-- 00000000000021_published_content_access.sql
-- Allow public access to published activity content
-- =============================================

-- Update RLS policy for pr_review_submissions to allow access to published activities
DROP POLICY IF EXISTS "review_submissions_access" ON pr_review_submissions;
CREATE POLICY "review_submissions_access" ON pr_review_submissions
  FOR ALL
  TO authenticated
  USING (
    -- Anyone can access reviews for published activities
    EXISTS (
      SELECT 1 FROM pr_activities pa
      WHERE pa.activity_id = pr_review_submissions.activity_id
      AND pa.current_state = 'published_on_ps'
    )
    OR
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

-- Update RLS policy for pr_author_responses to allow access to published activities
DROP POLICY IF EXISTS "author_responses_access" ON pr_author_responses;
CREATE POLICY "author_responses_access" ON pr_author_responses
  FOR ALL
  TO authenticated
  USING (
    -- Anyone can access author responses for published activities
    EXISTS (
      SELECT 1 FROM pr_activities pa
      WHERE pa.activity_id = pr_author_responses.activity_id
      AND pa.current_state = 'published_on_ps'
    )
    OR
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

-- Update RLS policy for pr_assessments to allow access to published activities
DROP POLICY IF EXISTS "assessment_participant_access" ON pr_assessments;
CREATE POLICY "assessment_participant_access" ON pr_assessments
  FOR ALL
  TO authenticated
  USING (
    -- Anyone can access assessments for published activities
    EXISTS (
      SELECT 1 FROM pr_activities pa
      WHERE pa.activity_id = pr_assessments.activity_id
      AND pa.current_state = 'published_on_ps'
    )
    OR
    -- Allow reviewers who are part of the reviewer team
    EXISTS (
      SELECT 1 FROM pr_reviewer_teams prt
      WHERE prt.activity_id = pr_assessments.activity_id
      AND prt.user_id = (
        SELECT user_id FROM user_accounts 
        WHERE auth_id = (SELECT auth.uid())
      )
      AND prt.status IN ('joined', 'locked_in')
    )
    OR
    -- Allow paper contributors (authors) of the associated paper
    EXISTS (
      SELECT 1 FROM pr_activities pra
      JOIN papers p ON p.paper_id = pra.paper_id
      JOIN paper_contributors pc ON pc.paper_id = p.paper_id
      WHERE pra.activity_id = pr_assessments.activity_id
      AND pc.user_id = (
        SELECT user_id FROM user_accounts 
        WHERE auth_id = (SELECT auth.uid())
      )
    )
  );

-- Add comments explaining the new public access rules
COMMENT ON POLICY "review_submissions_access" ON pr_review_submissions IS 
'Allows participant access during review and public access after publication';

COMMENT ON POLICY "author_responses_access" ON pr_author_responses IS 
'Allows participant access during review and public access after publication';

COMMENT ON POLICY "assessment_participant_access" ON pr_assessments IS 
'Allows participant access during review and public access after publication';