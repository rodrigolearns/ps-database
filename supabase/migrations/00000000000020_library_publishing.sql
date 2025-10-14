 -- =====================================================
-- Library Publishing Migration
-- Adds support for publishing pr-activities to library
-- =====================================================

-- NOTE: The activity_state enum values have already been updated in 00000000000010_pr_core.sql
-- New states: publication_choice, published_on_ps, submitted_externally, made_private

-- Add columns to pr_activities table for publishing
ALTER TABLE pr_activities 
ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS published_to TEXT,
ADD COLUMN IF NOT EXISTS journal_choice TEXT, -- 'paperstack-library', 'external-journal', 'private'
ADD COLUMN IF NOT EXISTS publication_term TEXT CHECK (publication_term IN ('diamond-open-access', 'join-charter', 'custom-access', NULL)),
ADD COLUMN IF NOT EXISTS completion_status TEXT CHECK (completion_status IN ('published_on_ps', 'submitted_externally', 'made_private', NULL));

-- Create index for published activities (now published_on_ps state)
CREATE INDEX IF NOT EXISTS idx_pr_activities_published 
ON pr_activities(current_state, published_to, published_at);

-- Create index for journal choices
CREATE INDEX IF NOT EXISTS idx_pr_activities_journal_choice 
ON pr_activities(journal_choice, current_state);

-- Create index for publication terms
CREATE INDEX IF NOT EXISTS idx_pr_activities_publication_term 
ON pr_activities(publication_term) 
WHERE publication_term IS NOT NULL;

-- Add comment to document the new columns
COMMENT ON COLUMN pr_activities.published_at IS 'Timestamp when the activity was published to a journal/library';
COMMENT ON COLUMN pr_activities.published_to IS 'Identifier of the journal/library where the activity was published (e.g., paperstack-library, elife)';
COMMENT ON COLUMN pr_activities.journal_choice IS 'Authors journal choice: paperstack-library, external-journal, or private';
COMMENT ON COLUMN pr_activities.publication_term IS 'Publication term chosen for PaperStack Library: diamond-open-access, join-charter, or custom-access';

-- Create external_journal_submissions table for tracking external submissions
CREATE TABLE IF NOT EXISTS external_journal_submissions (
    id SERIAL PRIMARY KEY,
    activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
    journal_id VARCHAR(50) NOT NULL, -- 'elife', 'nature', etc.
    journal_name VARCHAR(200) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'submitted', -- 'submitted', 'under_review', 'accepted', 'rejected'
    submitted_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    external_url VARCHAR(500),
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    
    -- Ensure one submission per journal per activity
    UNIQUE(activity_id, journal_id)
);

-- Create indexes for external submissions
CREATE INDEX IF NOT EXISTS idx_external_journal_submissions_activity_id 
ON external_journal_submissions(activity_id);

CREATE INDEX IF NOT EXISTS idx_external_journal_submissions_journal_id 
ON external_journal_submissions(journal_id);

CREATE INDEX IF NOT EXISTS idx_external_journal_submissions_status 
ON external_journal_submissions(status);

-- Add trigger for external submissions
CREATE TRIGGER update_external_journal_submissions_updated_at 
    BEFORE UPDATE ON external_journal_submissions 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Function to publish activity to PaperStack Library (now uses published_on_ps state)
CREATE OR REPLACE FUNCTION publish_to_paperstack_library(
  p_activity_id INTEGER,
  p_publication_term TEXT DEFAULT 'diamond-open-access'
) RETURNS BOOLEAN AS $$
BEGIN
  -- Validate publication term
  IF p_publication_term NOT IN ('diamond-open-access', 'join-charter', 'custom-access') THEN
    RAISE EXCEPTION 'Invalid publication term: %', p_publication_term;
  END IF;

  -- Update the activity to published_on_ps state
  UPDATE public.pr_activities
  SET 
    current_state = 'published_on_ps',
    published_at = CURRENT_TIMESTAMP,
    published_to = 'paperstack-library',
    journal_choice = 'paperstack-library',
    publication_term = p_publication_term,
    state_change_reason = 'Published to PaperStack Library with ' || p_publication_term
  WHERE activity_id = p_activity_id 
    AND current_state = 'publication_choice';
  
  -- Return true if activity was updated
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION publish_to_paperstack_library(INTEGER, TEXT) IS 'Publishes a peer review activity to PaperStack Library with specified publication term';

-- Function to submit activity to external journal
CREATE OR REPLACE FUNCTION submit_to_external_journal(
  p_activity_id INTEGER,
  p_journal_id TEXT,
  p_journal_name TEXT
) RETURNS BOOLEAN AS $$
BEGIN
  -- Update the activity to submitted_externally state
  UPDATE public.pr_activities
  SET 
    current_state = 'submitted_externally',
    published_to = p_journal_id,
    journal_choice = 'external-journal',
    state_change_reason = 'Submitted to external journal: ' || p_journal_name
  WHERE activity_id = p_activity_id 
    AND current_state = 'publication_choice';
  
  IF FOUND THEN
    -- Create external submission record
    INSERT INTO public.external_journal_submissions (activity_id, journal_id, journal_name)
    VALUES (p_activity_id, p_journal_id, p_journal_name)
    ON CONFLICT (activity_id, journal_id) DO NOTHING;
  END IF;
  
  -- Return true if activity was updated
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION submit_to_external_journal(INTEGER, TEXT, TEXT) IS 'Submits a peer review activity to an external journal';

-- Function to make activity private
CREATE OR REPLACE FUNCTION make_activity_private(
  p_activity_id INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  -- Update the activity to made_private state
  UPDATE public.pr_activities
  SET 
    current_state = 'made_private',
    journal_choice = 'private',
    state_change_reason = 'Activity made private by author'
  WHERE activity_id = p_activity_id 
    AND current_state = 'publication_choice';
  
  -- Return true if activity was updated
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION make_activity_private(INTEGER) IS 'Makes a peer review activity private (not published anywhere)';

-- Function to set publication choice (generic handler)
CREATE OR REPLACE FUNCTION set_publication_choice(
  p_activity_id INTEGER,
  p_choice TEXT
) RETURNS BOOLEAN AS $$
BEGIN
  CASE p_choice
    WHEN 'paperstack-library' THEN
      RETURN publish_to_paperstack_library(p_activity_id);
    WHEN 'private' THEN
      RETURN make_activity_private(p_activity_id);
    ELSE
      -- For external journals, this function just sets the choice
      -- The actual external journal submission should use submit_to_external_journal
      UPDATE public.pr_activities
      SET 
        journal_choice = p_choice,
        state_change_reason = 'Publication choice set to: ' || p_choice
      WHERE activity_id = p_activity_id 
        AND current_state = 'publication_choice';
      
      RETURN FOUND;
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION set_publication_choice(INTEGER, TEXT) IS 'Sets the publication choice for a peer review activity (paperstack-library, external-journal, or private)';

-- Revoke public execute permissions for security
-- These functions should only be called via API routes with proper permission checks
REVOKE EXECUTE ON FUNCTION publish_to_paperstack_library(INTEGER, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION submit_to_external_journal(INTEGER, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION make_activity_private(INTEGER) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION set_publication_choice(INTEGER, TEXT) FROM PUBLIC;

-- Grant execute only to service role (used by API routes)
GRANT EXECUTE ON FUNCTION publish_to_paperstack_library(INTEGER, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION submit_to_external_journal(INTEGER, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION make_activity_private(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION set_publication_choice(INTEGER, TEXT) TO service_role;

-- Add comments to new columns
COMMENT ON COLUMN pr_activities.completion_status IS 'Final completion status of the activity after publication choice';
COMMENT ON TABLE external_journal_submissions IS 'Tracks submissions to external journals separate from activity state';