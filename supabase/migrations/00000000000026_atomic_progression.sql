-- =============================================
-- 00000000000026_atomic_progression.sql
-- Atomic progression functions to eliminate race conditions
-- =============================================
-- 
-- ARCHITECTURAL DECISION:
-- Previously, progression checks happened in separate transactions:
--   1. Submit review/response (transaction 1)
--   2. Update status (transaction 2)
--   3. Query for progression check (transaction 3, reads stale data!)
-- 
-- This caused race conditions where status updates weren't visible to
-- progression checks, causing activities to get stuck in 'submitted' state.
-- 
-- SOLUTION:
-- Database functions that perform ALL operations atomically:
--   - Store content (review/response/etc)
--   - Update status
--   - Check progression conditions
--   - Return result (all in ONE transaction)
-- 
-- This follows DEVELOPMENT_PRINCIPLES.md:
--   - "Database is Source of Truth"
--   - "Fail Fast, Fail Clear"
--   - Let database handle atomic operations
-- =============================================

-- =============================================
-- ACTIVITY TYPE ENUM (for journal club support)
-- =============================================
-- Create activity_type enum to distinguish standard PR from journal club
-- This is needed by progression functions below
DO $$ BEGIN
  CREATE TYPE activity_type AS ENUM ('standard', 'journal_club');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON TYPE activity_type IS 'Type of peer review activity: standard (token-based, automatic) or journal_club (free, manual)';

-- Add activity_type column to pr_activities (defaults to 'standard' for existing activities)
ALTER TABLE pr_activities 
ADD COLUMN IF NOT EXISTS activity_type activity_type NOT NULL DEFAULT 'standard';

COMMENT ON COLUMN pr_activities.activity_type IS 'Type of activity: standard (token-based, automatic) or journal_club (free, manual)';

-- =============================================
-- FUNCTION: submit_review_and_check_progression
-- =============================================
-- Atomically submit a review, update reviewer status, and check if activity should progress
-- Returns progression decision so application can trigger state transition if needed
CREATE OR REPLACE FUNCTION submit_review_and_check_progression(
  p_activity_id INTEGER,
  p_reviewer_id INTEGER,
  p_review_content TEXT,
  p_round_number INTEGER,
  p_is_initial_assessment BOOLEAN DEFAULT false
) RETURNS JSONB AS $$
DECLARE
  v_review_id INTEGER;
  v_locked_in_count INTEGER;
  v_required_count INTEGER;
  v_current_state activity_state;
  v_should_progress BOOLEAN := false;
  v_next_state activity_state;
  v_activity_type activity_type;
BEGIN
  -- Check if this is a journal club (manual progression only)
  SELECT activity_type INTO v_activity_type
  FROM pr_activities
  WHERE activity_id = p_activity_id;
  
  IF v_activity_type = 'journal_club' THEN
    -- Journal clubs use manual progression - never auto-progress
    RETURN jsonb_build_object(
      'review_id', NULL,
      'should_progress', false,
      'current_state', NULL,
      'next_state', NULL,
      'locked_in_count', NULL,
      'required_count', NULL,
      'message', 'Journal club activities use manual progression'
    );
  END IF;
  
  -- Get current activity state and required reviewer count
  SELECT pa.current_state, pt.reviewer_count
  INTO v_current_state, v_required_count
  FROM pr_activities pa
  JOIN pr_templates pt ON pa.template_id = pt.template_id
  WHERE pa.activity_id = p_activity_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Activity % not found', p_activity_id;
  END IF;

  -- 1. Insert review
  INSERT INTO pr_review_submissions (
    activity_id, 
    reviewer_id, 
    review_content, 
    round_number, 
    is_initial_assessment,
    submitted_at
  )
  VALUES (
    p_activity_id, 
    p_reviewer_id, 
    p_review_content, 
    p_round_number,
    p_is_initial_assessment,
    NOW()
  )
  RETURNING submission_id INTO v_review_id;

  -- 2. Update reviewer status to locked_in (if not already)
  UPDATE pr_reviewer_teams
  SET 
    status = 'locked_in',
    locked_in_at = COALESCE(locked_in_at, NOW())
  WHERE activity_id = p_activity_id 
    AND user_id = p_reviewer_id
    AND status != 'locked_in';

  -- 3. Count locked-in reviewers (in same transaction, sees the update!)
  SELECT COUNT(*)
  INTO v_locked_in_count
  FROM pr_reviewer_teams
  WHERE activity_id = p_activity_id 
    AND status = 'locked_in';

  -- 4. Determine if progression should occur based on current state
  IF v_current_state = 'submitted' AND v_locked_in_count >= 1 THEN
    -- submitted → review_round_1 (first reviewer locks in)
    v_should_progress := true;
    v_next_state := 'review_round_1';
  ELSIF v_current_state = 'review_round_1' AND p_round_number = 1 AND v_locked_in_count >= v_required_count THEN
    -- review_round_1 → author_response_1 (all reviewers submitted round 1)
    v_should_progress := true;
    v_next_state := 'author_response_1';
  ELSIF v_current_state = 'review_round_2' AND p_round_number = 2 AND v_locked_in_count >= v_required_count THEN
    -- review_round_2 → author_response_2 (all reviewers submitted round 2)
    v_should_progress := true;
    v_next_state := 'author_response_2';
  END IF;

  -- 5. Return result
  RETURN jsonb_build_object(
    'review_id', v_review_id,
    'locked_in_count', v_locked_in_count,
    'required_count', v_required_count,
    'current_state', v_current_state,
    'should_progress', v_should_progress,
    'next_state', v_next_state
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp;

COMMENT ON FUNCTION submit_review_and_check_progression IS 
  'Atomically submit review, update reviewer status, and check progression conditions. Eliminates race conditions by performing all operations in single transaction.';

-- =============================================
-- FUNCTION: submit_author_response_and_check_progression
-- =============================================
-- Atomically submit author response and check if activity should progress
CREATE OR REPLACE FUNCTION submit_author_response_and_check_progression(
  p_activity_id INTEGER,
  p_author_id INTEGER,
  p_response_content TEXT,
  p_cover_letter TEXT,
  p_round_number INTEGER
) RETURNS JSONB AS $$
DECLARE
  v_response_id INTEGER;
  v_current_state activity_state;
  v_review_rounds INTEGER;
  v_should_progress BOOLEAN := false;
  v_next_state activity_state;
  v_activity_type activity_type;
BEGIN
  -- Check if this is a journal club (manual progression only)
  SELECT activity_type INTO v_activity_type
  FROM pr_activities
  WHERE activity_id = p_activity_id;
  
  IF v_activity_type = 'journal_club' THEN
    -- Journal clubs use manual progression - never auto-progress
    RETURN jsonb_build_object(
      'response_id', NULL,
      'should_progress', false,
      'current_state', NULL,
      'next_state', NULL,
      'message', 'Journal club activities use manual progression'
    );
  END IF;
  
  -- Get current activity state and template info
  SELECT pa.current_state, pt.review_rounds
  INTO v_current_state, v_review_rounds
  FROM pr_activities pa
  JOIN pr_templates pt ON pa.template_id = pt.template_id
  WHERE pa.activity_id = p_activity_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Activity % not found', p_activity_id;
  END IF;

  -- 1. Insert author response
  INSERT INTO pr_author_responses (
    activity_id,
    user_id,
    response_content,
    cover_letter,
    round_number,
    submitted_at
  )
  VALUES (
    p_activity_id,
    p_author_id,
    p_response_content,
    p_cover_letter,
    p_round_number,
    NOW()
  )
  RETURNING response_id INTO v_response_id;

  -- 2. Determine if progression should occur
  IF v_current_state = 'author_response_1' AND p_round_number = 1 THEN
    v_should_progress := true;
    -- Check if this is a multi-round template
    IF v_review_rounds > 1 THEN
      v_next_state := 'review_round_2';
    ELSE
      v_next_state := 'assessment';
    END IF;
  ELSIF v_current_state = 'author_response_2' AND p_round_number = 2 THEN
    v_should_progress := true;
    v_next_state := 'assessment';
  END IF;

  -- 3. Return result
  RETURN jsonb_build_object(
    'response_id', v_response_id,
    'current_state', v_current_state,
    'review_rounds', v_review_rounds,
    'should_progress', v_should_progress,
    'next_state', v_next_state
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp;

COMMENT ON FUNCTION submit_author_response_and_check_progression IS
  'Atomically submit author response and determine next state based on template configuration.';

-- =============================================
-- FUNCTION: toggle_assessment_finalization_and_check_progression
-- =============================================
-- Atomically toggle reviewer finalization status and check if all reviewers are ready
CREATE OR REPLACE FUNCTION toggle_assessment_finalization_and_check_progression(
  p_activity_id INTEGER,
  p_reviewer_id INTEGER,
  p_is_finalized BOOLEAN,
  p_content_hash TEXT
) RETURNS JSONB AS $$
DECLARE
  v_finalization_id INTEGER;
  v_finalized_count INTEGER;
  v_required_count INTEGER;
  v_current_state activity_state;
  v_should_progress BOOLEAN := false;
  v_next_state activity_state;
BEGIN
  -- Get current activity state and required reviewer count
  SELECT pa.current_state, pt.reviewer_count
  INTO v_current_state, v_required_count
  FROM pr_activities pa
  JOIN pr_templates pt ON pa.template_id = pt.template_id
  WHERE pa.activity_id = p_activity_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Activity % not found', p_activity_id;
  END IF;

  -- Verify we're in assessment state
  IF v_current_state != 'assessment' THEN
    RAISE EXCEPTION 'Activity % is not in assessment state (current: %)', p_activity_id, v_current_state;
  END IF;

  -- 1. Upsert finalization status
  INSERT INTO pr_finalization_status (
    activity_id,
    reviewer_id,
    is_finalized,
    content_hash_at_finalization,
    finalized_at
  )
  VALUES (
    p_activity_id,
    p_reviewer_id,
    p_is_finalized,
    p_content_hash,
    CASE WHEN p_is_finalized THEN NOW() ELSE NULL END
  )
  ON CONFLICT (activity_id, reviewer_id)
  DO UPDATE SET
    is_finalized = p_is_finalized,
    content_hash_at_finalization = p_content_hash,
    finalized_at = CASE WHEN p_is_finalized THEN NOW() ELSE NULL END,
    updated_at = NOW()
  RETURNING status_id INTO v_finalization_id;

  -- 2. Count finalized reviewers
  SELECT COUNT(*)
  INTO v_finalized_count
  FROM pr_finalization_status
  WHERE activity_id = p_activity_id
    AND is_finalized = true;

  -- 3. Check if all reviewers have finalized
  IF v_finalized_count >= v_required_count THEN
    v_should_progress := true;
    v_next_state := 'awarding';
  END IF;

  -- 4. Return result
  RETURN jsonb_build_object(
    'finalization_id', v_finalization_id,
    'finalized_count', v_finalized_count,
    'required_count', v_required_count,
    'current_state', v_current_state,
    'should_progress', v_should_progress,
    'next_state', v_next_state
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp;

COMMENT ON FUNCTION toggle_assessment_finalization_and_check_progression IS
  'Atomically toggle finalization status and check if all reviewers are ready to progress.';

-- =============================================
-- FUNCTION: submit_award_distribution_and_check_progression
-- =============================================
-- Atomically submit award distribution and check if all participants have submitted
CREATE OR REPLACE FUNCTION submit_award_distribution_and_check_progression(
  p_activity_id INTEGER,
  p_participant_id INTEGER,
  p_awards JSONB
) RETURNS JSONB AS $$
DECLARE
  v_distribution_id INTEGER;
  v_submitted_count INTEGER;
  v_required_count INTEGER;
  v_current_state activity_state;
  v_should_progress BOOLEAN := false;
  v_next_state activity_state;
BEGIN
  -- Get current activity state and total participant count
  SELECT pa.current_state, 
         (SELECT COUNT(*) FROM pr_activity_permissions WHERE activity_id = p_activity_id) as participant_count
  INTO v_current_state, v_required_count
  FROM pr_activities pa
  WHERE pa.activity_id = p_activity_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Activity % not found', p_activity_id;
  END IF;

  -- Verify we're in awarding state
  IF v_current_state != 'awarding' THEN
    RAISE EXCEPTION 'Activity % is not in awarding state (current: %)', p_activity_id, v_current_state;
  END IF;

  -- 1. Upsert award distribution status
  INSERT INTO pr_award_distribution_status (
    activity_id,
    participant_id,
    participant_type,
    has_distributed_awards,
    distributed_at
  )
  VALUES (
    p_activity_id,
    p_participant_id,
    -- Determine participant type from pr_activity_permissions
    (SELECT CASE 
      WHEN role = 'corresponding_author' THEN 'author'
      ELSE 'reviewer'
    END FROM pr_activity_permissions 
    WHERE activity_id = p_activity_id AND user_id = p_participant_id),
    TRUE,
    NOW()
  )
  ON CONFLICT (activity_id, participant_id)
  DO UPDATE SET
    has_distributed_awards = TRUE,
    distributed_at = NOW()
  RETURNING status_id INTO v_distribution_id;

  -- 2. Count submitted distributions
  SELECT COUNT(*)
  INTO v_submitted_count
  FROM pr_award_distribution_status
  WHERE activity_id = p_activity_id
    AND has_distributed_awards = TRUE;

  -- 3. Check if all participants have submitted
  IF v_submitted_count >= v_required_count THEN
    v_should_progress := true;
    v_next_state := 'publication_choice';
  END IF;

  -- 4. Return result
  RETURN jsonb_build_object(
    'distribution_id', v_distribution_id,
    'submitted_count', v_submitted_count,
    'required_count', v_required_count,
    'current_state', v_current_state,
    'should_progress', v_should_progress,
    'next_state', v_next_state
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp;

COMMENT ON FUNCTION submit_award_distribution_and_check_progression IS
  'Atomically submit award distribution and check if all participants have submitted.';

-- =============================================
-- FUNCTION: execute_state_transition
-- =============================================
-- Execute a state transition with proper validation and timeline event creation
-- This replaces the complex application-layer ProgressionService logic
CREATE OR REPLACE FUNCTION execute_state_transition(
  p_activity_id INTEGER,
  p_from_state activity_state,
  p_to_state activity_state,
  p_triggered_by_user_id INTEGER
) RETURNS JSONB AS $$
DECLARE
  v_actual_state activity_state;
  v_transition_id INTEGER;
  v_deadline_days INTEGER;
  v_new_deadline TIMESTAMPTZ;
BEGIN
  -- 1. Verify current state matches expected state (prevent race conditions)
  SELECT current_state INTO v_actual_state
  FROM pr_activities
  WHERE activity_id = p_activity_id
  FOR UPDATE; -- Lock the row

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Activity % not found', p_activity_id;
  END IF;

  IF v_actual_state != p_from_state THEN
    RAISE EXCEPTION 'Activity % state mismatch: expected %, got %', 
      p_activity_id, p_from_state, v_actual_state;
  END IF;

  -- 2. Update activity state
  UPDATE pr_activities
  SET 
    current_state = p_to_state,
    stage_transition_at = NOW(),
    updated_at = NOW()
  WHERE activity_id = p_activity_id;

  -- 3. Get deadline for new state
  SELECT deadline_days INTO v_deadline_days
  FROM pr_deadlines pd
  JOIN pr_activities pa ON pa.template_id = pd.template_id
  WHERE pa.activity_id = p_activity_id
    AND pd.state_name = p_to_state;

  -- 4. Set new deadline if configured
  IF v_deadline_days IS NOT NULL THEN
    v_new_deadline := NOW() + (v_deadline_days || ' days')::INTERVAL;
    UPDATE pr_activities
    SET stage_deadline = v_new_deadline
    WHERE activity_id = p_activity_id;
  END IF;

  -- 5. Create timeline event
  INSERT INTO pr_state_log (
    activity_id,
    old_state,
    new_state,
    changed_by,
    reason,
    changed_at
  )
  VALUES (
    p_activity_id,
    p_from_state,
    p_to_state,
    p_triggered_by_user_id,
    'Automatic progression',
    NOW()
  )
  RETURNING log_id INTO v_transition_id;

  -- 6. Return result
  RETURN jsonb_build_object(
    'transition_id', v_transition_id,
    'from_state', p_from_state,
    'to_state', p_to_state,
    'new_deadline', v_new_deadline,
    'transitioned_at', NOW()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp;

COMMENT ON FUNCTION execute_state_transition IS
  'Execute a validated state transition with deadline setting and timeline event creation.';

-- Grant execute permissions to authenticated users
GRANT EXECUTE ON FUNCTION submit_review_and_check_progression TO authenticated;
GRANT EXECUTE ON FUNCTION submit_author_response_and_check_progression TO authenticated;
GRANT EXECUTE ON FUNCTION toggle_assessment_finalization_and_check_progression TO authenticated;
GRANT EXECUTE ON FUNCTION submit_award_distribution_and_check_progression TO authenticated;
GRANT EXECUTE ON FUNCTION execute_state_transition TO authenticated;

