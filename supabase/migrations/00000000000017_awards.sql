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