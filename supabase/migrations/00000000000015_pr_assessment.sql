-- =============================================
-- 00000000000018_pr_assessment.sql
-- Collaborative Assessment System with Turn-Based Edit Locking
-- =============================================

-- 1. Main Collaborative Assessments Table
-- Stores collaborative assessment content with turn-based edit locking
CREATE TABLE IF NOT EXISTS pr_assessments (
  assessment_id           SERIAL PRIMARY KEY,
  activity_id             INTEGER NOT NULL
    REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  assessment_content      TEXT NOT NULL DEFAULT '',
  is_finalized            BOOLEAN NOT NULL DEFAULT FALSE,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finalized_at            TIMESTAMPTZ NULL,
  finalized_by            INTEGER NULL
    REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  
  -- Turn-based edit lock fields
  current_editor_id       INTEGER NULL
    REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  edit_session_started_at TIMESTAMPTZ NULL,
  edit_session_expires_at TIMESTAMPTZ NULL,
  draft_content           TEXT NULL,  -- Auto-save backup
  
  UNIQUE(activity_id)
);
COMMENT ON TABLE pr_assessments IS 'Collaborative assessments with turn-based edit locking';
COMMENT ON COLUMN pr_assessments.assessment_id IS 'Primary key for the assessment';
COMMENT ON COLUMN pr_assessments.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_assessments.assessment_content IS 'Collaborative markdown assessment content';
COMMENT ON COLUMN pr_assessments.is_finalized IS 'Whether all reviewers have finalized the assessment';
COMMENT ON COLUMN pr_assessments.current_editor_id IS 'User currently editing (turn-based locking)';
COMMENT ON COLUMN pr_assessments.edit_session_started_at IS 'When current edit session started';
COMMENT ON COLUMN pr_assessments.edit_session_expires_at IS 'When current edit session expires';
COMMENT ON COLUMN pr_assessments.draft_content IS 'Auto-save backup content';

-- 2. Reviewer Finalization Status Table
-- Track which reviewers have approved the collaborative assessment
CREATE TABLE IF NOT EXISTS pr_finalization_status (
  status_id        SERIAL PRIMARY KEY,
  activity_id      INTEGER NOT NULL
    REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  reviewer_id      INTEGER NULL
    REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  is_finalized     BOOLEAN NOT NULL DEFAULT FALSE,
  finalized_at     TIMESTAMPTZ NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(activity_id, reviewer_id)
);
COMMENT ON TABLE pr_finalization_status IS 'Track individual reviewer approval of collaborative assessment';
COMMENT ON COLUMN pr_finalization_status.status_id IS 'Primary key for the status';
COMMENT ON COLUMN pr_finalization_status.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_finalization_status.reviewer_id IS 'Foreign key to user_accounts (reviewer)';
COMMENT ON COLUMN pr_finalization_status.is_finalized IS 'Whether this reviewer has finalized';
COMMENT ON COLUMN pr_finalization_status.finalized_at IS 'When this reviewer finalized';

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_pr_assessments_activity
  ON pr_assessments(activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_assessments_editor
  ON pr_assessments(current_editor_id);
CREATE INDEX IF NOT EXISTS idx_pr_assessments_expires
  ON pr_assessments(edit_session_expires_at);
CREATE INDEX IF NOT EXISTS idx_pr_finalization_activity
  ON pr_finalization_status(activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_finalization_reviewer
  ON pr_finalization_status(reviewer_id);

-- 3. Functions for turn-based edit lock management

-- Function to automatically release expired edit locks
CREATE OR REPLACE FUNCTION release_expired_edit_locks()
RETURNS void AS $$
BEGIN
  UPDATE pr_assessments
  SET 
    current_editor_id = NULL,
    edit_session_started_at = NULL,
    edit_session_expires_at = NULL
  WHERE edit_session_expires_at < NOW()
    AND current_editor_id IS NOT NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION release_expired_edit_locks() IS 'Automatically release expired assessment edit locks';

-- Function to acquire turn-based edit lock
CREATE OR REPLACE FUNCTION acquire_assessment_edit_lock(
  p_activity_id INTEGER,
  p_user_id INTEGER,
  p_lock_duration_hours INTEGER DEFAULT 1
)
RETURNS JSONB AS $$
DECLARE
  v_assessment_id INTEGER;
  v_current_editor INTEGER;
  v_expires_at TIMESTAMPTZ;
  v_lock_acquired BOOLEAN := FALSE;
BEGIN
  -- Clean up expired locks first
  PERFORM release_expired_edit_locks();
  
  -- Get or create assessment
  SELECT assessment_id, current_editor_id, edit_session_expires_at
  INTO v_assessment_id, v_current_editor, v_expires_at
  FROM pr_assessments
  WHERE activity_id = p_activity_id;
  
  -- Create assessment if it doesn't exist
  IF v_assessment_id IS NULL THEN
    INSERT INTO pr_assessments (activity_id, assessment_content)
    VALUES (p_activity_id, '')
    RETURNING assessment_id INTO v_assessment_id;
    v_current_editor := NULL;
  END IF;
  
  -- Check if lock is available (turn-based: only one user can edit at a time)
  IF v_current_editor IS NULL OR v_current_editor = p_user_id THEN
    -- Acquire or extend lock
    UPDATE pr_assessments
    SET 
      current_editor_id = p_user_id,
      edit_session_started_at = NOW(),
      edit_session_expires_at = NOW() + (p_lock_duration_hours || ' hours')::INTERVAL,
      updated_at = NOW()
    WHERE activity_id = p_activity_id;
    
    v_lock_acquired := TRUE;
    v_expires_at := NOW() + (p_lock_duration_hours || ' hours')::INTERVAL;
  END IF;
  
  RETURN jsonb_build_object(
    'lockAcquired', v_lock_acquired,
    'expiresAt', v_expires_at,
    'currentEditor', v_current_editor
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION acquire_assessment_edit_lock(INTEGER, INTEGER, INTEGER) IS 'Acquire turn-based edit lock for collaborative assessment';

-- Function to release edit lock
CREATE OR REPLACE FUNCTION release_assessment_edit_lock(
  p_activity_id INTEGER,
  p_user_id INTEGER
)
RETURNS BOOLEAN AS $$
DECLARE
  v_current_editor INTEGER;
  v_released BOOLEAN := FALSE;
BEGIN
  -- Get current editor
  SELECT current_editor_id
  INTO v_current_editor
  FROM pr_assessments
  WHERE activity_id = p_activity_id;
  
  -- Only the current editor can release their own lock
  IF v_current_editor = p_user_id THEN
    UPDATE pr_assessments
    SET 
      current_editor_id = NULL,
      edit_session_started_at = NULL,
      edit_session_expires_at = NULL,
      updated_at = NOW()
    WHERE activity_id = p_activity_id;
    
    v_released := TRUE;
  END IF;
  
  RETURN v_released;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION release_assessment_edit_lock(INTEGER, INTEGER) IS 'Release edit lock for collaborative assessment';

-- 4. Functions for assessment finalization and state transitions

-- Function to check if all reviewers have finalized their assessment
CREATE OR REPLACE FUNCTION check_all_assessments_finalized(
  p_activity_id INTEGER
)
RETURNS BOOLEAN AS $$
DECLARE
  v_total_reviewers INTEGER;
  v_finalized_reviewers INTEGER;
BEGIN
  -- Count total reviewers for this activity (include both joined and locked_in)
  SELECT COUNT(*)
  INTO v_total_reviewers
  FROM pr_reviewer_teams
  WHERE activity_id = p_activity_id
  AND status IN ('joined', 'locked_in');
  
  -- Count reviewers who have finalized
  SELECT COUNT(*)
  INTO v_finalized_reviewers
  FROM pr_finalization_status
  WHERE activity_id = p_activity_id
  AND is_finalized = true;
  
  -- Return true if all reviewers have finalized
  RETURN v_total_reviewers > 0 AND v_finalized_reviewers = v_total_reviewers;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION check_all_assessments_finalized(INTEGER) IS 'Check if all reviewers have finalized their assessment for an activity';

-- Function to finalize assessment and check for state transition
CREATE OR REPLACE FUNCTION finalize_assessment_and_check_transition(
  p_activity_id INTEGER,
  p_reviewer_id INTEGER
)
RETURNS JSONB AS $$
DECLARE
  v_current_state activity_state;
  v_all_finalized BOOLEAN;
  v_assessment_id INTEGER;
  v_result JSONB;
BEGIN
  -- Get current state
  SELECT current_state INTO v_current_state
  FROM pr_activities
  WHERE activity_id = p_activity_id;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Activity not found',
      'activity_id', p_activity_id
    );
  END IF;
  
  IF v_current_state != 'assessment' THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Activity is not in assessment stage',
      'activity_id', p_activity_id,
      'current_state', v_current_state
    );
  END IF;
  
  -- Update or create reviewer finalization status
  INSERT INTO pr_finalization_status (activity_id, reviewer_id, is_finalized, finalized_at)
  VALUES (p_activity_id, p_reviewer_id, true, NOW())
  ON CONFLICT (activity_id, reviewer_id) 
  DO UPDATE SET 
    is_finalized = true,
    finalized_at = NOW(),
    updated_at = NOW();
  
  -- Check if all reviewers have finalized
  SELECT check_all_assessments_finalized(p_activity_id) INTO v_all_finalized;
  
  -- Just return status - let the service layer handle state transitions and timeline events
  RETURN jsonb_build_object(
    'success', true,
    'message', CASE 
      WHEN v_all_finalized THEN 'All reviewers have finalized the assessment'
      ELSE 'Reviewer finalization recorded, waiting for others'
    END,
    'activity_id', p_activity_id,
    'reviewer_id', p_reviewer_id,
    'all_finalized', v_all_finalized,
    'current_state', v_current_state
  );
  
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'message', 'Error finalizing assessment: ' || SQLERRM,
    'error_code', SQLSTATE,
    'activity_id', p_activity_id,
    'reviewer_id', p_reviewer_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION finalize_assessment_and_check_transition(INTEGER, INTEGER) IS 'Finalize individual reviewer assessment and transition to awarding if all reviewers are done';

-- Simple function to update activity state (for debugging and setup scripts)
CREATE OR REPLACE FUNCTION simple_update_activity_state(
  p_activity_id INTEGER,
  p_new_state activity_state,
  p_reason TEXT DEFAULT 'System transition'
)
RETURNS JSONB AS $$
DECLARE
  v_current_state activity_state;
  v_rows_updated INTEGER;
BEGIN
  -- Get current state
  SELECT current_state INTO v_current_state
  FROM pr_activities
  WHERE activity_id = p_activity_id;
  
  -- Check if activity exists
  IF v_current_state IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Activity not found',
      'activity_id', p_activity_id
    );
  END IF;
  
  -- Skip if already in target state
  IF v_current_state = p_new_state THEN
    RETURN jsonb_build_object(
      'success', true,
      'message', 'Activity already in target state',
      'activity_id', p_activity_id,
      'old_state', v_current_state,
      'new_state', p_new_state
    );
  END IF;
  
  -- Update activity state
  UPDATE pr_activities 
  SET 
    current_state = p_new_state,
    updated_at = NOW()
  WHERE activity_id = p_activity_id;
  
  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;
  
  -- Log the state change
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
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'State updated successfully',
    'activity_id', p_activity_id,
    'old_state', v_current_state,
    'new_state', p_new_state,
    'rows_updated', v_rows_updated
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error updating state: ' || SQLERRM,
      'activity_id', p_activity_id,
      'error_code', SQLSTATE
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION simple_update_activity_state(INTEGER, activity_state, TEXT) IS 'Simple function to update activity state for debugging and setup scripts';

-- 5. Triggers for automatic timestamps
CREATE TRIGGER update_pr_assessments_updated_at
    BEFORE UPDATE ON pr_assessments
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_pr_finalization_status_updated_at
  BEFORE UPDATE ON pr_finalization_status
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- 6. RLS (Row Level Security) policies
ALTER TABLE pr_assessments ENABLE ROW LEVEL SECURITY;
ALTER TABLE pr_finalization_status ENABLE ROW LEVEL SECURITY;

-- Policy for pr_assessments: Only reviewers can access collaborative assessments
CREATE POLICY "assessment_reviewer_access" ON pr_assessments
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM pr_reviewer_teams prt
      WHERE prt.activity_id = pr_assessments.activity_id
      AND prt.user_id = (
        SELECT user_id FROM user_accounts 
        WHERE auth_id = auth.uid()
      )
      AND prt.status IN ('joined', 'locked_in')
    )
  );

-- Policy for pr_finalization_status: Reviewers can access all finalization statuses for their activities
CREATE POLICY "finalization_reviewer_visibility" ON pr_finalization_status
  FOR ALL
  TO authenticated
  USING (
    -- Reviewers can see all finalization statuses for activities they're part of
    EXISTS (
      SELECT 1 FROM pr_reviewer_teams prt
      WHERE prt.activity_id = pr_finalization_status.activity_id
      AND prt.user_id = (
        SELECT user_id FROM user_accounts 
        WHERE auth_id = auth.uid()
      )
      AND prt.status IN ('joined', 'locked_in')
    )
  )
  WITH CHECK (
    -- Can only modify their own finalization status
    reviewer_id = (
      SELECT user_id FROM user_accounts 
      WHERE auth_id = auth.uid()
    )
    OR
    -- Allow system/admin operations for global records
    reviewer_id IS NULL
  );

-- 7. Cleanup job for expired locks (run periodically)
-- This can be called by a cron job or scheduled function
CREATE OR REPLACE FUNCTION scheduled_cleanup_assessment_locks()
RETURNS void AS $$
BEGIN
  PERFORM release_expired_edit_locks();
  
  -- Log cleanup activity
  INSERT INTO system_logs (log_level, message, created_at)
  VALUES ('INFO', 'Released expired assessment edit locks', NOW())
  ON CONFLICT DO NOTHING;  -- Ignore if logs table doesn't exist
EXCEPTION WHEN OTHERS THEN
  -- Ignore errors if system_logs table doesn't exist
  NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION scheduled_cleanup_assessment_locks() IS 'Cleanup job for expired assessment edit locks'; 

-- 8. Conditional finalization update functions for RLS-based reset system

-- Function to handle conditional finalization updates
-- Allows: Own record (any change), Others' records (only finalized → edit reset)
CREATE OR REPLACE FUNCTION update_reviewer_finalization_conditional(
  p_activity_id INTEGER,
  p_reviewer_id INTEGER,
  p_is_finalized BOOLEAN,
  p_requesting_user_id INTEGER
) RETURNS JSONB AS $$
DECLARE
  v_current_status BOOLEAN;
  v_is_reviewer BOOLEAN;
  v_result JSONB;
BEGIN
  -- Verify requesting user is a reviewer in this activity
  SELECT EXISTS (
    SELECT 1 FROM pr_reviewer_teams 
    WHERE activity_id = p_activity_id 
    AND user_id = p_requesting_user_id
    AND status IN ('joined', 'locked_in')
  ) INTO v_is_reviewer;
  
  IF NOT v_is_reviewer THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Not authorized - user is not a reviewer in this activity'
    );
  END IF;
  
  -- Get current finalization status
  SELECT is_finalized INTO v_current_status
  FROM pr_finalization_status
  WHERE activity_id = p_activity_id AND reviewer_id = p_reviewer_id;
  
  -- Apply conditional update rules
  IF p_reviewer_id = p_requesting_user_id THEN
    -- Own record: Full control (can finalize or unfinalize)
    INSERT INTO pr_finalization_status (
      activity_id, reviewer_id, is_finalized, finalized_at, updated_at
    )
    VALUES (
      p_activity_id, p_reviewer_id, p_is_finalized,
      CASE WHEN p_is_finalized THEN NOW() ELSE NULL END,
      NOW()
    )
    ON CONFLICT (activity_id, reviewer_id)
    DO UPDATE SET
      is_finalized = p_is_finalized,
      finalized_at = CASE WHEN p_is_finalized THEN NOW() ELSE NULL END,
      updated_at = NOW();
      
    RETURN jsonb_build_object(
      'success', true,
      'action', 'own_record_updated',
      'old_status', v_current_status,
      'new_status', p_is_finalized
    );
    
  ELSIF v_current_status = true AND p_is_finalized = false THEN
    -- Others' record: Only allow reset (finalized → edit)
    UPDATE pr_finalization_status
    SET 
      is_finalized = false,
      finalized_at = NULL,
      updated_at = NOW()
    WHERE activity_id = p_activity_id AND reviewer_id = p_reviewer_id;
    
    RETURN jsonb_build_object(
      'success', true,
      'action', 'other_record_reset',
      'old_status', true,
      'new_status', false,
      'reset_by', p_requesting_user_id
    );
    
  ELSE
    -- Forbidden: Cannot finalize others or change already-edit records
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Cannot finalize others or modify already-edit records',
      'current_status', v_current_status,
      'requested_status', p_is_finalized
    );
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_reviewer_finalization_conditional IS 'Handles conditional finalization updates with business rule enforcement';

-- Function to reset ALL finalization statuses when content changes
CREATE OR REPLACE FUNCTION reset_all_finalization_statuses(
  p_activity_id INTEGER,
  p_requesting_user_id INTEGER,
  p_reason TEXT DEFAULT 'content_modified'
) RETURNS JSONB AS $$
DECLARE
  v_is_reviewer BOOLEAN;
  v_reset_count INTEGER := 0;
  v_reviewer_record RECORD;
  v_function_result JSONB;
BEGIN
  -- Verify requesting user is a reviewer
  SELECT EXISTS (
    SELECT 1 FROM pr_reviewer_teams 
    WHERE activity_id = p_activity_id 
    AND user_id = p_requesting_user_id
    AND status IN ('joined', 'locked_in')
  ) INTO v_is_reviewer;
  
  IF NOT v_is_reviewer THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Not authorized to reset finalization statuses'
    );
  END IF;
  
  -- Reset all finalization statuses using the conditional function
  FOR v_reviewer_record IN 
    SELECT user_id FROM pr_reviewer_teams 
    WHERE activity_id = p_activity_id 
    AND status IN ('joined', 'locked_in')
  LOOP
    -- Use conditional function to reset each reviewer's status
    SELECT update_reviewer_finalization_conditional(
      p_activity_id,
      v_reviewer_record.user_id,
      false, -- Reset to false
      p_requesting_user_id
    ) INTO v_function_result;
    
    -- Count successful resets
    IF (v_function_result->>'success')::boolean THEN
      v_reset_count := v_reset_count + 1;
    END IF;
  END LOOP;
  
  RETURN jsonb_build_object(
    'success', true,
    'reset_count', v_reset_count,
    'reason', p_reason,
    'reset_by', p_requesting_user_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION reset_all_finalization_statuses IS 'Resets all reviewer finalization statuses for an activity';

-- Grant permissions for assessment functions
GRANT EXECUTE ON FUNCTION acquire_assessment_edit_lock(INTEGER, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION release_assessment_edit_lock(INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION check_all_assessments_finalized(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION finalize_assessment_and_check_transition(INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION simple_update_activity_state(INTEGER, activity_state, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION scheduled_cleanup_assessment_locks() TO authenticated;
GRANT EXECUTE ON FUNCTION update_reviewer_finalization_conditional(INTEGER, INTEGER, BOOLEAN, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION reset_all_finalization_statuses(INTEGER, INTEGER, TEXT) TO authenticated; 