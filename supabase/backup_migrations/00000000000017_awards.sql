-- =============================================
-- 00000000000017_awards.sql  
-- Simplified Award Distribution and Ranking System
-- =============================================

-- Award distributions table - tracks who gave what award to whom
CREATE TABLE IF NOT EXISTS pr_award_distributions (
  distribution_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  giver_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  receiver_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  award_type TEXT NOT NULL CHECK (award_type IN ('insightful_analysis', 'paper_challenger', 'clarity_champion', 'methodology_mentor')),
  points_awarded INTEGER NOT NULL,
  distributed_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Ensure no self-awarding and unique award type per giver-receiver pair per activity
  CONSTRAINT no_self_awarding CHECK (giver_id != receiver_id),
  CONSTRAINT unique_award_per_giver_receiver UNIQUE (activity_id, giver_id, receiver_id, award_type)
);

COMMENT ON TABLE pr_award_distributions IS 'Tracks award distributions from authors and reviewers to reviewers';
COMMENT ON COLUMN pr_award_distributions.distribution_id IS 'Primary key for the award distribution';
COMMENT ON COLUMN pr_award_distributions.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_award_distributions.giver_id IS 'User who gave the award (author or reviewer)';
COMMENT ON COLUMN pr_award_distributions.receiver_id IS 'User who received the award (always a reviewer)';
COMMENT ON COLUMN pr_award_distributions.award_type IS 'Type of award given (insightful_analysis, paper_challenger, etc.)';
COMMENT ON COLUMN pr_award_distributions.points_awarded IS 'Points awarded for this award type';
COMMENT ON COLUMN pr_award_distributions.distributed_at IS 'When the award was distributed';

-- Final reviewer rankings table - stores the final rankings after awarding completes
CREATE TABLE IF NOT EXISTS pr_reviewer_rankings (
  ranking_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  final_rank INTEGER NOT NULL,
  total_points INTEGER NOT NULL DEFAULT 0,
  tokens_awarded INTEGER NOT NULL DEFAULT 0,
  ranked_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Ensure unique ranking per activity-reviewer pair
  CONSTRAINT unique_ranking_per_activity_reviewer UNIQUE (activity_id, reviewer_id),
  -- Ensure unique rank per activity
  CONSTRAINT unique_rank_per_activity UNIQUE (activity_id, final_rank)
);

COMMENT ON TABLE pr_reviewer_rankings IS 'Final reviewer rankings and token awards after awarding stage completion';
COMMENT ON COLUMN pr_reviewer_rankings.ranking_id IS 'Primary key for the ranking';
COMMENT ON COLUMN pr_reviewer_rankings.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_reviewer_rankings.reviewer_id IS 'Foreign key to user_accounts (reviewer)';
COMMENT ON COLUMN pr_reviewer_rankings.final_rank IS 'Final rank (1st, 2nd, 3rd, etc.)';
COMMENT ON COLUMN pr_reviewer_rankings.total_points IS 'Total points earned from all awards';
COMMENT ON COLUMN pr_reviewer_rankings.tokens_awarded IS 'Tokens awarded based on ranking';
COMMENT ON COLUMN pr_reviewer_rankings.ranked_at IS 'When the final ranking was established';

-- Award distribution status tracking - tracks who has completed their award distribution
CREATE TABLE IF NOT EXISTS pr_award_distribution_status (
  status_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  participant_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  participant_type TEXT NOT NULL CHECK (participant_type IN ('author', 'reviewer')),
  has_distributed_awards BOOLEAN DEFAULT FALSE,
  distributed_at TIMESTAMPTZ NULL,
  
  -- Ensure unique status per activity-participant pair
  CONSTRAINT unique_status_per_activity_participant UNIQUE (activity_id, participant_id)
);

COMMENT ON TABLE pr_award_distribution_status IS 'Tracks completion status of award distribution for each participant';
COMMENT ON COLUMN pr_award_distribution_status.status_id IS 'Primary key for the status';
COMMENT ON COLUMN pr_award_distribution_status.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_award_distribution_status.participant_id IS 'User who needs to distribute awards';
COMMENT ON COLUMN pr_award_distribution_status.participant_type IS 'Whether participant is author or reviewer';
COMMENT ON COLUMN pr_award_distribution_status.has_distributed_awards IS 'Whether participant has completed award distribution';
COMMENT ON COLUMN pr_award_distribution_status.distributed_at IS 'When the participant completed award distribution';

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_pr_award_distributions_activity_id ON pr_award_distributions (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_award_distributions_giver_id ON pr_award_distributions (giver_id);
CREATE INDEX IF NOT EXISTS idx_pr_award_distributions_receiver_id ON pr_award_distributions (receiver_id);
CREATE INDEX IF NOT EXISTS idx_pr_award_distributions_award_type ON pr_award_distributions (award_type);

CREATE INDEX IF NOT EXISTS idx_pr_reviewer_rankings_activity_id ON pr_reviewer_rankings (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_rankings_reviewer_id ON pr_reviewer_rankings (reviewer_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_rankings_final_rank ON pr_reviewer_rankings (final_rank);

CREATE INDEX IF NOT EXISTS idx_pr_award_distribution_status_activity_id ON pr_award_distribution_status (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_award_distribution_status_participant_id ON pr_award_distribution_status (participant_id);

-- =============================================
-- RLS POLICIES FOR AWARDING TABLES
-- =============================================
-- Resolves security warnings: RLS disabled on pr_award_distributions, pr_reviewer_rankings, pr_award_distribution_status
-- Access pattern: Users see their own data + activity participants see all for transparency
-- Used by: reviewer_completed_activities view, awarding services

-- =============================================
-- 1. pr_reviewer_rankings
-- =============================================
ALTER TABLE pr_reviewer_rankings ENABLE ROW LEVEL SECURITY;

-- Reviewers can see their own rankings
-- Activity participants can see all rankings in their activity (for transparency)
CREATE POLICY pr_reviewer_rankings_select_own_or_participant ON pr_reviewer_rankings
  FOR SELECT
  USING (
    reviewer_id = (SELECT auth_user_id()) OR
    -- Activity participants can see all rankings (transparency in peer review)
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_reviewer_rankings.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify rankings (managed by awarding service)
CREATE POLICY pr_reviewer_rankings_insert_service_role_only ON pr_reviewer_rankings
  FOR INSERT
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY pr_reviewer_rankings_update_service_role_only ON pr_reviewer_rankings
  FOR UPDATE
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY pr_reviewer_rankings_delete_service_role_only ON pr_reviewer_rankings
  FOR DELETE
  USING ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_reviewer_rankings_select_own_or_participant ON pr_reviewer_rankings IS
  'Reviewers see own rankings, activity participants see all rankings for transparency';

-- =============================================
-- 2. pr_award_distributions
-- =============================================
ALTER TABLE pr_award_distributions ENABLE ROW LEVEL SECURITY;

-- Users can see awards they gave or received
-- Activity participants can see all awards in their activity
CREATE POLICY pr_award_distributions_select_participant ON pr_award_distributions
  FOR SELECT
  USING (
    giver_id = (SELECT auth_user_id()) OR
    receiver_id = (SELECT auth_user_id()) OR
    -- Activity participants can see all awards (transparency)
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_award_distributions.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify awards (managed by awarding service)
CREATE POLICY pr_award_distributions_insert_service_role_only ON pr_award_distributions
  FOR INSERT
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY pr_award_distributions_update_service_role_only ON pr_award_distributions
  FOR UPDATE
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY pr_award_distributions_delete_service_role_only ON pr_award_distributions
  FOR DELETE
  USING ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_award_distributions_select_participant ON pr_award_distributions IS
  'Users see awards they gave/received, activity participants see all for transparency';

-- =============================================
-- 3. pr_award_distribution_status
-- =============================================
ALTER TABLE pr_award_distribution_status ENABLE ROW LEVEL SECURITY;

-- Users can see their own distribution status
-- Activity participants can see all statuses in their activity
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

-- Only service role can modify distribution status
CREATE POLICY pr_award_distribution_status_modify_service_role_only ON pr_award_distribution_status
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_award_distribution_status_select_participant ON pr_award_distribution_status IS
  'Users see own status, activity participants see all statuses'; 