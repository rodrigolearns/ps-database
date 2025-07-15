-- =====================================================
-- Peer Review State Management Migration
-- =====================================================

-- Add stage_deadline column to pr_activities if not exists
ALTER TABLE pr_activities 
ADD COLUMN IF NOT EXISTS stage_deadline TIMESTAMPTZ;

-- Create processing log table for service monitoring
CREATE TABLE IF NOT EXISTS pr_processing_log (
  log_id SERIAL PRIMARY KEY,
  activity_id INTEGER REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  process_type TEXT NOT NULL, -- 'state_check', 'deadline_check', 'condition_eval'
  result TEXT NOT NULL, -- 'no_change', 'transitioned', 'error', 'deadline_expired'
  details JSONB DEFAULT '{}'::jsonb,
  processing_time_ms INTEGER,
  processed_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for performance (pr_state_log indexes are already created in 00000000000010_pr_core.sql)
CREATE INDEX IF NOT EXISTS idx_pr_processing_log_activity_id ON pr_processing_log(activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_processing_log_processed_at ON pr_processing_log(processed_at);
CREATE INDEX IF NOT EXISTS idx_pr_activities_stage_deadline ON pr_activities(stage_deadline) WHERE stage_deadline IS NOT NULL;

-- Function to log state changes automatically
CREATE OR REPLACE FUNCTION log_state_change()
RETURNS TRIGGER AS $$
BEGIN
  -- Only log if state actually changed
  IF OLD.current_state IS DISTINCT FROM NEW.current_state THEN
    INSERT INTO pr_state_log (
      activity_id,
      old_state,
      new_state,
      reason
    ) VALUES (
      NEW.activity_id,
      OLD.current_state,
      NEW.current_state,
      COALESCE(NEW.state_change_reason, 'System transition')
    );
    
    -- Clear the reason field after logging
    NEW.state_change_reason := NULL;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add temporary column for state change reasons
ALTER TABLE pr_activities 
ADD COLUMN IF NOT EXISTS state_change_reason TEXT;

-- Create trigger for automatic state logging
DROP TRIGGER IF EXISTS trigger_log_state_change ON pr_activities;
CREATE TRIGGER trigger_log_state_change
  AFTER UPDATE ON pr_activities
  FOR EACH ROW
  EXECUTE FUNCTION log_state_change();

-- Function to get active activities for processing
CREATE OR REPLACE FUNCTION get_active_activities()
RETURNS TABLE (
  activity_id INTEGER,
  current_state activity_state,
  stage_deadline TIMESTAMPTZ,
  template_id INTEGER,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    pa.activity_id,
    pa.current_state,
    pa.stage_deadline,
    pa.template_id,
    pa.created_at,
    pa.updated_at
  FROM pr_activities pa
  WHERE pa.current_state != 'completed'
  ORDER BY pa.created_at;
END;
$$ LANGUAGE plpgsql;

-- Function to check if reviewer team is complete
CREATE OR REPLACE FUNCTION check_reviewer_team_complete(p_activity_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
  joined_count INTEGER;
  required_count INTEGER;
BEGIN
  -- Get joined reviewer count and required count
  SELECT 
    COUNT(*) FILTER (WHERE prt.status = 'joined'),
    pt.reviewer_count
  INTO joined_count, required_count
  FROM pr_activities pa
  JOIN pr_templates pt ON pa.template_id = pt.template_id
  LEFT JOIN pr_reviewer_teams prt ON pa.activity_id = prt.activity_id
  WHERE pa.activity_id = p_activity_id
  GROUP BY pt.reviewer_count;
  
  -- Return true if we have enough reviewers
  RETURN COALESCE(joined_count, 0) >= COALESCE(required_count, 0);
END;
$$ LANGUAGE plpgsql;

-- Function to check if all reviews are submitted for a round
CREATE OR REPLACE FUNCTION check_all_reviews_submitted(p_activity_id INTEGER, p_round INTEGER DEFAULT 1)
RETURNS BOOLEAN AS $$
DECLARE
  submitted_count INTEGER;
  required_count INTEGER;
BEGIN
  -- Get required reviewer count from template
  SELECT pt.reviewer_count
  INTO required_count
  FROM pr_activities pa
  JOIN pr_templates pt ON pa.template_id = pt.template_id
  WHERE pa.activity_id = p_activity_id;
  
  -- Get count of locked-in reviewers who have submitted for this round
  SELECT COUNT(DISTINCT prs.reviewer_id)
  INTO submitted_count
  FROM pr_reviewer_teams prt
  JOIN pr_review_submissions prs ON prt.user_id = prs.reviewer_id 
    AND prs.activity_id = p_activity_id 
    AND prs.round_number = p_round
  WHERE prt.activity_id = p_activity_id 
    AND prt.status = 'locked_in';
  
  -- Return true if all required reviewers have submitted
  RETURN COALESCE(submitted_count, 0) >= COALESCE(required_count, 0) 
    AND COALESCE(required_count, 0) > 0;
END;
$$ LANGUAGE plpgsql;

-- Function to check if author response is submitted for a round
CREATE OR REPLACE FUNCTION check_author_response_submitted(p_activity_id INTEGER, p_round INTEGER DEFAULT 1)
RETURNS BOOLEAN AS $$
DECLARE
  response_count INTEGER;
BEGIN
  -- Check if author has submitted response for the round
  SELECT COUNT(*)
  INTO response_count
  FROM pr_author_responses par
  WHERE par.activity_id = p_activity_id 
    AND par.round_number = p_round;
  
  RETURN response_count > 0;
END;
$$ LANGUAGE plpgsql;

-- Function to update activity state with logging (improved version)
CREATE OR REPLACE FUNCTION update_activity_state(
  p_activity_id INTEGER,
  p_new_state activity_state,
  p_reason TEXT DEFAULT 'System transition',
  p_deadline_days INTEGER DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_current_state activity_state;
  v_new_deadline TIMESTAMPTZ;
  v_rows_updated INTEGER;
BEGIN
  -- Get current state
  SELECT current_state INTO v_current_state
  FROM pr_activities
  WHERE activity_id = p_activity_id;
  
  -- Check if activity exists
  IF v_current_state IS NULL THEN
    RAISE NOTICE 'Activity % not found', p_activity_id;
    RETURN FALSE;
  END IF;
  
  -- Skip if already in target state (prevents duplicates)
  IF v_current_state = p_new_state THEN
    RAISE NOTICE 'Activity % already in state %', p_activity_id, p_new_state;
    RETURN TRUE;
  END IF;
  
  -- Check if this exact transition already exists in the log (additional safety)
  IF EXISTS (
    SELECT 1 FROM pr_state_log 
    WHERE activity_id = p_activity_id 
    AND old_state = v_current_state 
    AND new_state = p_new_state
    AND changed_at > NOW() - INTERVAL '1 minute' -- Within the last minute
  ) THEN
    RAISE NOTICE 'Activity % transition from % to % already logged recently', 
      p_activity_id, v_current_state, p_new_state;
    RETURN TRUE;
  END IF;
  
  -- Calculate new deadline if specified
  IF p_deadline_days IS NOT NULL THEN
    v_new_deadline := NOW() + (p_deadline_days || ' days')::INTERVAL;
  END IF;
  
  -- Update activity state
  UPDATE pr_activities 
  SET 
    current_state = p_new_state,
    stage_deadline = v_new_deadline,
    updated_at = NOW()
  WHERE activity_id = p_activity_id;
  
  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;
  
  -- Log the state change directly
  INSERT INTO pr_state_log (
    activity_id,
    old_state,
    new_state,
    reason,
    changed_at
  ) VALUES (
    p_activity_id,
    v_current_state,
    p_new_state,
    p_reason,
    NOW()
  );
  
  RAISE NOTICE 'Activity % transitioned from % to % (reason: %)', 
    p_activity_id, v_current_state, p_new_state, p_reason;
  
  RETURN v_rows_updated > 0;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Error updating activity % state: %', p_activity_id, SQLERRM;
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Function to get activities with expired deadlines
CREATE OR REPLACE FUNCTION get_expired_activities()
RETURNS TABLE (
  activity_id INTEGER,
  current_state activity_state,
  stage_deadline TIMESTAMPTZ,
  hours_overdue NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    pa.activity_id,
    pa.current_state,
    pa.stage_deadline,
    EXTRACT(EPOCH FROM (NOW() - pa.stage_deadline)) / 3600 as hours_overdue
  FROM pr_activities pa
  WHERE pa.stage_deadline IS NOT NULL 
    AND pa.stage_deadline < NOW()
    AND pa.current_state != 'completed'
  ORDER BY pa.stage_deadline;
END;
$$ LANGUAGE plpgsql;

-- Insert initial state log entries for existing activities
INSERT INTO pr_state_log (activity_id, old_state, new_state, reason, changed_at)
SELECT 
  activity_id,
  NULL,
  current_state,
  'Initial state (migration)',
  created_at
FROM pr_activities
WHERE NOT EXISTS (
  SELECT 1 FROM pr_state_log psl 
  WHERE psl.activity_id = pr_activities.activity_id
);

-- Grant necessary permissions
GRANT SELECT, INSERT, UPDATE ON pr_state_log TO authenticated;
GRANT SELECT, INSERT ON pr_processing_log TO authenticated;
GRANT EXECUTE ON FUNCTION get_active_activities() TO authenticated;
GRANT EXECUTE ON FUNCTION check_reviewer_team_complete(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION check_all_reviews_submitted(INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION check_author_response_submitted(INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION update_activity_state(INTEGER, activity_state, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_expired_activities() TO authenticated;
