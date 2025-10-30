-- =============================================
-- 00000000000043_jc_assessments.sql
-- JC Activity Domain: Collaborative Assessments
-- =============================================
-- Etherpad-based assessment for journal clubs (manual finalization, no automatic progression)

-- =============================================
-- 1. JC Assessments Table
-- =============================================
CREATE TABLE IF NOT EXISTS jc_assessments (
  assessment_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES jc_activities(activity_id) ON DELETE CASCADE,
  
  -- Etherpad integration
  etherpad_pad_id TEXT UNIQUE,
  etherpad_group_id TEXT,
  
  -- Assessment content (synced from Etherpad)
  assessment_content TEXT,
  content_last_synced_at TIMESTAMPTZ,
  
  -- Finalization (optional for JC - manual progression)
  is_finalized BOOLEAN DEFAULT false,
  finalized_at TIMESTAMPTZ,
  
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  UNIQUE(activity_id)
);

COMMENT ON TABLE jc_assessments IS 'Collaborative assessments for JC activities (Etherpad, manual progression)';
COMMENT ON COLUMN jc_assessments.assessment_id IS 'Primary key';
COMMENT ON COLUMN jc_assessments.activity_id IS 'Foreign key to jc_activities';
COMMENT ON COLUMN jc_assessments.etherpad_pad_id IS 'Etherpad pad identifier';
COMMENT ON COLUMN jc_assessments.assessment_content IS 'Content synced from Etherpad';

-- =============================================
-- 2. JC Finalization Status Table (Optional)
-- =============================================
CREATE TABLE IF NOT EXISTS jc_finalization_status (
  status_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES jc_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  is_finalized BOOLEAN DEFAULT false,
  finalized_at TIMESTAMPTZ,
  
  UNIQUE(activity_id, reviewer_id)
);

COMMENT ON TABLE jc_finalization_status IS 'Optional finalization tracking for JC assessments';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_jc_assessments_activity ON jc_assessments (activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_assessments_pad_id ON jc_assessments (etherpad_pad_id) WHERE etherpad_pad_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_jc_finalization_activity ON jc_finalization_status (activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_finalization_reviewer ON jc_finalization_status (reviewer_id);

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_jc_assessments_updated_at
  BEFORE UPDATE ON jc_assessments
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_jc_finalization_status_updated_at
  BEFORE UPDATE ON jc_finalization_status
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE jc_assessments ENABLE ROW LEVEL SECURITY;
ALTER TABLE jc_finalization_status ENABLE ROW LEVEL SECURITY;

-- Participants can see assessments
CREATE POLICY jc_assessments_select_participant ON jc_assessments
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM jc_participants jp
      WHERE jp.activity_id = jc_assessments.activity_id
      AND jp.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY jc_assessments_modify_service_role_only ON jc_assessments
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Participants can see finalization status
CREATE POLICY jc_finalization_status_select_participant ON jc_finalization_status
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM jc_participants jp
      WHERE jp.activity_id = jc_finalization_status.activity_id
      AND jp.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY jc_finalization_status_modify_service_role_only ON jc_finalization_status
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

