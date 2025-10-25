-- =============================================
-- 00000000000012_condition_evaluators.sql
-- Progression Condition Evaluator Functions
-- =============================================
-- Pluggable condition evaluators for stage progression
-- Each function returns BOOLEAN (true = condition met, false = not met)

-- =============================================
-- 1. Recursive Expression Evaluator (AND/OR/NOT Support)
-- =============================================
-- Evaluates condition expression trees with boolean logic
-- Expression format:
--   Leaf: {"type": "all_reviews_submitted", "config": {"round_number": 1}}
--   AND:  {"op": "AND", "conditions": [{...}, {...}]}
--   OR:   {"op": "OR", "conditions": [{...}, {...}]}
--   NOT:  {"op": "NOT", "condition": {...}}
CREATE OR REPLACE FUNCTION eval_condition_expression(
  p_activity_id INTEGER,
  p_activity_type TEXT,
  p_stage_key TEXT,
  p_expression JSONB
) RETURNS BOOLEAN AS $$
DECLARE
  v_operator TEXT;
  v_condition_type TEXT;
  v_condition_config JSONB;
  v_evaluator_function TEXT;
  v_result BOOLEAN;
  v_sub_condition JSONB;
BEGIN
  -- Extract operator
  v_operator := p_expression->>'op';
  
  -- Handle leaf node (single condition)
  IF v_operator IS NULL THEN
    v_condition_type := p_expression->>'type';
    v_condition_config := p_expression->'config';
    
    -- Get evaluator function for this condition type
    SELECT evaluator_function INTO v_evaluator_function
    FROM progression_conditions
    WHERE condition_code = v_condition_type;
    
    IF v_evaluator_function IS NULL THEN
      RAISE EXCEPTION 'Unknown condition type: %', v_condition_type;
    END IF;
    
    -- Execute evaluator function
    EXECUTE format('SELECT %I($1, $2, $3, $4)', v_evaluator_function)
    INTO v_result
    USING p_activity_id, p_activity_type, p_stage_key, v_condition_config;
    
    RETURN v_result;
  END IF;
  
  -- Handle AND operator (all must be true)
  IF v_operator = 'AND' THEN
    FOR v_sub_condition IN SELECT * FROM jsonb_array_elements(p_expression->'conditions')
    LOOP
      v_result := eval_condition_expression(p_activity_id, p_activity_type, p_stage_key, v_sub_condition);
      IF NOT v_result THEN
        RETURN false;  -- Short-circuit: first false fails the AND
      END IF;
    END LOOP;
    RETURN true;  -- All conditions were true
  END IF;
  
  -- Handle OR operator (at least one must be true)
  IF v_operator = 'OR' THEN
    FOR v_sub_condition IN SELECT * FROM jsonb_array_elements(p_expression->'conditions')
    LOOP
      v_result := eval_condition_expression(p_activity_id, p_activity_type, p_stage_key, v_sub_condition);
      IF v_result THEN
        RETURN true;  -- Short-circuit: first true satisfies the OR
      END IF;
    END LOOP;
    RETURN false;  -- No conditions were true
  END IF;
  
  -- Handle NOT operator (invert result)
  IF v_operator = 'NOT' THEN
    v_result := eval_condition_expression(p_activity_id, p_activity_type, p_stage_key, p_expression->'condition');
    RETURN NOT v_result;
  END IF;
  
  -- Unknown operator
  RAISE EXCEPTION 'Unknown operator: %', v_operator;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION eval_condition_expression IS 'Recursively evaluates condition expression trees with AND/OR/NOT operators';

-- =============================================
-- 2. PR Activity Condition Evaluators
-- =============================================

-- Condition: First review submitted (triggers posted → review_1)
CREATE OR REPLACE FUNCTION eval_first_review_submitted(
  p_activity_id INTEGER,
  p_activity_type TEXT,
  p_stage_key TEXT,
  p_condition_config JSONB
) RETURNS BOOLEAN AS $$
DECLARE
  v_round_number INTEGER;
  v_review_count INTEGER;
BEGIN
  -- Extract config (round_number optional, defaults to 1)
  v_round_number := COALESCE((p_condition_config->>'round_number')::INTEGER, 1);
  
  -- Count reviews for this round (activity-type specific)
  IF p_activity_type = 'pr-activity' THEN
    SELECT COUNT(*) INTO v_review_count
    FROM pr_review_submissions
    WHERE activity_id = p_activity_id 
      AND round_number = v_round_number;
  ELSE
    RETURN false;
  END IF;
  
  -- Return true if at least one review exists
  RETURN v_review_count >= 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION eval_first_review_submitted IS 'Evaluates whether at least one review has been submitted (triggers posted → review_1)';

-- Condition: Minimum reviewers locked in
CREATE OR REPLACE FUNCTION eval_min_reviewers_locked_in(
  p_activity_id INTEGER,
  p_activity_type TEXT,
  p_stage_key TEXT,
  p_condition_config JSONB
) RETURNS BOOLEAN AS $$
DECLARE
  v_min_count INTEGER;
  v_locked_in_count INTEGER;
BEGIN
  -- Extract config
  v_min_count := (p_condition_config->>'min_count')::INTEGER;
  
  -- Count locked-in reviewers (activity-type specific)
  IF p_activity_type = 'pr-activity' THEN
    SELECT COUNT(*) INTO v_locked_in_count
    FROM pr_reviewers
    WHERE activity_id = p_activity_id 
      AND status = 'locked_in';
  ELSE
    RETURN false;
  END IF;
  
  RETURN v_locked_in_count >= v_min_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION eval_min_reviewers_locked_in IS 'Evaluates whether minimum number of reviewers have locked in';

-- Condition: All reviews submitted for a round
CREATE OR REPLACE FUNCTION eval_all_reviews_submitted(
  p_activity_id INTEGER,
  p_activity_type TEXT,
  p_stage_key TEXT,
  p_condition_config JSONB
) RETURNS BOOLEAN AS $$
DECLARE
  v_round_number INTEGER;
  v_required_count INTEGER;
  v_submitted_count INTEGER;
BEGIN
  -- Extract config
  v_round_number := (p_condition_config->>'round_number')::INTEGER;
  
  -- Get required reviewer count and count submissions (activity-type specific)
  IF p_activity_type = 'pr-activity' THEN
    SELECT pt.reviewer_count INTO v_required_count
    FROM pr_activities pa
    JOIN pr_templates pt ON pa.template_id = pt.template_id
    WHERE pa.activity_id = p_activity_id;
    
    -- Count submitted reviews for this round
    SELECT COUNT(DISTINCT reviewer_id) INTO v_submitted_count
    FROM pr_review_submissions
    WHERE activity_id = p_activity_id 
      AND round_number = v_round_number;
  ELSE
    RETURN false;
  END IF;
  
  RETURN v_submitted_count >= v_required_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION eval_all_reviews_submitted IS 'Evaluates whether all required reviews submitted for a round';

-- Condition: Author response submitted for a round
CREATE OR REPLACE FUNCTION eval_author_response_submitted(
  p_activity_id INTEGER,
  p_activity_type TEXT,
  p_stage_key TEXT,
  p_condition_config JSONB
) RETURNS BOOLEAN AS $$
DECLARE
  v_round_number INTEGER;
  v_response_exists BOOLEAN;
BEGIN
  -- Extract config
  v_round_number := (p_condition_config->>'round_number')::INTEGER;
  
  -- Check if response exists (activity-type specific)
  IF p_activity_type = 'pr-activity' THEN
    SELECT EXISTS(
      SELECT 1 FROM pr_author_responses
      WHERE activity_id = p_activity_id 
        AND round_number = v_round_number
    ) INTO v_response_exists;
  ELSE
    RETURN false;
  END IF;
  
  RETURN v_response_exists;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION eval_author_response_submitted IS 'Evaluates whether author submitted response for a round';

-- Condition: All participants finalized (assessment stage)
CREATE OR REPLACE FUNCTION eval_all_finalized(
  p_activity_id INTEGER,
  p_activity_type TEXT,
  p_stage_key TEXT,
  p_condition_config JSONB
) RETURNS BOOLEAN AS $$
DECLARE
  v_required_count INTEGER;
  v_finalized_count INTEGER;
BEGIN
  -- Count required participants and finalized (activity-type specific)
  IF p_activity_type = 'pr-activity' THEN
    -- Database as Source of Truth: Count ACTUAL reviewers, not template requirement
    -- This ensures activities with fewer reviewers than template allows can still complete
    SELECT COUNT(*) INTO v_required_count
    FROM pr_reviewers
    WHERE activity_id = p_activity_id
      AND status IN ('joined', 'locked_in');
    
    -- Count finalized
    SELECT COUNT(*) INTO v_finalized_count
    FROM pr_finalization_status
    WHERE activity_id = p_activity_id
      AND is_finalized = true;
  ELSIF p_activity_type = 'jc-activity' THEN
    -- For JC, check if all participants finalized
    SELECT COUNT(*) INTO v_required_count
    FROM jc_participants
    WHERE activity_id = p_activity_id;
    
    SELECT COUNT(*) INTO v_finalized_count
    FROM jc_finalization_status
    WHERE activity_id = p_activity_id
      AND is_finalized = true;
  ELSE
    RETURN false;
  END IF;
  
  RETURN v_finalized_count >= v_required_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION eval_all_finalized IS 'Evaluates whether all required participants have finalized';

-- Condition: All awards distributed
CREATE OR REPLACE FUNCTION eval_all_awards_distributed(
  p_activity_id INTEGER,
  p_activity_type TEXT,
  p_stage_key TEXT,
  p_condition_config JSONB
) RETURNS BOOLEAN AS $$
DECLARE
  v_required_count INTEGER;
  v_distributed_count INTEGER;
BEGIN
  -- Count required participants and distributed (activity-type specific)
  IF p_activity_type = 'pr-activity' THEN
    -- Get total participant count (reviewers + authors)
    SELECT COUNT(DISTINCT user_id) INTO v_required_count
    FROM pr_activity_permissions
    WHERE activity_id = p_activity_id;
    
    -- Count who have distributed
    SELECT COUNT(*) INTO v_distributed_count
    FROM pr_award_distribution_status
    WHERE activity_id = p_activity_id
      AND has_distributed_awards = true;
  ELSIF p_activity_type = 'jc-activity' THEN
    -- For JC, count participants
    SELECT COUNT(*) INTO v_required_count
    FROM jc_activity_permissions
    WHERE activity_id = p_activity_id;
    
    SELECT COUNT(*) INTO v_distributed_count
    FROM jc_award_distribution_status
    WHERE activity_id = p_activity_id
      AND has_distributed_awards = true;
  ELSE
    RETURN false;
  END IF;
  
  RETURN v_distributed_count >= v_required_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION eval_all_awards_distributed IS 'Evaluates whether all participants have distributed awards';

-- Condition: Deadline reached
CREATE OR REPLACE FUNCTION eval_deadline_reached(
  p_activity_id INTEGER,
  p_activity_type TEXT,
  p_stage_key TEXT,
  p_condition_config JSONB
) RETURNS BOOLEAN AS $$
DECLARE
  v_deadline TIMESTAMPTZ;
BEGIN
  -- Get current stage deadline
  SELECT stage_deadline INTO v_deadline
  FROM activity_stage_state
  WHERE activity_type = p_activity_type
    AND activity_id = p_activity_id;
  
  -- Return true if deadline exists and has passed
  RETURN v_deadline IS NOT NULL AND v_deadline <= NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION eval_deadline_reached IS 'Evaluates whether stage deadline has been reached';

-- =============================================
-- 3. Universal Condition Evaluators
-- =============================================

-- Condition: Manual progression (always returns true)
CREATE OR REPLACE FUNCTION eval_manual(
  p_activity_id INTEGER,
  p_activity_type TEXT,
  p_stage_key TEXT,
  p_condition_config JSONB
) RETURNS BOOLEAN AS $$
BEGIN
  -- Manual progression always returns true when explicitly triggered
  -- The is_automatic=false flag prevents automatic checking
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION eval_manual IS 'Manual progression condition (always true when triggered)';

-- =============================================
-- Function Permissions
-- =============================================
-- Condition evaluators are called by progression engine (service role only)
-- Grant execute to authenticated for direct testing/debugging

GRANT EXECUTE ON FUNCTION eval_condition_expression TO authenticated;
GRANT EXECUTE ON FUNCTION eval_min_reviewers_locked_in TO authenticated;
GRANT EXECUTE ON FUNCTION eval_all_reviews_submitted TO authenticated;
GRANT EXECUTE ON FUNCTION eval_author_response_submitted TO authenticated;
GRANT EXECUTE ON FUNCTION eval_all_finalized TO authenticated;
GRANT EXECUTE ON FUNCTION eval_all_awards_distributed TO authenticated;
GRANT EXECUTE ON FUNCTION eval_deadline_reached TO authenticated;
GRANT EXECUTE ON FUNCTION eval_manual TO authenticated;

