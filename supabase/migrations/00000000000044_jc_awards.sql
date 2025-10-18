-- =============================================
-- 00000000000044_jc_awards.sql
-- JC Activity Domain: Award Distribution (No Tokens)
-- =============================================
-- Recognition awards for journal clubs (no token rewards)

-- =============================================
-- 1. JC Award Distributions Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_award_distributions (
  distribution_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES jc_activities(activity_id) ON DELETE CASCADE,
  giver_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  receiver_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  award_type TEXT NOT NULL CHECK (award_type IN ('insightful_analysis', 'paper_challenger', 'clarity_champion', 'methodology_mentor')),
  points_awarded INTEGER NOT NULL,  -- Points for recognition (no token conversion)
  distributed_at TIMESTAMPTZ DEFAULT NOW(),
  
  CONSTRAINT no_self_awarding_jc CHECK (giver_id != receiver_id),
  CONSTRAINT unique_award_per_giver_receiver_jc UNIQUE (activity_id, giver_id, receiver_id, award_type)
);

COMMENT ON TABLE jc_award_distributions IS 'Award distributions for JC activities (recognition only, no tokens)';
COMMENT ON COLUMN jc_award_distributions.distribution_id IS 'Primary key';
COMMENT ON COLUMN jc_award_distributions.activity_id IS 'Foreign key to jc_activities';
COMMENT ON COLUMN jc_award_distributions.giver_id IS 'User who gave the award';
COMMENT ON COLUMN jc_award_distributions.receiver_id IS 'User who received the award';
COMMENT ON COLUMN jc_award_distributions.award_type IS 'Award type';
COMMENT ON COLUMN jc_award_distributions.points_awarded IS 'Recognition points (not converted to tokens)';

-- =============================================
-- 2. JC Award Distribution Status Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_award_distribution_status (
  status_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES jc_activities(activity_id) ON DELETE CASCADE,
  participant_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  has_distributed_awards BOOLEAN DEFAULT false,
  distributed_at TIMESTAMPTZ,
  
  CONSTRAINT unique_status_per_jc_participant UNIQUE (activity_id, participant_id)
);

COMMENT ON TABLE jc_award_distribution_status IS 'Award distribution completion status for JC participants';
COMMENT ON COLUMN jc_award_distribution_status.status_id IS 'Primary key';
COMMENT ON COLUMN jc_award_distribution_status.activity_id IS 'Foreign key to jc_activities';
COMMENT ON COLUMN jc_award_distribution_status.participant_id IS 'User who needs to distribute awards';
COMMENT ON COLUMN jc_award_distribution_status.has_distributed_awards IS 'Whether completed distribution';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_jc_award_distributions_activity ON jc_award_distributions (activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_award_distributions_giver ON jc_award_distributions (giver_id);
CREATE INDEX IF NOT EXISTS idx_jc_award_distributions_receiver ON jc_award_distributions (receiver_id);
CREATE INDEX IF NOT EXISTS idx_jc_award_distributions_type ON jc_award_distributions (award_type);

CREATE INDEX IF NOT EXISTS idx_jc_award_distribution_status_activity ON jc_award_distribution_status (activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_award_distribution_status_participant ON jc_award_distribution_status (participant_id);

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE jc_award_distributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE jc_award_distribution_status ENABLE ROW LEVEL SECURITY;

-- Participants can see awards
CREATE POLICY jc_award_distributions_select_participant ON jc_award_distributions
  FOR SELECT
  USING (
    giver_id = (SELECT auth_user_id()) OR
    receiver_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM jc_activity_permissions jap
      WHERE jap.activity_id = jc_award_distributions.activity_id
      AND jap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY jc_award_distributions_modify_service_role_only ON jc_award_distributions
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Participants can see distribution status
CREATE POLICY jc_award_distribution_status_select_participant ON jc_award_distribution_status
  FOR SELECT
  USING (
    participant_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM jc_activity_permissions jap
      WHERE jap.activity_id = jc_award_distribution_status.activity_id
      AND jap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY jc_award_distribution_status_modify_service_role_only ON jc_award_distribution_status
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

