-- =============================================
-- 00000000000007_pr_participants.sql
-- Peer Review Domain: Reviewers and Teams (Simplified)
-- =============================================

-- Create ENUMs for reviewer system
DO $$ BEGIN
  CREATE TYPE reviewer_status AS ENUM ('joined', 'locked_in', 'removed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE reviewer_status IS 'Status of reviewer in a team (simplified)';

-- Create ENUM for PR activity roles (unified permission system)
DO $$ BEGIN
  CREATE TYPE pr_activity_role AS ENUM (
    'corresponding_author',
    'spectating_author', 
    'reviewer',
    'reader',
    'spectating_admin'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE pr_activity_role IS 'Unified roles for PR activity permissions';

-- Reviewer team members table
CREATE TABLE IF NOT EXISTS pr_reviewer_teams (
  team_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  status reviewer_status NOT NULL DEFAULT 'joined',
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  commitment_deadline TIMESTAMPTZ, -- 72 hours from joined_at
  locked_in_at TIMESTAMPTZ, -- When they submitted initial evaluation
  removed_at TIMESTAMPTZ,
  removal_reason TEXT, -- Why they were removed (timeout, etc.)
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, user_id)
);

COMMENT ON TABLE pr_reviewer_teams IS 'Reviewer team members for peer review activities';
COMMENT ON COLUMN pr_reviewer_teams.team_id IS 'Primary key for the team membership';
COMMENT ON COLUMN pr_reviewer_teams.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_reviewer_teams.user_id IS 'Foreign key to user_accounts (reviewer)';
COMMENT ON COLUMN pr_reviewer_teams.status IS 'Current status of the reviewer';
COMMENT ON COLUMN pr_reviewer_teams.joined_at IS 'When the reviewer joined the team';
COMMENT ON COLUMN pr_reviewer_teams.commitment_deadline IS '72 hours from join time for initial evaluation';
COMMENT ON COLUMN pr_reviewer_teams.locked_in_at IS 'When reviewer submitted initial evaluation and locked in';
COMMENT ON COLUMN pr_reviewer_teams.removed_at IS 'When the reviewer was removed';
COMMENT ON COLUMN pr_reviewer_teams.removal_reason IS 'Reason for removal (timeout, manual, etc.)';

-- Unified permission table for PR activities (replaces pr_participants)
CREATE TABLE IF NOT EXISTS pr_activity_permissions (
  permission_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  role pr_activity_role NOT NULL,
  granted_at TIMESTAMPTZ DEFAULT NOW(),
  granted_by INTEGER REFERENCES user_accounts(user_id),
  UNIQUE(activity_id, user_id)
);

COMMENT ON TABLE pr_activity_permissions IS 'Unified permission system for PR activities';
COMMENT ON COLUMN pr_activity_permissions.permission_id IS 'Primary key for permission record';
COMMENT ON COLUMN pr_activity_permissions.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_activity_permissions.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN pr_activity_permissions.role IS 'User role in this specific activity';
COMMENT ON COLUMN pr_activity_permissions.granted_at IS 'When the permission was granted';
COMMENT ON COLUMN pr_activity_permissions.granted_by IS 'Who granted this permission (optional)';

-- Timeline events table for comprehensive activity history
CREATE TABLE IF NOT EXISTS pr_timeline_events (
  event_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  stage TEXT,
  user_id INTEGER REFERENCES user_accounts(user_id),
  user_name TEXT,
  title TEXT NOT NULL,
  description TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE pr_timeline_events IS 'Complete timeline of all events in PR activities';
COMMENT ON COLUMN pr_timeline_events.event_id IS 'Primary key for the event';
COMMENT ON COLUMN pr_timeline_events.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_timeline_events.event_type IS 'Type of event: state_transition, review_submitted, etc';
COMMENT ON COLUMN pr_timeline_events.stage IS 'Stage where event occurred';
COMMENT ON COLUMN pr_timeline_events.user_id IS 'User who triggered the event';
COMMENT ON COLUMN pr_timeline_events.user_name IS 'Name of user (denormalized for display)';
COMMENT ON COLUMN pr_timeline_events.title IS 'Event title for display';
COMMENT ON COLUMN pr_timeline_events.description IS 'Detailed description of the event';
COMMENT ON COLUMN pr_timeline_events.metadata IS 'Additional event metadata';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_activity_id ON pr_reviewer_teams (activity_id);

-- Enhanced indexes for pr_timeline_events for workflow system
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_activity_id ON pr_timeline_events (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_type_stage ON pr_timeline_events (event_type, stage);
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_created_at ON pr_timeline_events (created_at DESC);

-- Composite index for stage transition lookups
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_activity_stage_created 
ON pr_timeline_events (activity_id, stage, created_at DESC) 
WHERE event_type = 'state_transition';
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_user_id ON pr_reviewer_teams (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_status ON pr_reviewer_teams (status);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_commitment_deadline ON pr_reviewer_teams (commitment_deadline);
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_joined_at ON pr_reviewer_teams (joined_at);

-- Performance optimization index for progression system queries
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_activity_status 
ON pr_reviewer_teams(activity_id, status) 
WHERE status IN ('joined', 'locked_in');

-- =============================================
-- PERFORMANCE OPTIMIZATION INDEXES - PR Activity Page
-- =============================================
-- Following DEVELOPMENT_PRINCIPLES.md: Database as Source of Truth for performance
-- Indexes optimized for the main PR activity data loading JOIN operations

-- Covering index for reviewer teams JOIN optimization (avoids table lookup)
CREATE INDEX IF NOT EXISTS idx_pr_reviewer_teams_activity_user_covering
ON pr_reviewer_teams (activity_id, user_id)
INCLUDE (status, joined_at, locked_in_at, team_id, commitment_deadline, removed_at, removal_reason);

-- Covering index for timeline events JOIN optimization (avoids table lookup)
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_activity_type_covering
ON pr_timeline_events (activity_id, event_type)
INCLUDE (created_at, user_id, title, stage, description, metadata, user_name, event_id);

-- Optimized index for timeline events ordering (most common query pattern)
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_activity_created_desc
ON pr_timeline_events (activity_id, created_at DESC);

-- Indexes for pr_activity_permissions
CREATE INDEX IF NOT EXISTS idx_pr_activity_permissions_activity ON pr_activity_permissions(activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_activity_permissions_user ON pr_activity_permissions(user_id);
CREATE INDEX IF NOT EXISTS idx_pr_activity_permissions_role ON pr_activity_permissions(role);

-- Indexes for pr_timeline_events
CREATE INDEX IF NOT EXISTS idx_pr_timeline_created ON pr_timeline_events(created_at);
CREATE INDEX IF NOT EXISTS idx_pr_timeline_type ON pr_timeline_events(event_type);
CREATE INDEX IF NOT EXISTS idx_pr_timeline_user ON pr_timeline_events(user_id);

-- Commitment deadline logic moved to application services

-- Basic triggers
CREATE TRIGGER update_pr_reviewer_teams_updated_at
  BEFORE UPDATE ON pr_reviewer_teams
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at(); 

-- RLS policies for new tables
ALTER TABLE pr_activity_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE pr_timeline_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can view activity permissions"
  ON pr_activity_permissions FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can insert activity permissions"
  ON pr_activity_permissions FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "Authenticated users can update activity permissions"
  ON pr_activity_permissions FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Authenticated users can delete activity permissions"
  ON pr_activity_permissions FOR DELETE
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can view timeline events"
  ON pr_timeline_events FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can insert timeline events"
  ON pr_timeline_events FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "Authenticated users can update timeline events"
  ON pr_timeline_events FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Authenticated users can delete timeline events"
  ON pr_timeline_events FOR DELETE
  TO authenticated
  USING (true);

-- Data migration: Populate pr_activity_permissions from existing data
-- Migrate paper contributors as authors (corresponding vs spectating)
INSERT INTO pr_activity_permissions (activity_id, user_id, role)
SELECT DISTINCT
  p.activity_id,
  pc.user_id,
  CASE 
    WHEN pc.is_corresponding THEN 'corresponding_author'::pr_activity_role
    ELSE 'spectating_author'::pr_activity_role
  END
FROM pr_activities p
JOIN papers pap ON p.paper_id = pap.paper_id  
JOIN paper_contributors pc ON pap.paper_id = pc.paper_id
ON CONFLICT (activity_id, user_id) DO NOTHING;

-- Migrate reviewer team members as reviewers
INSERT INTO pr_activity_permissions (activity_id, user_id, role)
SELECT DISTINCT
  rt.activity_id,
  rt.user_id,
  'reviewer'::pr_activity_role
FROM pr_reviewer_teams rt
WHERE rt.status IN ('joined', 'locked_in')
ON CONFLICT (activity_id, user_id) DO NOTHING;

-- Grant permissions
GRANT SELECT ON pr_activity_permissions TO authenticated;
GRANT SELECT ON pr_timeline_events TO authenticated;
GRANT SELECT, INSERT, UPDATE ON pr_reviewer_teams TO authenticated;

-- =============================================
-- HELPER FUNCTION TO CHECK IF USER IS PAPER CONTRIBUTOR
-- =============================================
-- This function bypasses RLS to check if a user is a contributor on a paper
-- Following DEVELOPMENT_PRINCIPLES.md: Prevents infinite recursion
-- This is safe because:
-- 1. It only checks for the authenticated user (auth.uid())
-- 2. It's read-only
-- 3. It prevents papers<->paper_contributors circular dependency
CREATE OR REPLACE FUNCTION is_paper_contributor(p_paper_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.paper_contributors pc
    WHERE pc.paper_id = p_paper_id
    AND pc.user_id = (SELECT user_id FROM public.user_accounts WHERE auth_id = auth.uid())
  );
$$;

COMMENT ON FUNCTION is_paper_contributor(INTEGER) IS 'Checks if current user is a contributor on the given paper. Uses SECURITY DEFINER to bypass RLS and prevent infinite recursion between papers and paper_contributors policies.';

-- =============================================
-- EXTEND PAPER RLS POLICIES
-- =============================================
-- Now that pr_activity_permissions exists, add activity participant access to papers and contributors

-- Extend papers SELECT policy with activity participant access
DROP POLICY IF EXISTS papers_select_own_or_contributor_or_service ON papers;

CREATE POLICY papers_select_own_or_participant_or_service ON papers
  FOR SELECT
  USING (
    uploaded_by = auth_user_id() OR
    -- Use helper function to avoid recursion (doesn't trigger paper_contributors policy)
    is_paper_contributor(paper_id) OR
    EXISTS (
      SELECT 1 FROM public.pr_activity_permissions pap
      JOIN public.pr_activities pa ON pa.activity_id = pap.activity_id
      WHERE pa.paper_id = papers.paper_id
      AND pap.user_id = auth_user_id()
    ) OR
    auth.role() = 'service_role'
  );

-- Extend paper_contributors SELECT policy with activity participant access
DROP POLICY IF EXISTS paper_contributors_select_own_or_service ON paper_contributors;

CREATE POLICY paper_contributors_select_own_or_participant_or_service ON paper_contributors
  FOR SELECT
  USING (
    -- Direct check: User is a contributor on this paper (no subquery on same table)
    user_id = auth_user_id() OR
    -- User owns the paper (check papers table directly, not its policy)
    EXISTS (
      SELECT 1 FROM public.papers p
      WHERE p.paper_id = paper_contributors.paper_id
      AND p.uploaded_by = auth_user_id()
    ) OR
    -- User has activity permission (now safe - pr_activity_permissions exists)
    EXISTS (
      SELECT 1 FROM public.pr_activity_permissions pap
      JOIN public.pr_activities pa ON pa.activity_id = pap.activity_id
      WHERE pa.paper_id = paper_contributors.paper_id
      AND pap.user_id = auth_user_id()
    ) OR
    auth.role() = 'service_role'
  ); 