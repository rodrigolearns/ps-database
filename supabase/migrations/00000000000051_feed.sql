-- =============================================
-- 00000000000051_feed.sql
-- Platform Feature: Activity Feed
-- =============================================
-- Feed system for discovering activities

-- =============================================
-- Feed Optimization Indexes
-- =============================================
-- Index for PR activity feed queries (funded activities ordered by posting date)
CREATE INDEX IF NOT EXISTS idx_pr_activities_feed_ordered 
ON pr_activities (escrow_balance, posted_at DESC) 
WHERE escrow_balance > 0 AND completed_at IS NULL;

-- Index for checking if user is already a reviewer
CREATE INDEX IF NOT EXISTS idx_pr_reviewers_user_activity_lookup 
ON pr_reviewers (user_id, activity_id);

-- Index for template joins in feed queries
CREATE INDEX IF NOT EXISTS idx_pr_activities_template_feed
ON pr_activities (template_id, escrow_balance, posted_at DESC)
WHERE escrow_balance > 0 AND completed_at IS NULL;

-- =============================================
-- Feed Helper Functions
-- =============================================

-- Get available PR activities for user (excludes activities where user is already involved)
-- This function performs all filtering in the database for optimal performance
CREATE OR REPLACE FUNCTION get_available_pr_activities_for_user(
  p_user_id INTEGER,
  p_limit INTEGER DEFAULT 20,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  activity_id INTEGER,
  activity_uuid UUID,
  paper_id INTEGER,
  paper_title TEXT,
  template_id INTEGER,
  template_name TEXT,
  reviewer_count INTEGER,
  current_reviewers_count BIGINT,
  escrow_balance INTEGER,
  funding_amount INTEGER,
  posted_at TIMESTAMPTZ,
  creator_id INTEGER
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    pa.activity_id,
    pa.activity_uuid,
    pa.paper_id,
    p.title as paper_title,
    pa.template_id,
    pt.name as template_name,
    pt.reviewer_count,
    COUNT(DISTINCT pr.user_id) as current_reviewers_count,
    pa.escrow_balance,
    pa.funding_amount,
    pa.posted_at,
    pa.creator_id
  FROM pr_activities pa
  JOIN papers p ON pa.paper_id = p.paper_id
  JOIN pr_templates pt ON pa.template_id = pt.template_id
  LEFT JOIN pr_reviewers pr ON pa.activity_id = pr.activity_id AND pr.status IN ('joined', 'locked_in')
  WHERE pa.escrow_balance > 0
    AND pa.completed_at IS NULL
    AND pa.creator_id != p_user_id
    -- Exclude if user is paper contributor (author or co-author)
    AND NOT EXISTS (
      SELECT 1 FROM paper_contributors pc
      WHERE pc.paper_id = pa.paper_id
      AND pc.user_id = p_user_id
    )
    -- Exclude if user is already an active reviewer (joined or locked_in, not removed)
    AND NOT EXISTS (
      SELECT 1 FROM pr_reviewers pr2
      WHERE pr2.activity_id = pa.activity_id
      AND pr2.user_id = p_user_id
      AND pr2.status IN ('joined', 'locked_in')
    )
  GROUP BY pa.activity_id, pa.activity_uuid, pa.paper_id, p.title, pa.template_id, pt.name, pt.reviewer_count, pa.escrow_balance, pa.funding_amount, pa.posted_at, pa.creator_id
  HAVING COUNT(DISTINCT pr.user_id) < pt.reviewer_count  -- Exclude full teams
  ORDER BY pa.posted_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION get_available_pr_activities_for_user IS 
  'Gets PR activities available for user to join. All filtering done in database for optimal performance.';

GRANT EXECUTE ON FUNCTION get_available_pr_activities_for_user TO authenticated;
