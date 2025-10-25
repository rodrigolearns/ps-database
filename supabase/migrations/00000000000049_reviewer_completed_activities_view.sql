-- Migration: Create reviewer_completed_activities view
-- Purpose: Optimized view for reviewers to see their completed activities with rankings
-- SPRINT-7: Uses activity_stage_state for current_stage_key

-- Create view for completed review activities
-- "Completed" means: activity reached publication_choice or terminal publication state
CREATE OR REPLACE VIEW reviewer_completed_activities AS
SELECT 
  a.activity_id,
  a.activity_uuid,
  a.paper_id,
  p.title AS paper_title,
  r.joined_at,
  -- Use stage_entered_at from activity_stage_state when stage is publication_choice or beyond
  CASE 
    WHEN ass.current_stage_key IN ('publication_choice', 'published_on_ps', 'submitted_externally', 'made_private') 
    THEN ass.stage_entered_at
    ELSE NULL
  END AS completed_at,
  -- Rankings data from pr_reviewer_rankings
  rr.final_rank,
  rr.tokens_awarded,
  -- SPRINT-7: current stage from activity_stage_state
  ass.current_stage_key AS current_state,
  r.user_id
FROM pr_activities a
-- Join with activity stage state (SPRINT-7)
INNER JOIN activity_stage_state ass ON a.activity_id = ass.activity_id
-- Join with papers
INNER JOIN papers p ON a.paper_id = p.paper_id
-- Join with reviewers
INNER JOIN pr_reviewers r ON a.activity_id = r.activity_id
-- Left join with rankings (may not exist if not yet ranked)
LEFT JOIN pr_reviewer_rankings rr ON a.activity_id = rr.activity_id AND r.user_id = rr.reviewer_id
WHERE 
  -- Only include completed activities (publication_choice or beyond)
  ass.current_stage_key IN ('publication_choice', 'published_on_ps', 'submitted_externally', 'made_private')
  -- Only locked-in reviewers (who actually submitted reviews)
  AND r.status = 'locked_in';

-- Add comment
COMMENT ON VIEW reviewer_completed_activities IS 
'View of completed review activities for reviewers. Includes activities that reached publication_choice or beyond, with ranking and token data.';

