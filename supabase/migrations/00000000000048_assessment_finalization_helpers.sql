-- Migration: Assessment Finalization Helper Functions
-- Purpose: Functions for managing assessment finalization and content change detection

-- Function: Reset all finalization when assessment content changes
-- Used by check-content-change endpoint to invalidate finalization when reviewers edit the pad
CREATE OR REPLACE FUNCTION reset_all_finalization_on_content_change(
  p_activity_id INTEGER
)
RETURNS VOID AS $$
BEGIN
  -- Delete all finalization records for this activity
  -- This forces all reviewers to re-finalize after content changes
  DELETE FROM pr_finalization_status
  WHERE activity_id = p_activity_id;
  
  -- Log the reset event
  RAISE NOTICE 'Reset all finalization for activity % due to content change', p_activity_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION reset_all_finalization_on_content_change IS 
'Resets all reviewer finalization when assessment content changes. Called by check-content-change endpoint.';

-- Grant execute permission
GRANT EXECUTE ON FUNCTION reset_all_finalization_on_content_change TO authenticated;

