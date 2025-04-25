-- =============================================
-- 00000000000105_pr_deadlines.sql
-- Schedule pg_cron jobs for reviewer penalties
-- =============================================

-- Fine 1 token for any review round that's >24h overdue
SELECT cron.schedule(
  'fine-late-reviews',
  '0 * * * *',   -- every hour at minute 0
  $$
    INSERT INTO reviewer_penalties(activity_id, user_id, penalty_type, amount)
    SELECT rs.activity_id, rs.reviewer_id, 'late', 1
    FROM review_submissions rs
    JOIN peer_review_activities pra ON pra.activity_id = rs.activity_id
    WHERE pra.stage_deadline + INTERVAL '1 day' < NOW()
      AND pra.current_state = format('review_round_%s', rs.round_number)::activity_state
      AND NOT EXISTS (
        SELECT 1 FROM reviewer_penalties rp
         WHERE rp.activity_id = rs.activity_id
           AND rp.user_id = rs.reviewer_id
           AND rp.penalty_type = 'late'
      );
  $$::text
);

-- Kick out (and fine) reviewers >7 days overdue
SELECT cron.schedule(
  'kickout-weekly-overdue',
  '30 * * * *',  -- every hour at minute 30
  $$
    WITH to_kick AS (
      SELECT rs.activity_id, rs.reviewer_id
      FROM review_submissions rs
      JOIN peer_review_activities pra ON pra.activity_id = rs.activity_id
      WHERE pra.stage_deadline + INTERVAL '7 days' < NOW()
        AND pra.current_state = format('review_round_%s', rs.round_number)::activity_state
        AND NOT EXISTS (
          SELECT 1 FROM reviewer_penalties rp
           WHERE rp.activity_id = rs.activity_id
             AND rp.user_id = rs.reviewer_id
             AND rp.penalty_type = 'kicked_out'
        )
    )
    INSERT INTO reviewer_penalties(activity_id, user_id, penalty_type, amount)
    SELECT activity_id, user_id, 'kicked_out', 1 FROM to_kick;

    -- Also update their team-member status
    UPDATE reviewer_team_members rtm
    SET status = 'kicked_out', removed_reason = 'Missed deadline by 7 days'
    FROM to_kick
    WHERE rtm.activity_id = to_kick.activity_id
      AND rtm.user_id = to_kick.user_id;
  $$::text
);
