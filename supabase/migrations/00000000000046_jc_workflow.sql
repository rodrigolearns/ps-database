-- =============================================
-- 00000000000046_jc_workflow.sql
-- JC Activity Domain: Workflow Definition
-- =============================================
-- Defines the fixed workflow for JC activities
-- JC uses simple manual progression (no templates, no complex workflow graphs)

-- =============================================
-- JC Workflow Stages
-- =============================================
-- JC activities have a fixed 3-stage workflow:
-- 1. jc_review (review submission)
-- 2. jc_assessment (collaborative assessment)
-- 3. jc_awarding (award distribution)
--
-- Progression is entirely manual (creator-controlled)
-- No deadlines, no automatic transitions
--
-- Stage state is tracked in activity_stage_state table
-- Creator manually calls check_and_progress_activity() with force_transition_id

-- Helper function: Get JC activities for a user
CREATE OR REPLACE FUNCTION get_user_jc_activities(p_user_id INTEGER)
RETURNS TABLE (
  activity_id INTEGER,
  activity_uuid UUID,
  paper_title TEXT,
  current_stage_key TEXT,
  created_at TIMESTAMPTZ,
  reviewer_count BIGINT,
  is_creator BOOLEAN
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    jca.activity_id,
    jca.activity_uuid,
    p.title as paper_title,
    ass.current_stage_key,
    jca.created_at,
    COUNT(DISTINCT jp.user_id) as participant_count,
    (jca.creator_id = p_user_id) as is_creator
  FROM jc_activities jca
  JOIN papers p ON jca.paper_id = p.paper_id
  LEFT JOIN activity_stage_state ass ON ass.activity_id = jca.activity_id AND ass.activity_type = 'jc-activity'
  LEFT JOIN jc_participants jp ON jca.activity_id = jp.activity_id
  WHERE jca.creator_id = p_user_id OR
    EXISTS (
      SELECT 1 FROM jc_participants jp2
      WHERE jp2.activity_id = jca.activity_id
      AND jp2.user_id = p_user_id
    )
  GROUP BY jca.activity_id, jca.activity_uuid, p.title, ass.current_stage_key, jca.created_at, jca.creator_id
  ORDER BY jca.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION get_user_jc_activities IS 'Gets all JC activities user created or participates in';

-- Helper function: Get pending invitations for a user
CREATE OR REPLACE FUNCTION get_pending_jc_invitations(p_user_id INTEGER)
RETURNS TABLE (
  invitation_id INTEGER,
  activity_id INTEGER,
  paper_title TEXT,
  inviter_name TEXT,
  invited_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    jci.invitation_id,
    jci.activity_id,
    p.title as paper_title,
    ua.username as inviter_name,
    jci.invited_at
  FROM jc_invitations jci
  JOIN jc_activities jca ON jci.activity_id = jca.activity_id
  JOIN papers p ON jca.paper_id = p.paper_id
  JOIN user_accounts ua ON jci.inviter_id = ua.user_id
  WHERE jci.invitee_id = p_user_id
    AND jci.status = 'pending'
  ORDER BY jci.invited_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION get_pending_jc_invitations IS 'Gets pending JC invitations for a user';

-- Grant permissions
GRANT EXECUTE ON FUNCTION get_user_jc_activities TO authenticated;
GRANT EXECUTE ON FUNCTION get_pending_jc_invitations TO authenticated;

