-- =============================================
-- 00000000000071_audit_logs.sql
-- Admin & Monitoring: Audit and Processing Logs
-- =============================================
-- System monitoring and security audit trails

-- =============================================
-- PR Security Audit Log
-- =============================================
CREATE TABLE IF NOT EXISTS pr_security_audit_log (
  log_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  user_action TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('SUCCESS', 'SECURITY_FAILURE')),
  progression_occurred BOOLEAN NOT NULL DEFAULT false,
  from_stage TEXT,
  to_stage TEXT,
  session_id TEXT,
  ip_address INET,
  user_agent TEXT,
  request_id UUID,
  error_message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE pr_security_audit_log IS 'Security audit trail for PR activity operations';
COMMENT ON COLUMN pr_security_audit_log.activity_id IS 'PR activity ID';
COMMENT ON COLUMN pr_security_audit_log.user_id IS 'User who attempted the action';
COMMENT ON COLUMN pr_security_audit_log.status IS 'SUCCESS or SECURITY_FAILURE';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_security_audit_activity ON pr_security_audit_log (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_security_audit_user ON pr_security_audit_log (user_id);
CREATE INDEX IF NOT EXISTS idx_pr_security_audit_status ON pr_security_audit_log (status);
CREATE INDEX IF NOT EXISTS idx_pr_security_audit_created ON pr_security_audit_log (created_at DESC);

-- =============================================
-- PR Processing Log
-- =============================================
CREATE TABLE IF NOT EXISTS pr_processing_log (
  log_id SERIAL PRIMARY KEY,
  activity_id INTEGER REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  process_type TEXT NOT NULL,
  result TEXT NOT NULL,
  details JSONB DEFAULT '{}',
  processing_time_ms INTEGER,
  processed_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE pr_processing_log IS 'Processing logs for PR activity operations';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_processing_log_activity ON pr_processing_log (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_processing_log_processed ON pr_processing_log (processed_at DESC);

-- =============================================
-- PR State Transition Log
-- =============================================
CREATE TABLE IF NOT EXISTS pr_state_log (
  log_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  old_stage TEXT,
  new_stage TEXT NOT NULL,
  changed_at TIMESTAMPTZ DEFAULT NOW(),
  changed_by INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  reason TEXT,
  metadata JSONB DEFAULT '{}'
);

COMMENT ON TABLE pr_state_log IS 'History of PR activity stage transitions';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_state_log_activity ON pr_state_log (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_state_log_changed ON pr_state_log (changed_at DESC);

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE pr_security_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE pr_processing_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE pr_state_log ENABLE ROW LEVEL SECURITY;

-- Service role only for audit logs
CREATE POLICY pr_security_audit_log_service_role_only ON pr_security_audit_log
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY pr_processing_log_service_role_only ON pr_processing_log
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY pr_state_log_service_role_only ON pr_state_log
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

