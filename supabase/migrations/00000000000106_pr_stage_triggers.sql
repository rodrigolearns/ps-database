-- =============================================
-- 00000000000108_pr_auto_stage_triggers.sql
-- Automatic Stage Advancement for Peer Review Activities
-- =============================================

CREATE OR REPLACE FUNCTION public.pr_advance_state()
RETURNS TRIGGER AS $$
DECLARE
  v_aid    INT;
  v_stats  RECORD;
  v_next   activity_state;
BEGIN
  -- 1) Figure out which activity we're talking about
  IF TG_TABLE_NAME = 'paper_versions' THEN
    SELECT pra.activity_id
      INTO v_aid
      FROM peer_review_activities pra
     WHERE pra.paper_id = NEW.paper_id
     ORDER BY pra.created_at DESC
     LIMIT 1;
  ELSE
    v_aid := NEW.activity_id;
  END IF;

  IF v_aid IS NULL THEN
    RETURN NEW;  -- no activity found, bail out
  END IF;

  -- 2) Gather counts and template rules
  SELECT
    pra.current_state,
    prt.review_rounds,
    prt.reviewer_count     AS required_reviewers,
    COUNT(rtm.*)           AS joined_reviewers,
    COUNT(*) FILTER (WHERE rs.round_number = 1)   AS round1_reviews,
    COUNT(*) FILTER (WHERE ar.round_number = 1)   AS response1_count,
    COUNT(*) FILTER (WHERE rs.round_number = 2)   AS round2_reviews,
    COUNT(*) FILTER (WHERE ar.round_number = 2)   AS response2_count,
    COUNT(*) FILTER (WHERE rs.round_number = 999) AS eval_reviews,
    COUNT(ag.*)            AS awards_count
  INTO v_stats
  FROM peer_review_activities pra
  JOIN peer_review_templates prt
    ON pra.template_id = prt.template_id
  LEFT JOIN reviewer_team_members rtm
    ON rtm.activity_id = pra.activity_id
   AND rtm.status = 'joined'
  LEFT JOIN review_submissions rs
    ON rs.activity_id = pra.activity_id
    AND rs.reviewer_id = rtm.user_id
  LEFT JOIN author_responses ar
    ON ar.activity_id = pra.activity_id
  LEFT JOIN awards_given ag
    ON ag.activity_id = pra.activity_id
  WHERE pra.activity_id = v_aid
  GROUP BY pra.current_state, prt.review_rounds, prt.reviewer_count;

  -- 3) Decide the next state
  v_next := CASE
    WHEN v_stats.current_state = 'submitted'
         AND v_stats.joined_reviewers >= v_stats.required_reviewers
      THEN 'review_round_1'
    WHEN v_stats.current_state = 'review_round_1'
         AND v_stats.round1_reviews >= v_stats.joined_reviewers
      THEN 'author_response_1'
    WHEN v_stats.current_state = 'author_response_1'
         AND v_stats.response1_count > 0
      THEN CASE
             WHEN v_stats.review_rounds > 1 THEN 'review_round_2'
             ELSE 'evaluation'
           END
    WHEN v_stats.current_state = 'review_round_2'
         AND v_stats.round2_reviews >= v_stats.joined_reviewers
      THEN 'author_response_2'
    WHEN v_stats.current_state = 'author_response_2'
         AND v_stats.response2_count > 0
      THEN 'evaluation'
    WHEN v_stats.current_state = 'evaluation'
         AND v_stats.eval_reviews >= v_stats.joined_reviewers
      THEN 'awarding'
    WHEN v_stats.current_state = 'awarding'
         AND v_stats.awards_count >= (v_stats.joined_reviewers + 1) * 3
      THEN 'completed'
    ELSE NULL
  END;

  -- 4) If there *is* a next state, update it + set the new deadline
  IF v_next IS NOT NULL THEN
    UPDATE peer_review_activities
       SET current_state  = v_next,
           stage_deadline = CASE
                              WHEN v_next::text LIKE 'review_round_%'   THEN NOW() + INTERVAL '14 days'
                              WHEN v_next::text LIKE 'author_response_%' THEN NOW() + INTERVAL '14 days'
                              WHEN v_next = 'evaluation'::activity_state THEN NOW() + INTERVAL '7 days'
                              WHEN v_next = 'awarding'::activity_state   THEN NOW() + INTERVAL '7 days'
                              ELSE NULL
                            END
     WHERE activity_id = v_aid;

    INSERT INTO pr_activity_state_log (
      activity_id,
      old_state,
      new_state,
      changed_at
    ) VALUES (
      v_aid,
      v_stats.current_state,
      v_next,
      NOW()
    );
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Then re-create your triggers exactly as before:
DROP TRIGGER IF EXISTS trg_pr_on_join    ON reviewer_team_members;
DROP TRIGGER IF EXISTS trg_pr_on_review  ON review_submissions;
DROP TRIGGER IF EXISTS trg_pr_on_response ON author_responses;
DROP TRIGGER IF EXISTS trg_pr_on_version ON paper_versions;
DROP TRIGGER IF EXISTS trg_pr_on_award   ON awards_given;

CREATE TRIGGER trg_pr_on_join
  AFTER INSERT OR UPDATE OF status ON reviewer_team_members
  FOR EACH ROW
  WHEN (NEW.status = 'joined')
  EXECUTE FUNCTION public.pr_advance_state();

-- After a review submission
CREATE TRIGGER trg_pr_on_review
  AFTER INSERT ON review_submissions
  FOR EACH ROW
  WHEN (NEW.round_number IS NOT NULL)
  EXECUTE FUNCTION public.pr_advance_state();

-- After an author response
CREATE TRIGGER trg_pr_on_response
  AFTER INSERT ON author_responses
  FOR EACH ROW
  WHEN (NEW.round_number IS NOT NULL)
  EXECUTE FUNCTION public.pr_advance_state();

-- After a new paper version
CREATE TRIGGER trg_pr_on_version
  AFTER INSERT ON paper_versions
  FOR EACH ROW
  EXECUTE FUNCTION public.pr_advance_state();

-- After an award is given
CREATE TRIGGER trg_pr_on_award
  AFTER INSERT ON awards_given
  FOR EACH ROW
  EXECUTE FUNCTION public.pr_advance_state();

-- Add index on state log table for faster lookups and writes
CREATE INDEX IF NOT EXISTS idx_pr_activity_state_log_activity_time
  ON pr_activity_state_log(activity_id, changed_at);
