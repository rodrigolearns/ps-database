-- =============================================
-- 00000000000025_pr_awards.sql
-- PR Activity Domain: Award Distribution and Rankings
-- =============================================
-- Award distribution system with token allocation

-- =============================================
-- 1. PR Award Distributions Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_award_distributions (
  distribution_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  giver_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  receiver_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  award_type TEXT NOT NULL CHECK (award_type IN ('insightful_analysis', 'paper_challenger', 'clarity_champion', 'methodology_mentor')),
  points_awarded INTEGER NOT NULL,
  distributed_at TIMESTAMPTZ DEFAULT NOW(),
  
  CONSTRAINT no_self_awarding CHECK (giver_id != receiver_id),
  CONSTRAINT unique_award_per_giver_receiver UNIQUE (activity_id, giver_id, receiver_id, award_type)
);

COMMENT ON TABLE pr_award_distributions IS 'Award distributions from authors and reviewers to reviewers';
COMMENT ON COLUMN pr_award_distributions.distribution_id IS 'Primary key';
COMMENT ON COLUMN pr_award_distributions.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_award_distributions.giver_id IS 'User who gave the award';
COMMENT ON COLUMN pr_award_distributions.receiver_id IS 'User who received the award';
COMMENT ON COLUMN pr_award_distributions.award_type IS 'Award type (insightful_analysis, etc.)';
COMMENT ON COLUMN pr_award_distributions.points_awarded IS 'Points for this award';

-- =============================================
-- 2. PR Reviewer Rankings Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_reviewer_rankings (
  ranking_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  final_rank INTEGER NOT NULL,
  total_points INTEGER NOT NULL DEFAULT 0,
  tokens_awarded INTEGER NOT NULL DEFAULT 0,
  ranked_at TIMESTAMPTZ DEFAULT NOW(),
  
  CONSTRAINT unique_ranking_per_activity_reviewer UNIQUE (activity_id, reviewer_id),
  CONSTRAINT unique_rank_per_activity UNIQUE (activity_id, final_rank)
);

COMMENT ON TABLE pr_reviewer_rankings IS 'Final reviewer rankings and token awards';
COMMENT ON COLUMN pr_reviewer_rankings.ranking_id IS 'Primary key';
COMMENT ON COLUMN pr_reviewer_rankings.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_reviewer_rankings.reviewer_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN pr_reviewer_rankings.final_rank IS 'Final rank (1, 2, 3, etc.)';
COMMENT ON COLUMN pr_reviewer_rankings.total_points IS 'Total points from awards';
COMMENT ON COLUMN pr_reviewer_rankings.tokens_awarded IS 'Tokens awarded based on rank';

-- =============================================
-- 3. PR Award Distribution Status Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_award_distribution_status (
  status_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  participant_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  participant_type TEXT NOT NULL CHECK (participant_type IN ('author', 'reviewer')),
  has_distributed_awards BOOLEAN DEFAULT false,
  distributed_at TIMESTAMPTZ,
  
  CONSTRAINT unique_status_per_activity_participant UNIQUE (activity_id, participant_id)
);

COMMENT ON TABLE pr_award_distribution_status IS 'Completion status of award distribution for each participant';
COMMENT ON COLUMN pr_award_distribution_status.status_id IS 'Primary key';
COMMENT ON COLUMN pr_award_distribution_status.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_award_distribution_status.participant_id IS 'User who needs to distribute awards';
COMMENT ON COLUMN pr_award_distribution_status.participant_type IS 'Author or reviewer';
COMMENT ON COLUMN pr_award_distribution_status.has_distributed_awards IS 'Whether participant completed distribution';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_pr_award_distributions_activity ON pr_award_distributions (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_award_distributions_giver ON pr_award_distributions (giver_id);
CREATE INDEX IF NOT EXISTS idx_pr_award_distributions_receiver ON pr_award_distributions (receiver_id);
CREATE INDEX IF NOT EXISTS idx_pr_award_distributions_type ON pr_award_distributions (award_type);

CREATE INDEX IF NOT EXISTS idx_pr_reviewer_rankings_activity ON pr_reviewer_rankings (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_rankings_reviewer ON pr_reviewer_rankings (reviewer_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_rankings_rank ON pr_reviewer_rankings (activity_id, final_rank);

CREATE INDEX IF NOT EXISTS idx_pr_award_distribution_status_activity ON pr_award_distribution_status (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_award_distribution_status_participant ON pr_award_distribution_status (participant_id);
CREATE INDEX IF NOT EXISTS idx_pr_award_distribution_status_completed ON pr_award_distribution_status (activity_id, has_distributed_awards) WHERE has_distributed_awards = true;

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE pr_award_distributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE pr_reviewer_rankings ENABLE ROW LEVEL SECURITY;
ALTER TABLE pr_award_distribution_status ENABLE ROW LEVEL SECURITY;

-- Award distributions: Participants can see all (transparency after awarding completes)
CREATE POLICY pr_award_distributions_select_participant ON pr_award_distributions
  FOR SELECT
  USING (
    giver_id = (SELECT auth_user_id()) OR
    receiver_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_award_distributions.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY pr_award_distributions_modify_service_role_only ON pr_award_distributions
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Reviewer rankings: Participants can see all rankings
CREATE POLICY pr_reviewer_rankings_select_participant ON pr_reviewer_rankings
  FOR SELECT
  USING (
    reviewer_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_reviewer_rankings.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY pr_reviewer_rankings_modify_service_role_only ON pr_reviewer_rankings
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Award distribution status: Participants can see status
CREATE POLICY pr_award_distribution_status_select_participant ON pr_award_distribution_status
  FOR SELECT
  USING (
    participant_id = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_award_distribution_status.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY pr_award_distribution_status_modify_service_role_only ON pr_award_distribution_status
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

