-- =============================================
-- 00000000000011_activity_stage_state.sql
-- Runtime Activity Stage State Tracking
-- =============================================
-- Tracks the current stage for each activity instance
-- Polymorphic table: activity_type determines which activity table it references

-- =============================================
-- Activity Stage State Table
-- =============================================
CREATE TABLE IF NOT EXISTS activity_stage_state (
  state_id SERIAL PRIMARY KEY,
  
  -- Polymorphic activity reference
  activity_type TEXT NOT NULL REFERENCES activity_type_registry(type_code) ON DELETE CASCADE,
  activity_id INTEGER NOT NULL,  -- References pr_activities.activity_id or jc_activities.activity_id
  
  -- Current stage (references template_stage_graph.stage_key)
  current_stage_key TEXT NOT NULL,
  stage_entered_at TIMESTAMPTZ DEFAULT NOW(),
  stage_deadline TIMESTAMPTZ,  -- Calculated from template_stage_graph.deadline_days
  
  -- Stage-specific runtime data
  stage_runtime_data JSONB DEFAULT '{}',  -- Arbitrary key-value storage for stage state
  
  -- Completion tracking
  is_completed BOOLEAN DEFAULT false,
  completed_at TIMESTAMPTZ,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(activity_type, activity_id)
);

COMMENT ON TABLE activity_stage_state IS 'Runtime state tracking current stage for each activity instance';
COMMENT ON COLUMN activity_stage_state.activity_type IS 'Which activity type table this references (pr-activity, jc-activity, etc.)';
COMMENT ON COLUMN activity_stage_state.activity_id IS 'Activity ID (polymorphic - references different tables based on activity_type)';
COMMENT ON COLUMN activity_stage_state.current_stage_key IS 'Current stage key (references template_stage_graph.stage_key)';
COMMENT ON COLUMN activity_stage_state.stage_entered_at IS 'When the activity entered this stage';
COMMENT ON COLUMN activity_stage_state.stage_deadline IS 'Calculated deadline for current stage (NULL if no deadline)';
COMMENT ON COLUMN activity_stage_state.stage_runtime_data IS 'Stage-specific runtime data (e.g., current_editor_id, lock_expires_at for assessment)';
COMMENT ON COLUMN activity_stage_state.is_completed IS 'Whether the activity has completed its workflow';
COMMENT ON COLUMN activity_stage_state.completed_at IS 'When the activity completed';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_activity_stage_state_lookup ON activity_stage_state (activity_type, activity_id);
CREATE INDEX IF NOT EXISTS idx_activity_stage_state_stage ON activity_stage_state (current_stage_key);
CREATE INDEX IF NOT EXISTS idx_activity_stage_state_deadline ON activity_stage_state (stage_deadline) WHERE stage_deadline IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_activity_stage_state_completed ON activity_stage_state (is_completed, activity_type) WHERE is_completed = false;
-- Note: Can't create overdue index with NOW() as it's not immutable. 
-- Queries for overdue items can use idx_activity_stage_state_deadline and filter in application or use a function-based query

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_activity_stage_state_updated_at
  BEFORE UPDATE ON activity_stage_state
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================
-- Users can see stage state for activities they participate in
-- Note: Participant access will be fully implemented after permissions tables exist

ALTER TABLE activity_stage_state ENABLE ROW LEVEL SECURITY;

-- Service role can access all (API routes handle authorization)
-- Authenticated users will get participant-based access after permissions tables created
CREATE POLICY activity_stage_state_select_service_role ON activity_stage_state
  FOR SELECT
  USING ((SELECT auth.role()) = 'service_role');

-- Only service role can modify stage state (via progression engine)
CREATE POLICY activity_stage_state_modify_service_role_only ON activity_stage_state
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY activity_stage_state_select_service_role ON activity_stage_state IS
  'Service role access (participant-based access will be added in PR/JC migrations)';

