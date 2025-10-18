-- =============================================
-- 00000000000026_pr_timeline.sql
-- PR Activity Domain: Timeline Events
-- =============================================
-- Complete timeline of all events in PR activities
-- Separate table (not shared with other activity types)

-- =============================================
-- PR Timeline Events Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_timeline_events (
  event_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  
  -- Event metadata
  event_type TEXT NOT NULL,  -- 'stage_transition', 'review_submitted', 'author_response_submitted', etc.
  stage_key TEXT,  -- Which stage this event belongs to (references template_stage_graph.stage_key)
  
  -- User attribution
  user_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  user_name TEXT,  -- Denormalized for display
  
  -- Event content
  title TEXT NOT NULL,
  description TEXT,
  metadata JSONB DEFAULT '{}',
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE pr_timeline_events IS 'Complete timeline of all events in PR activities';
COMMENT ON COLUMN pr_timeline_events.event_id IS 'Primary key';
COMMENT ON COLUMN pr_timeline_events.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_timeline_events.event_type IS 'Event type (stage_transition, review_submitted, etc.)';
COMMENT ON COLUMN pr_timeline_events.stage_key IS 'Stage where event occurred (references template_stage_graph.stage_key)';
COMMENT ON COLUMN pr_timeline_events.user_id IS 'User who triggered the event';
COMMENT ON COLUMN pr_timeline_events.user_name IS 'User name (denormalized for display)';
COMMENT ON COLUMN pr_timeline_events.title IS 'Event title for display';
COMMENT ON COLUMN pr_timeline_events.description IS 'Detailed description';
COMMENT ON COLUMN pr_timeline_events.metadata IS 'Additional event metadata (JSONB)';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_activity ON pr_timeline_events (activity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_type ON pr_timeline_events (event_type);
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_user ON pr_timeline_events (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_stage ON pr_timeline_events (stage_key) WHERE stage_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_type_stage ON pr_timeline_events (event_type, stage_key);

-- Composite index for stage transition lookups
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_activity_stage_transition 
ON pr_timeline_events (activity_id, stage_key, created_at DESC) 
WHERE event_type = 'stage_transition';

-- Covering index for timeline display
CREATE INDEX IF NOT EXISTS idx_pr_timeline_events_activity_covering
ON pr_timeline_events (activity_id, event_type)
INCLUDE (created_at, user_id, title, stage_key, description, metadata, user_name, event_id);

-- =============================================
-- Row Level Security Policies
-- =============================================
-- Activity participants can see all timeline events for their activities

ALTER TABLE pr_timeline_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY pr_timeline_events_select_participant ON pr_timeline_events
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_timeline_events.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can insert/update timeline events
CREATE POLICY pr_timeline_events_modify_service_role_only ON pr_timeline_events
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_timeline_events_select_participant ON pr_timeline_events IS
  'Activity participants can see all timeline events for their activities';

