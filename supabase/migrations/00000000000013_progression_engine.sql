-- =============================================
-- 00000000000013_progression_engine.sql
-- Generic Activity Progression Engine
-- =============================================
-- Generic progression engine that works across all activity types
-- Evaluates condition expressions and executes state transitions

-- =============================================
-- 1. Generic Progression Engine
-- =============================================
-- Checks conditions and progresses activities through their workflow graphs
-- Works for any activity type (pr-activity, jc-activity, future types)
CREATE OR REPLACE FUNCTION check_and_progress_activity(
  p_activity_type TEXT,
  p_activity_id INTEGER,
  p_triggered_by_user_id INTEGER DEFAULT NULL,
  p_force_transition_id INTEGER DEFAULT NULL  -- For manual progression
) RETURNS JSONB AS $$
DECLARE
  v_template_id INTEGER;
  v_current_stage_key TEXT;
  v_transition_record RECORD;
  v_condition_met BOOLEAN;
  v_next_stage_key TEXT;
  v_progression_result JSONB;
BEGIN
  -- 1. Get current stage
  SELECT current_stage_key INTO v_current_stage_key
  FROM activity_stage_state
  WHERE activity_type = p_activity_type 
    AND activity_id = p_activity_id;
  
  IF v_current_stage_key IS NULL THEN
    RETURN jsonb_build_object(
      'progressed', false,
      'error', 'Activity not found or no current stage'
    );
  END IF;
  
  -- 2. Get template ID (activity-type specific query)
  IF p_activity_type = 'pr-activity' THEN
    SELECT template_id INTO v_template_id 
    FROM pr_activities 
    WHERE activity_id = p_activity_id;
  ELSIF p_activity_type = 'jc-activity' THEN
    v_template_id := NULL;  -- JC activities don't use templates
  ELSE
    RETURN jsonb_build_object(
      'progressed', false,
      'error', 'Unknown activity type: ' || p_activity_type
    );
  END IF;
  
  -- 3. If manual transition requested, use that specific transition
  IF p_force_transition_id IS NOT NULL THEN
    SELECT * INTO v_transition_record
    FROM template_stage_transitions
    WHERE transition_id = p_force_transition_id
      AND from_stage_key = v_current_stage_key;
    
    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'progressed', false,
        'error', 'Invalid transition ID or not valid from current stage'
      );
    END IF;
    
    -- Execute the manual transition
    SELECT execute_stage_transition(
      p_activity_type,
      p_activity_id,
      v_current_stage_key,
      v_transition_record.to_stage_key,
      p_triggered_by_user_id
    ) INTO v_progression_result;
    
    RETURN jsonb_build_object(
      'progressed', true,
      'from_stage', v_current_stage_key,
      'to_stage', v_transition_record.to_stage_key,
      'transition_id', v_transition_record.transition_id,
      'result', v_progression_result
    );
  END IF;
  
  -- 4. Find valid automatic transitions from current stage
  FOR v_transition_record IN
    SELECT tst.*
    FROM template_stage_transitions tst
    WHERE tst.template_id = v_template_id
      AND tst.activity_type = p_activity_type
      AND tst.from_stage_key = v_current_stage_key
      AND tst.is_automatic = true  -- Only check automatic transitions
    ORDER BY tst.transition_order ASC
  LOOP
    -- 5. Evaluate condition expression (supports AND/OR/NOT)
    SELECT eval_condition_expression(
      p_activity_id,
      p_activity_type,
      v_current_stage_key,
      v_transition_record.condition_expression
    ) INTO v_condition_met;
    
    -- 6. If condition met, perform transition
    IF v_condition_met THEN
      v_next_stage_key := v_transition_record.to_stage_key;
      
      -- Execute the transition
      SELECT execute_stage_transition(
        p_activity_type,
        p_activity_id,
        v_current_stage_key,
        v_next_stage_key,
        p_triggered_by_user_id
      ) INTO v_progression_result;
      
      RETURN jsonb_build_object(
        'progressed', true,
        'from_stage', v_current_stage_key,
        'to_stage', v_next_stage_key,
        'transition_id', v_transition_record.transition_id,
        'result', v_progression_result
      );
    END IF;
  END LOOP;
  
  -- No valid transitions found
  RETURN jsonb_build_object(
    'progressed', false,
    'current_stage', v_current_stage_key,
    'reason', 'No conditions met for progression'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION check_and_progress_activity IS 'Generic progression engine: checks conditions and transitions activities through workflow graphs';

-- =============================================
-- 2. Stage Transition Executor
-- =============================================
-- Executes a stage transition with deadline calculation and timeline event creation
-- Works for any activity type
CREATE OR REPLACE FUNCTION execute_stage_transition(
  p_activity_type TEXT,
  p_activity_id INTEGER,
  p_from_stage_key TEXT,
  p_to_stage_key TEXT,
  p_triggered_by_user_id INTEGER DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_template_id INTEGER;
  v_deadline_days INTEGER;
  v_new_deadline TIMESTAMPTZ;
  v_stage_display_name TEXT;
  v_timeline_event_id INTEGER;
BEGIN
  -- 1. Get template ID and new stage deadline config (activity-type specific)
  IF p_activity_type = 'pr-activity' THEN
    SELECT pa.template_id, tsg.deadline_days, tsg.display_name
    INTO v_template_id, v_deadline_days, v_stage_display_name
    FROM pr_activities pa
    JOIN template_stage_graph tsg 
      ON tsg.template_id = pa.template_id 
      AND tsg.activity_type = p_activity_type
      AND tsg.stage_key = p_to_stage_key
    WHERE pa.activity_id = p_activity_id;
  ELSIF p_activity_type = 'jc-activity' THEN
    -- JC activities don't have deadlines or templates
    v_deadline_days := NULL;
    v_stage_display_name := p_to_stage_key;
  END IF;
  
  -- 2. Calculate new deadline
  IF v_deadline_days IS NOT NULL THEN
    v_new_deadline := NOW() + (v_deadline_days || ' days')::INTERVAL;
  ELSE
    v_new_deadline := NULL;
  END IF;
  
  -- 3. Update activity stage state
  UPDATE activity_stage_state
  SET 
    current_stage_key = p_to_stage_key,
    stage_entered_at = NOW(),
    stage_deadline = v_new_deadline,
    updated_at = NOW()
  WHERE activity_type = p_activity_type
    AND activity_id = p_activity_id;
  
  -- 4. Create timeline event (activity-type specific table)
  IF p_activity_type = 'pr-activity' THEN
    INSERT INTO pr_timeline_events (
      activity_id,
      event_type,
      stage_key,
      user_id,
      title,
      description,
      created_at
    )
    VALUES (
      p_activity_id,
      'stage_transition',
      p_to_stage_key,
      p_triggered_by_user_id,
      'Progressed to ' || COALESCE(v_stage_display_name, p_to_stage_key),
      'Activity progressed from ' || p_from_stage_key || ' to ' || p_to_stage_key,
      NOW()
    )
    RETURNING event_id INTO v_timeline_event_id;
  ELSIF p_activity_type = 'jc-activity' THEN
    INSERT INTO jc_timeline_events (
      activity_id,
      event_type,
      stage_key,
      user_id,
      title,
      description,
      created_at
    )
    VALUES (
      p_activity_id,
      'stage_transition',
      p_to_stage_key,
      p_triggered_by_user_id,
      'Progressed to ' || COALESCE(v_stage_display_name, p_to_stage_key),
      'Activity progressed from ' || p_from_stage_key || ' to ' || p_to_stage_key,
      NOW()
    )
    RETURNING event_id INTO v_timeline_event_id;
  END IF;
  
  -- 5. Return result
  RETURN jsonb_build_object(
    'from_stage', p_from_stage_key,
    'to_stage', p_to_stage_key,
    'new_deadline', v_new_deadline,
    'timeline_event_id', v_timeline_event_id,
    'transitioned_at', NOW()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION execute_stage_transition IS 'Executes stage transition with deadline calculation and timeline event creation';

-- =============================================
-- Function Permissions
-- =============================================
-- Progression functions are called by API routes (service role)
-- Grant to authenticated for direct testing

GRANT EXECUTE ON FUNCTION check_and_progress_activity TO authenticated;
GRANT EXECUTE ON FUNCTION execute_stage_transition TO authenticated;

