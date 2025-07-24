-- =============================================
-- 00000000000007_pr_participants.sql
-- Peer Review Domain: Reviewers and Teams (Simplified)
-- =============================================

-- Create ENUMs for reviewer system
DO $$ BEGIN
  CREATE TYPE reviewer_status AS ENUM ('joined', 'locked_in', 'removed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE reviewer_status IS 'Status of reviewer in a team (simplified)';

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

-- Unified participants table for all roles in PR activities
CREATE TABLE IF NOT EXISTS pr_participants (
  participant_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('author', 'reviewer', 'editor', 'observer')),
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'removed', 'joined', 'locked_in')),
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  left_at TIMESTAMPTZ,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, user_id, role)
);

COMMENT ON TABLE pr_participants IS 'Unified tracking of all participants in PR activities';
COMMENT ON COLUMN pr_participants.participant_id IS 'Primary key for participant record';
COMMENT ON COLUMN pr_participants.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_participants.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN pr_participants.role IS 'Participant role: author, reviewer, editor, observer';
COMMENT ON COLUMN pr_participants.status IS 'Current status of the participant';
COMMENT ON COLUMN pr_participants.joined_at IS 'When the participant joined the activity';
COMMENT ON COLUMN pr_participants.left_at IS 'When the participant left the activity';
COMMENT ON COLUMN pr_participants.metadata IS 'Additional metadata for the participant';

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

-- Indexes for pr_participants
CREATE INDEX IF NOT EXISTS idx_pr_participants_activity ON pr_participants(activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_participants_user ON pr_participants(user_id);
CREATE INDEX IF NOT EXISTS idx_pr_participants_role ON pr_participants(role);
CREATE INDEX IF NOT EXISTS idx_pr_participants_status ON pr_participants(status);

-- Indexes for pr_timeline_events
CREATE INDEX IF NOT EXISTS idx_pr_timeline_activity ON pr_timeline_events(activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_timeline_created ON pr_timeline_events(created_at);
CREATE INDEX IF NOT EXISTS idx_pr_timeline_type ON pr_timeline_events(event_type);
CREATE INDEX IF NOT EXISTS idx_pr_timeline_user ON pr_timeline_events(user_id);

-- Simple trigger to set commitment deadline
CREATE OR REPLACE FUNCTION set_commitment_deadline()
RETURNS TRIGGER AS $$
BEGIN
  -- Set 72-hour deadline when joining
  IF NEW.status = 'joined' AND OLD.status IS DISTINCT FROM 'joined' THEN
    NEW.commitment_deadline = NEW.joined_at + INTERVAL '72 hours';
  END IF;
  
  -- Clear deadline when locked in
  IF NEW.status = 'locked_in' THEN
    NEW.locked_in_at = COALESCE(NEW.locked_in_at, NOW());
    NEW.commitment_deadline = NULL;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_reviewer_commitment_deadline
  BEFORE INSERT OR UPDATE ON pr_reviewer_teams
  FOR EACH ROW
  EXECUTE FUNCTION set_commitment_deadline();

-- Basic triggers
CREATE TRIGGER update_pr_reviewer_teams_updated_at
  BEFORE UPDATE ON pr_reviewer_teams
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at(); 

CREATE TRIGGER update_pr_participants_updated_at
  BEFORE UPDATE ON pr_participants
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- Function to sync participants when activities are created
CREATE OR REPLACE FUNCTION sync_participant_on_activity_create()
RETURNS TRIGGER AS $$
BEGIN
  -- Add author as participant when activity is created
  INSERT INTO pr_participants (activity_id, user_id, role)
  SELECT 
    NEW.activity_id,
    p.uploaded_by,
    'author'
  FROM papers p
  WHERE p.paper_id = NEW.paper_id
  ON CONFLICT (activity_id, user_id, role) DO NOTHING;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER sync_author_participant_on_create
AFTER INSERT ON pr_activities
FOR EACH ROW
EXECUTE FUNCTION sync_participant_on_activity_create();

-- Function to sync reviewer participants
CREATE OR REPLACE FUNCTION sync_reviewer_participant()
RETURNS TRIGGER AS $$
BEGIN

  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.user_id IS DISTINCT FROM NEW.user_id) THEN
    -- Sync to participants table
    INSERT INTO pr_participants (activity_id, user_id, role, status, joined_at)
    VALUES (NEW.activity_id, NEW.user_id, 'reviewer', NEW.status::text, NEW.joined_at)
    ON CONFLICT (activity_id, user_id, role) 
    DO UPDATE SET 
      status = EXCLUDED.status,
      left_at = CASE 
        WHEN NEW.status = 'removed' THEN NEW.removed_at
        ELSE NULL
      END,
      updated_at = NOW();
  END IF;
  
  -- Handle status changes
  IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    -- Update participant status
    UPDATE pr_participants
    SET 
      status = NEW.status::text,
      left_at = CASE WHEN NEW.status = 'removed' THEN NOW() ELSE NULL END,
      updated_at = NOW()
    WHERE activity_id = NEW.activity_id 
      AND user_id = NEW.user_id 
      AND role = 'reviewer';
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER sync_reviewer_to_participants
AFTER INSERT OR UPDATE ON pr_reviewer_teams
FOR EACH ROW
EXECUTE FUNCTION sync_reviewer_participant();

-- State change triggers removed - timeline events will be created in application services



-- RLS policies for new tables
ALTER TABLE pr_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE pr_timeline_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view participants"
  ON pr_participants FOR SELECT
  USING (true);

CREATE POLICY "Anyone can view timeline events"
  ON pr_timeline_events FOR SELECT
  USING (true);

-- Grant permissions
GRANT SELECT ON pr_participants TO authenticated;
GRANT SELECT ON pr_timeline_events TO authenticated;
GRANT SELECT, INSERT, UPDATE ON pr_reviewer_teams TO authenticated; 