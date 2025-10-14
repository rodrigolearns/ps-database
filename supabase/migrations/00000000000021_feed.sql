-- ================================================================================================
-- FEED SYSTEM MIGRATION
-- ================================================================================================
-- Performance indexes and optimizations for the server-side feed filtering system
-- Following DEVELOPMENT_PRINCIPLES.md: Database is Source of Truth

-- Index for main feed query: funded activities ordered by posting date
-- This supports the main WHERE clause (escrow_balance > 0) and ORDER BY (posted_at DESC)
CREATE INDEX idx_pr_activities_feed_ordered 
ON pr_activities (escrow_balance, posted_at DESC) 
WHERE escrow_balance > 0;

-- Index for user reviewer team exclusion lookups
-- Optimizes checking if user is already in a reviewer team
CREATE INDEX idx_pr_reviewer_teams_user_lookup 
ON pr_reviewer_teams (user_id, activity_id);

-- Index for paper author exclusion lookups
-- Optimizes checking if user is an author of the paper
CREATE INDEX idx_paper_contributors_user_lookup 
ON paper_contributors (user_id, paper_id);

-- Composite index for activity-paper joins (used frequently in feed queries)
CREATE INDEX idx_pr_activities_paper_lookup 
ON pr_activities (paper_id, activity_id);

-- Index for template-activity joins (needed for reviewer_count)
CREATE INDEX idx_pr_activities_template_lookup 
ON pr_activities (template_id, activity_id);
