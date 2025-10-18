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
  template_name TEXT,
  reviewer_count INTEGER,
  current_reviewers_count BIGINT,
  escrow_balance INTEGER,
  posted_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    pa.activity_id,
    pa.activity_uuid,
    pa.paper_id,
    p.title as paper_title,
    pt.name as template_name,
    pt.reviewer_count,
    COUNT(DISTINCT pr.user_id) as current_reviewers_count,
    pa.escrow_balance,
    pa.posted_at
  FROM pr_activities pa
  JOIN papers p ON pa.paper_id = p.paper_id
  JOIN pr_templates pt ON pa.template_id = pt.template_id
  LEFT JOIN pr_reviewers pr ON pa.activity_id = pr.activity_id AND pr.status IN ('joined', 'locked_in')
  WHERE pa.escrow_balance > 0
    AND pa.completed_at IS NULL
    -- Exclude if user is paper contributor
    AND NOT EXISTS (
      SELECT 1 FROM paper_contributors pc
      WHERE pc.paper_id = pa.paper_id
      AND pc.user_id = p_user_id
    )
    -- Exclude if user is already a reviewer
    AND NOT EXISTS (
      SELECT 1 FROM pr_reviewers pr2
      WHERE pr2.activity_id = pa.activity_id
      AND pr2.user_id = p_user_id
    )
  GROUP BY pa.activity_id, pa.activity_uuid, pa.paper_id, p.title, pt.name, pt.reviewer_count, pa.escrow_balance, pa.posted_at
  HAVING COUNT(DISTINCT pr.user_id) < pt.reviewer_count  -- Exclude full teams
  ORDER BY pa.posted_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION get_available_pr_activities_for_user IS 'Gets PR activities available for user to join (excludes own papers and full teams)';

GRANT EXECUTE ON FUNCTION get_available_pr_activities_for_user TO authenticated;

