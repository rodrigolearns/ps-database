-- =============================================
-- 00000000000045_jc_timeline.sql
-- JC Activity Domain: Timeline Events
-- =============================================
-- Timeline events for journal club activities
-- Separate table from PR timeline (type-safe, clean separation)

-- =============================================
-- JC Timeline Events Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_timeline_events (
  event_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES jc_activities(activity_id) ON DELETE CASCADE,
  
  -- Event metadata
  event_type TEXT NOT NULL,  -- 'stage_transition', 'review_submitted', 'invitation_sent', etc.
  stage_key TEXT,  -- Which stage this event belongs to
  
  -- User attribution
  user_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  user_name TEXT,  -- Denormalized for display
  
  -- Event content
  title TEXT NOT NULL,
  description TEXT,
  metadata JSONB DEFAULT '{}',
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE jc_timeline_events IS 'Timeline events for JC activities';
COMMENT ON COLUMN jc_timeline_events.event_id IS 'Primary key';
COMMENT ON COLUMN jc_timeline_events.activity_id IS 'Foreign key to jc_activities';
COMMENT ON COLUMN jc_timeline_events.event_type IS 'Event type (stage_transition, review_submitted, invitation_sent, etc.)';
COMMENT ON COLUMN jc_timeline_events.stage_key IS 'Stage where event occurred';
COMMENT ON COLUMN jc_timeline_events.user_id IS 'User who triggered the event';
COMMENT ON COLUMN jc_timeline_events.user_name IS 'User name (denormalized)';
COMMENT ON COLUMN jc_timeline_events.title IS 'Event title';
COMMENT ON COLUMN jc_timeline_events.description IS 'Event description';
COMMENT ON COLUMN jc_timeline_events.metadata IS 'Additional metadata';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_jc_timeline_events_activity ON jc_timeline_events (activity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_jc_timeline_events_type ON jc_timeline_events (event_type);
CREATE INDEX IF NOT EXISTS idx_jc_timeline_events_user ON jc_timeline_events (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_jc_timeline_events_stage ON jc_timeline_events (stage_key) WHERE stage_key IS NOT NULL;

-- Covering index
CREATE INDEX IF NOT EXISTS idx_jc_timeline_events_activity_covering
ON jc_timeline_events (activity_id)
INCLUDE (event_id, event_type, stage_key, user_id, user_name, title, description, metadata, created_at);

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE jc_timeline_events ENABLE ROW LEVEL SECURITY;

-- Participants can see timeline
CREATE POLICY jc_timeline_events_select_participant ON jc_timeline_events
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM jc_activity_permissions jap
      WHERE jap.activity_id = jc_timeline_events.activity_id
      AND jap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify
CREATE POLICY jc_timeline_events_modify_service_role_only ON jc_timeline_events
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

