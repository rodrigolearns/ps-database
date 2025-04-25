-- =============================================
-- 00000000000022_pr_moderation.sql
-- Deadlines, reminders, and moderation events
-- =============================================

-- Tracks scheduled deadline events and their status
CREATE TABLE IF NOT EXISTS deadline_events (
  event_id      SERIAL PRIMARY KEY,
  activity_id   INTEGER NOT NULL
    REFERENCES peer_review_activities(activity_id) ON DELETE CASCADE,
  stage         TEXT NOT NULL,            -- e.g. 'review_round_1', 'author_response', etc.
  due_at        TIMESTAMPTZ NOT NULL,
  triggered_at  TIMESTAMPTZ,              -- when handler ran
  status        TEXT NOT NULL DEFAULT 'pending'  -- 'pending','reminded','escalated','completed'
);
COMMENT ON TABLE deadline_events IS 'Scheduled reminders/escalations for each stage deadline';

-- Function to schedule a deadline event
CREATE OR REPLACE FUNCTION schedule_deadline_event(
  p_activity_id INTEGER,
  p_stage TEXT,
  p_days_from_now INTEGER
)
RETURNS BOOLEAN AS $$
DECLARE
  v_due_at TIMESTAMPTZ;
BEGIN
  v_due_at := NOW() + (p_days_from_now || ' days')::INTERVAL;
  
  -- Insert the deadline event
  INSERT INTO deadline_events (
    activity_id, stage, due_at
  ) VALUES (
    p_activity_id, p_stage, v_due_at
  );
  
  -- Update the activity's stage deadline
  UPDATE peer_review_activities
  SET stage_deadline = v_due_at
  WHERE activity_id = p_activity_id;
  
  RETURN TRUE;
EXCEPTION
  WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to advance activity to next stage
CREATE OR REPLACE FUNCTION advance_activity_stage(
  p_activity_id INTEGER,
  p_next_stage activity_state,
  p_days_for_deadline INTEGER DEFAULT 14
)
RETURNS BOOLEAN AS $$
BEGIN
  -- Update the activity's current state
  UPDATE peer_review_activities
  SET current_state = p_next_stage
  WHERE activity_id = p_activity_id;
  
  -- Mark current deadline as completed
  UPDATE deadline_events
  SET status = 'completed',
      triggered_at = NOW()
  WHERE activity_id = p_activity_id
    AND status = 'pending';
  
  -- Schedule the next deadline
  PERFORM schedule_deadline_event(p_activity_id, p_next_stage::TEXT, p_days_for_deadline);
  
  RETURN TRUE;
EXCEPTION
  WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
