-- =============================================
-- 00000000000024_completed_reviews_view.sql
-- Optimized view for completed review activities
-- =============================================

-- Create a materialized view for completed review activities
-- This provides better performance for the reviewing dashboard
CREATE OR REPLACE VIEW reviewer_completed_activities AS
SELECT 
  rt.team_id,
  rt.activity_id,
  rt.user_id,
  rt.status AS reviewer_status,
  rt.joined_at,
  rt.locked_in_at,
  pa.activity_uuid,
  pa.current_state,
  pa.paper_id,
  p.title AS paper_title,
  p.created_at AS paper_created_at,
  rr.final_rank,
  rr.tokens_awarded,
  rr.ranked_at AS completed_at
FROM pr_reviewer_teams rt
INNER JOIN pr_activities pa ON rt.activity_id = pa.activity_id
INNER JOIN papers p ON pa.paper_id = p.paper_id
LEFT JOIN pr_reviewer_rankings rr ON rt.activity_id = rr.activity_id AND rt.user_id = rr.reviewer_id
WHERE 
  rt.status IN ('joined', 'locked_in')
  AND pa.current_state IN ('publication_choice', 'published_on_ps', 'submitted_externally', 'made_private');

COMMENT ON VIEW reviewer_completed_activities IS 'Optimized view for completed review activities with rankings';

-- Create indexes on the underlying tables for better view performance
-- These complement existing indexes and optimize the JOIN operations

-- Composite index for pr_activities to speed up the WHERE clause
CREATE INDEX IF NOT EXISTS idx_pr_activities_state_completed 
ON pr_activities (current_state) 
WHERE current_state IN ('publication_choice', 'published_on_ps', 'submitted_externally', 'made_private');

-- Composite index for pr_reviewer_rankings to optimize the LEFT JOIN
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_rankings_activity_reviewer 
ON pr_reviewer_rankings (activity_id, reviewer_id)
INCLUDE (final_rank, tokens_awarded, ranked_at);

-- Grant permissions
GRANT SELECT ON reviewer_completed_activities TO authenticated;

