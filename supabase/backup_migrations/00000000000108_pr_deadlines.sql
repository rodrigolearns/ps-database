-- =============================================
-- 00000000000105_pr_deadlines.sql
-- Schedule pg_cron jobs for reviewer penalties
-- =============================================

-- Create a config table for deadline parameters
CREATE TABLE IF NOT EXISTS pr_deadline_config (
  config_key TEXT PRIMARY KEY,
  config_value TEXT NOT NULL
);

-- Insert default values if not exists
INSERT INTO pr_deadline_config (config_key, config_value)
VALUES 
  ('late_penalty_hours', '24'),
  ('kickout_penalty_days', '7')
ON CONFLICT (config_key) DO NOTHING;

-- Unschedule existing jobs to avoid duplicates (with error handling)
DO $$
BEGIN
  PERFORM cron.unschedule('fine-late-reviews');
EXCEPTION
  WHEN OTHERS THEN NULL; -- Ignore errors if job doesn't exist
END $$;

DO $$
BEGIN
  PERFORM cron.unschedule('kickout-weekly-overdue');
EXCEPTION
  WHEN OTHERS THEN NULL; -- Ignore errors if job doesn't exist
END $$;

DO $$
BEGIN
  PERFORM cron.unschedule('reviewer-deadline-checks');
EXCEPTION
  WHEN OTHERS THEN NULL; -- Ignore errors if job doesn't exist
END $$;

-- Combined job that handles both late penalties and kickouts
SELECT cron.schedule(
  'reviewer-deadline-checks',
  '0 * * * *',   -- every hour
  $$
    -- Get configuration values
    WITH config AS (
      SELECT 
        (SELECT config_value::int FROM pr_deadline_config WHERE config_key = 'late_penalty_hours') AS late_hours,
        (SELECT config_value::int FROM pr_deadline_config WHERE config_key = 'kickout_penalty_days') AS kickout_days
    ),
    
    -- Apply late penalties (>24h overdue by default)
    late_penalties AS (
      INSERT INTO reviewer_penalties(activity_id, user_id, penalty_type, amount)
      SELECT rs.activity_id, rs.reviewer_id, 'late', 1
      FROM review_submissions rs
      JOIN peer_review_activities pra ON pra.activity_id = rs.activity_id
      CROSS JOIN config
      WHERE pra.stage_deadline + (config.late_hours * INTERVAL '1 hour') < NOW()
        AND pra.current_state = format('review_round_%s', rs.round_number)::activity_state
        AND NOT EXISTS (
          SELECT 1 FROM reviewer_penalties rp
           WHERE rp.activity_id = rs.activity_id
             AND rp.user_id = rs.reviewer_id
             AND rp.penalty_type = 'late'
        )
      RETURNING activity_id, user_id
    ),
    
    -- Identify reviewers to kick out (>7 days overdue by default)
    to_kick AS (
      SELECT rs.activity_id, rs.reviewer_id
      FROM review_submissions rs
      JOIN peer_review_activities pra ON pra.activity_id = rs.activity_id
      CROSS JOIN config
      WHERE pra.stage_deadline + (config.kickout_days * INTERVAL '1 day') < NOW()
        AND pra.current_state = format('review_round_%s', rs.round_number)::activity_state
        AND NOT EXISTS (
          SELECT 1 FROM reviewer_penalties rp
           WHERE rp.activity_id = rs.activity_id
             AND rp.user_id = rs.reviewer_id
             AND rp.penalty_type = 'kicked_out'
        )
    )
    
    -- Apply kickout penalties
    INSERT INTO reviewer_penalties(activity_id, user_id, penalty_type, amount)
    SELECT activity_id, user_id, 'kicked_out', 1 
    FROM to_kick;

    -- Update team-member status for kicked out reviewers
    UPDATE reviewer_team_members rtm
    SET status = 'kicked_out', 
        removed_reason = 'Missed deadline by ' || 
          (SELECT kickout_days FROM config) || ' days'
    FROM to_kick
    WHERE rtm.activity_id = to_kick.activity_id
      AND rtm.user_id = to_kick.user_id;
  $$::text
);
