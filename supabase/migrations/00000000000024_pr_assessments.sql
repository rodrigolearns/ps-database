-- =============================================
-- 00000000000024_pr_assessments.sql
-- PR Activity Domain: Collaborative Assessments
-- =============================================
-- Etherpad-based collaborative assessment with finalization tracking
-- NOTE: Etherpad integration replaces complex turn-based locking system

-- =============================================
-- 1. PR Assessments Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_assessments (
  assessment_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  
  -- Etherpad integration
  etherpad_pad_id TEXT UNIQUE,  -- Etherpad pad identifier
  etherpad_group_id TEXT,  -- Etherpad group for this activity
  
  -- Assessment content (synced from Etherpad)
  assessment_content TEXT,  -- Latest content from Etherpad
  content_last_synced_at TIMESTAMPTZ,  -- When content was last synced
  last_content_hash TEXT,  -- SHA-256 hash for change detection
  
  -- Finalization
  is_finalized BOOLEAN NOT NULL DEFAULT false,
  finalized_at TIMESTAMPTZ,
  
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  UNIQUE(activity_id)
);

COMMENT ON TABLE pr_assessments IS 'Collaborative assessments using Etherpad for real-time editing';
COMMENT ON COLUMN pr_assessments.assessment_id IS 'Primary key';
COMMENT ON COLUMN pr_assessments.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_assessments.etherpad_pad_id IS 'Etherpad pad identifier for this assessment';
COMMENT ON COLUMN pr_assessments.etherpad_group_id IS 'Etherpad group identifier';
COMMENT ON COLUMN pr_assessments.assessment_content IS 'Assessment content (synced from Etherpad periodically)';
COMMENT ON COLUMN pr_assessments.content_last_synced_at IS 'When content was last synced from Etherpad';
COMMENT ON COLUMN pr_assessments.last_content_hash IS 'SHA-256 hash of Etherpad content for change detection (auto-resets finalization)';
COMMENT ON COLUMN pr_assessments.is_finalized IS 'Whether all reviewers have finalized';

-- =============================================
-- 2. Reviewer Finalization Status Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_finalization_status (
  status_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  is_finalized BOOLEAN NOT NULL DEFAULT false,
  finalized_at TIMESTAMPTZ,
  content_hash_at_finalization TEXT,  -- Hash of content when reviewer finalized
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(activity_id, reviewer_id)
);

COMMENT ON TABLE pr_finalization_status IS 'Individual reviewer finalization status for assessments';
COMMENT ON COLUMN pr_finalization_status.status_id IS 'Primary key';
COMMENT ON COLUMN pr_finalization_status.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_finalization_status.reviewer_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN pr_finalization_status.is_finalized IS 'Whether this reviewer has finalized';
COMMENT ON COLUMN pr_finalization_status.finalized_at IS 'When finalized';
COMMENT ON COLUMN pr_finalization_status.content_hash_at_finalization IS 'Content hash when finalized (for change detection)';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_pr_assessments_activity ON pr_assessments (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_assessments_pad_id ON pr_assessments (etherpad_pad_id) WHERE etherpad_pad_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pr_assessments_content_hash ON pr_assessments (last_content_hash) WHERE last_content_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pr_finalization_activity ON pr_finalization_status (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_finalization_reviewer ON pr_finalization_status (reviewer_id);
CREATE INDEX IF NOT EXISTS idx_pr_finalization_activity_finalized ON pr_finalization_status (activity_id, is_finalized) WHERE is_finalized = true;

-- Covering indexes
CREATE INDEX IF NOT EXISTS idx_pr_assessments_activity_covering
ON pr_assessments (activity_id)
INCLUDE (assessment_id, assessment_content, is_finalized, finalized_at, etherpad_pad_id, last_content_hash, updated_at, created_at);

CREATE INDEX IF NOT EXISTS idx_pr_finalization_status_activity_covering
ON pr_finalization_status (activity_id)
INCLUDE (status_id, reviewer_id, is_finalized, finalized_at, created_at, updated_at);

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_pr_assessments_updated_at
  BEFORE UPDATE ON pr_assessments
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_pr_finalization_status_updated_at
  BEFORE UPDATE ON pr_finalization_status
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Helper Functions
-- =============================================

-- Check if all reviewers have finalized
CREATE OR REPLACE FUNCTION check_all_assessments_finalized(
  p_activity_id INTEGER
)
RETURNS BOOLEAN AS $$
DECLARE
  v_total_reviewers INTEGER;
  v_finalized_reviewers INTEGER;
BEGIN
  -- Count total reviewers
  SELECT COUNT(*) INTO v_total_reviewers
  FROM pr_reviewers
  WHERE activity_id = p_activity_id
    AND status IN ('joined', 'locked_in');
  
  -- Count finalized reviewers
  SELECT COUNT(*) INTO v_finalized_reviewers
  FROM pr_finalization_status
  WHERE activity_id = p_activity_id
    AND is_finalized = true;
  
  RETURN v_total_reviewers > 0 AND v_finalized_reviewers = v_total_reviewers;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION check_all_assessments_finalized(INTEGER) IS 'Check if all reviewers have finalized assessment';

-- Toggle reviewer finalization status
CREATE OR REPLACE FUNCTION toggle_assessment_finalization(
  p_activity_id INTEGER,
  p_reviewer_id INTEGER,
  p_is_finalized BOOLEAN,
  p_content_hash TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_all_finalized BOOLEAN;
BEGIN
  -- Upsert finalization status
  INSERT INTO pr_finalization_status (
    activity_id,
    reviewer_id,
    is_finalized,
    finalized_at,
    content_hash_at_finalization
  )
  VALUES (
    p_activity_id,
    p_reviewer_id,
    p_is_finalized,
    CASE WHEN p_is_finalized THEN NOW() ELSE NULL END,
    p_content_hash
  )
  ON CONFLICT (activity_id, reviewer_id)
  DO UPDATE SET
    is_finalized = p_is_finalized,
    finalized_at = CASE WHEN p_is_finalized THEN NOW() ELSE NULL END,
    content_hash_at_finalization = p_content_hash,
    updated_at = NOW();
  
  -- Check if all finalized
  v_all_finalized := check_all_assessments_finalized(p_activity_id);
  
  RETURN jsonb_build_object(
    'success', true,
    'is_finalized', p_is_finalized,
    'all_finalized', v_all_finalized
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION toggle_assessment_finalization IS 'Toggle reviewer finalization status for assessment';

-- =============================================
-- Function Permissions
-- =============================================
GRANT EXECUTE ON FUNCTION check_all_assessments_finalized TO authenticated;
GRANT EXECUTE ON FUNCTION toggle_assessment_finalization TO authenticated;

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE pr_assessments ENABLE ROW LEVEL SECURITY;
ALTER TABLE pr_finalization_status ENABLE ROW LEVEL SECURITY;

-- Assessments: Participants can access
CREATE POLICY pr_assessments_select_participant ON pr_assessments
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_assessments.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify (via API/Etherpad sync)
CREATE POLICY pr_assessments_modify_service_role_only ON pr_assessments
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Finalization status: Participants can see all statuses for their activity
CREATE POLICY pr_finalization_status_select_participant ON pr_finalization_status
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pr_activity_permissions pap
      WHERE pap.activity_id = pr_finalization_status.activity_id
      AND pap.user_id = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify
CREATE POLICY pr_finalization_status_modify_service_role_only ON pr_finalization_status
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

