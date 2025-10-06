-- =====================================================
-- ETHERPAD COLLABORATIVE ASSESSMENT INTEGRATION
-- =====================================================
-- 
-- Purpose: Complete Etherpad integration for collaborative assessments
-- 
-- This migration handles:
-- 1. Etherpad database schema (store table for Etherpad's internal use)
-- 2. PaperStacks schema changes (pr_assessments metadata)
-- 3. Finalization logic (content hash tracking for reset detection)
-- 
-- Architecture:
-- - PaperStacks: Stores metadata (etherpad_pad_id, timeslider_url, etc.)
-- - Etherpad: Stores content (pads, revisions, authors, sessions)
-- - Database as Source of Truth for each system
-- 
-- Development Workflow:
-- 1. Run: supabase db reset
-- 2. This migration runs automatically
-- 3. Etherpad starts with a fresh, working database
-- 4. ProgressionEngine creates pads at author_response_1 stage
-- 5. Reviewers collaborate in assessment stage
-- 
-- References:
-- - COLLABORATIVE_ASSESSMENT_PRD.md
-- - DEVELOPMENT_PRINCIPLES.md
-- =====================================================

-- Enable pgcrypto extension for digest() function (used for SHA-256 content hashing)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =====================================================
-- PART 1: ETHERPAD DATABASE SCHEMA
-- =====================================================

-- Etherpad's main key-value store table
-- This is managed internally by Etherpad - PaperStacks never touches it
-- Resets with database for clean development slate
CREATE TABLE IF NOT EXISTS store (
  key VARCHAR(100) NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
);

-- Add index for performance on key lookups
CREATE INDEX IF NOT EXISTS store_key_idx ON store(key);

-- Document the table's purpose
COMMENT ON TABLE store IS 'Etherpad internal key-value storage - managed by Etherpad, not PaperStacks. Resets with database for clean development slate.';

-- Note: Etherpad will create additional internal structures as needed
-- (groups, pads, authors, sessions) using this store table as its foundation

-- =====================================================
-- PART 2: PAPERSTACKS SCHEMA CHANGES
-- =====================================================

-- Remove old turn-based locking mechanism
ALTER TABLE pr_assessments DROP COLUMN IF EXISTS current_editor_id CASCADE;
ALTER TABLE pr_assessments DROP COLUMN IF EXISTS edit_session_started_at CASCADE;
ALTER TABLE pr_assessments DROP COLUMN IF EXISTS edit_session_expires_at CASCADE;
ALTER TABLE pr_assessments DROP COLUMN IF EXISTS draft_content CASCADE;

-- Add Etherpad-specific columns
ALTER TABLE pr_assessments ADD COLUMN IF NOT EXISTS etherpad_pad_id TEXT NULL;
ALTER TABLE pr_assessments ADD COLUMN IF NOT EXISTS etherpad_group_id TEXT NULL;
ALTER TABLE pr_assessments ADD COLUMN IF NOT EXISTS timeslider_url TEXT NULL;
ALTER TABLE pr_assessments ADD COLUMN IF NOT EXISTS last_backup_content TEXT NULL;
ALTER TABLE pr_assessments ADD COLUMN IF NOT EXISTS last_backup_at TIMESTAMPTZ NULL;
ALTER TABLE pr_assessments ADD COLUMN IF NOT EXISTS last_content_hash TEXT NULL;
ALTER TABLE pr_assessments ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ NULL;
ALTER TABLE pr_assessments ADD COLUMN IF NOT EXISTS scheduled_deletion_at TIMESTAMPTZ NULL;

COMMENT ON COLUMN pr_assessments.etherpad_pad_id IS 'Etherpad pad ID (e.g., g.activity_5$assessment) - created at author_response_1 stage';
COMMENT ON COLUMN pr_assessments.etherpad_group_id IS 'Etherpad group ID (e.g., g.activity_5)';
COMMENT ON COLUMN pr_assessments.timeslider_url IS 'URL to Etherpad timeslider for revision history';
COMMENT ON COLUMN pr_assessments.last_backup_content IS 'Last backup of pad content (every 5 minutes)';
COMMENT ON COLUMN pr_assessments.last_backup_at IS 'When last backup was performed';
COMMENT ON COLUMN pr_assessments.last_content_hash IS 'SHA256 hash of last backup content (for change detection)';
COMMENT ON COLUMN pr_assessments.archived_at IS 'When pad was archived (made read-only)';
COMMENT ON COLUMN pr_assessments.scheduled_deletion_at IS 'When pad should be deleted (30 days after archival)';

-- Update table comment
COMMENT ON TABLE pr_assessments IS 'Collaborative assessments with Etherpad integration';

-- =====================================================
-- PART 3: FINALIZATION LOGIC
-- =====================================================

-- Add content hash column to track what version was finalized
ALTER TABLE pr_finalization_status ADD COLUMN IF NOT EXISTS content_hash_at_finalization TEXT NULL;

COMMENT ON COLUMN pr_finalization_status.content_hash_at_finalization IS 'Hash of content when user finalized (for reset detection)';
COMMENT ON TABLE pr_finalization_status IS 'Track individual reviewer finalization status with content hash';

-- Drop old edit locking functions (not needed with Etherpad)
DROP FUNCTION IF EXISTS release_expired_edit_locks() CASCADE;
DROP FUNCTION IF EXISTS acquire_assessment_edit_lock(INTEGER, INTEGER, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS release_assessment_edit_lock(INTEGER, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS scheduled_cleanup_assessment_locks() CASCADE;

-- Function to check if assessment stage should complete
-- (All reviewers finalized AND content hasn't changed since finalization)
CREATE OR REPLACE FUNCTION check_assessment_ready_for_completion(
  p_activity_id INTEGER
)
RETURNS JSONB AS $$
DECLARE
  v_total_reviewers INTEGER;
  v_finalized_reviewers INTEGER;
  v_last_content_hash TEXT;
  v_all_hashes_match BOOLEAN;
BEGIN
  -- Count total reviewers for this activity
  SELECT COUNT(*)
  INTO v_total_reviewers
  FROM public.pr_reviewer_teams
  WHERE activity_id = p_activity_id
  AND status IN ('joined', 'locked_in');
  
  -- Count reviewers who have finalized
  SELECT COUNT(*)
  INTO v_finalized_reviewers
  FROM public.pr_finalization_status
  WHERE activity_id = p_activity_id
  AND is_finalized = true;
  
  -- Get current content hash
  SELECT last_content_hash
  INTO v_last_content_hash
  FROM public.pr_assessments
  WHERE activity_id = p_activity_id;
  
  -- Check if all finalized reviewers have same content hash
  SELECT NOT EXISTS (
    SELECT 1 FROM public.pr_finalization_status
    WHERE activity_id = p_activity_id
    AND is_finalized = true
    AND (content_hash_at_finalization IS NULL OR content_hash_at_finalization != v_last_content_hash)
  ) INTO v_all_hashes_match;
  
  RETURN jsonb_build_object(
    'ready', (v_total_reviewers > 0 AND v_finalized_reviewers = v_total_reviewers AND v_all_hashes_match),
    'total_reviewers', v_total_reviewers,
    'finalized_reviewers', v_finalized_reviewers,
    'content_hash_matches', v_all_hashes_match,
    'current_content_hash', v_last_content_hash
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION check_assessment_ready_for_completion(INTEGER) IS 'Check if assessment is ready to complete (all finalized + no content changes)';

-- Function to update reviewer finalization status with content hash
-- Following DEVELOPMENT_PRINCIPLES.md: Explicit schema qualification (Database is Source of Truth)
CREATE OR REPLACE FUNCTION toggle_reviewer_finalization(
  p_activity_id INTEGER,
  p_reviewer_id INTEGER,
  p_is_finalized BOOLEAN
)
RETURNS JSONB AS $$
DECLARE
  v_current_state public.activity_state;
  v_current_content_hash TEXT;
  v_is_reviewer BOOLEAN;
BEGIN
  -- Get current state (explicitly qualify table with public schema)
  SELECT current_state INTO v_current_state
  FROM public.pr_activities
  WHERE activity_id = p_activity_id;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Activity not found'
    );
  END IF;
  
  IF v_current_state != 'assessment' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Activity is not in assessment stage'
    );
  END IF;
  
  -- Verify user is a reviewer
  SELECT EXISTS (
    SELECT 1 FROM public.pr_reviewer_teams 
    WHERE activity_id = p_activity_id 
    AND user_id = p_reviewer_id
    AND status IN ('joined', 'locked_in')
  ) INTO v_is_reviewer;
  
  IF NOT v_is_reviewer THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User is not a reviewer for this activity'
    );
  END IF;
  
  -- Get current content hash
  SELECT last_content_hash INTO v_current_content_hash
  FROM public.pr_assessments
  WHERE activity_id = p_activity_id;
  
  -- Update finalization status
  INSERT INTO public.pr_finalization_status (
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
    CASE WHEN p_is_finalized THEN v_current_content_hash ELSE NULL END
  )
  ON CONFLICT (activity_id, reviewer_id)
  DO UPDATE SET
    is_finalized = p_is_finalized,
    finalized_at = CASE WHEN p_is_finalized THEN NOW() ELSE NULL END,
    content_hash_at_finalization = CASE WHEN p_is_finalized THEN v_current_content_hash ELSE NULL END,
    updated_at = NOW();
  
  RETURN jsonb_build_object(
    'success', true,
    'is_finalized', p_is_finalized,
    'content_hash', v_current_content_hash
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION toggle_reviewer_finalization(INTEGER, INTEGER, BOOLEAN) IS 'Toggle reviewer finalization status with content hash tracking';

-- Function to reset all finalization statuses (when content changes)
CREATE OR REPLACE FUNCTION reset_all_finalization_on_content_change(
  p_activity_id INTEGER
)
RETURNS JSONB AS $$
DECLARE
  v_reset_count INTEGER;
BEGIN
  -- Reset all finalization statuses
  UPDATE public.pr_finalization_status
  SET 
    is_finalized = false,
    finalized_at = NULL,
    content_hash_at_finalization = NULL,
    updated_at = NOW()
  WHERE activity_id = p_activity_id
  AND is_finalized = true;
  
  GET DIAGNOSTICS v_reset_count = ROW_COUNT;
  
  RETURN jsonb_build_object(
    'success', true,
    'reset_count', v_reset_count,
    'reason', 'content_changed'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION reset_all_finalization_on_content_change(INTEGER) IS 'Reset all finalization statuses when Etherpad content changes';

-- =====================================================
-- PART 4: INDEXES AND PERMISSIONS
-- =====================================================

-- Drop old indexes related to edit locking
DROP INDEX IF EXISTS idx_pr_assessments_editor;
DROP INDEX IF EXISTS idx_pr_assessments_expires;

-- Create new indexes for Etherpad integration
CREATE INDEX IF NOT EXISTS idx_pr_assessments_etherpad_pad
  ON pr_assessments(etherpad_pad_id) WHERE etherpad_pad_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_pr_assessments_archived
  ON pr_assessments(archived_at) WHERE archived_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_pr_assessments_scheduled_deletion
  ON pr_assessments(scheduled_deletion_at) WHERE scheduled_deletion_at IS NOT NULL;

-- Function to create or update assessment with Etherpad metadata
-- Uses SECURITY DEFINER to bypass RLS policies during progression
-- Following DEVELOPMENT_PRINCIPLES.md: Explicit schema qualification (Database is Source of Truth)
CREATE OR REPLACE FUNCTION create_assessment_with_etherpad(
  p_activity_id INTEGER,
  p_etherpad_pad_id TEXT,
  p_timeslider_url TEXT
)
RETURNS JSONB AS $$
DECLARE
  v_assessment_id INTEGER;
BEGIN
  -- Insert or update assessment record
  -- Explicitly qualify table with public schema (search_path is empty for security)
  -- Initialize last_content_hash with SHA-256 hash of empty string for proper finalization tracking
  INSERT INTO public.pr_assessments (
    activity_id,
    etherpad_pad_id,
    etherpad_group_id,
    timeslider_url,
    assessment_content,
    last_content_hash,
    is_finalized,
    created_at,
    updated_at
  )
  VALUES (
    p_activity_id,
    p_etherpad_pad_id,
    NULL,  -- Regular pads don't use groups
    p_timeslider_url,
    '',    -- Empty initial content
    encode(extensions.digest('', 'sha256'), 'hex'),  -- Hash of empty string
    false,
    NOW(),
    NOW()
  )
  ON CONFLICT (activity_id) DO UPDATE SET
    etherpad_pad_id = p_etherpad_pad_id,
    etherpad_group_id = NULL,
    timeslider_url = p_timeslider_url,
    last_content_hash = encode(extensions.digest('', 'sha256'), 'hex'),  -- Reset hash on pad recreation
    updated_at = NOW()
  RETURNING assessment_id INTO v_assessment_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'assessment_id', v_assessment_id,
    'activity_id', p_activity_id,
    'etherpad_pad_id', p_etherpad_pad_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION create_assessment_with_etherpad(INTEGER, TEXT, TEXT) IS 'Create or update pr_assessments with Etherpad metadata. Uses SECURITY DEFINER to bypass RLS during progression.';

-- Grant permissions for new functions
GRANT EXECUTE ON FUNCTION check_assessment_ready_for_completion(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION toggle_reviewer_finalization(INTEGER, INTEGER, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION reset_all_finalization_on_content_change(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION create_assessment_with_etherpad(INTEGER, TEXT, TEXT) TO authenticated;

