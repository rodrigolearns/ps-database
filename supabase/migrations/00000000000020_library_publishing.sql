 -- =====================================================
-- Library Publishing Migration
-- Adds support for publishing pr-activities to library
-- =====================================================

-- NOTE: The activity_state enum values have already been updated in 00000000000010_pr_core.sql
-- New states: journal_selection, published_on_ps, submitted_externally, made_private

-- Add columns to pr_activities table for publishing
ALTER TABLE pr_activities 
ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS published_to TEXT,
ADD COLUMN IF NOT EXISTS journal_choice TEXT; -- 'paperstacks-library', 'external-journal', 'private'

-- Create index for published activities (now published_on_ps state)
CREATE INDEX IF NOT EXISTS idx_pr_activities_published 
ON pr_activities(current_state, published_to, published_at);

-- Create index for journal choices
CREATE INDEX IF NOT EXISTS idx_pr_activities_journal_choice 
ON pr_activities(journal_choice, current_state);

-- Add comment to document the new columns
COMMENT ON COLUMN pr_activities.published_at IS 'Timestamp when the activity was published to a journal/library';
COMMENT ON COLUMN pr_activities.published_to IS 'Identifier of the journal/library where the activity was published (e.g., paperstacks-library, elife)';
COMMENT ON COLUMN pr_activities.journal_choice IS 'Authors journal choice: paperstacks-library, external-journal, or private';

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

-- Function to publish activity to PaperStacks Library (now uses published_on_ps state)
CREATE OR REPLACE FUNCTION publish_to_paperstacks_library(
  p_activity_id INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  -- Update the activity to published_on_ps state
  UPDATE pr_activities
  SET 
    current_state = 'published_on_ps',
    published_at = CURRENT_TIMESTAMP,
    published_to = 'paperstacks-library',
    journal_choice = 'paperstacks-library',
    state_change_reason = 'Published to PaperStacks Library'
  WHERE activity_id = p_activity_id 
    AND current_state = 'journal_selection';
  
  -- Return true if activity was updated
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION publish_to_paperstacks_library(INTEGER) IS 'Publishes a peer review activity to PaperStacks Library';

-- Function to submit activity to external journal
CREATE OR REPLACE FUNCTION submit_to_external_journal(
  p_activity_id INTEGER,
  p_journal_id TEXT,
  p_journal_name TEXT
) RETURNS BOOLEAN AS $$
BEGIN
  -- Update the activity to submitted_externally state
  UPDATE pr_activities
  SET 
    current_state = 'submitted_externally',
    published_to = p_journal_id,
    journal_choice = 'external-journal',
    state_change_reason = 'Submitted to external journal: ' || p_journal_name
  WHERE activity_id = p_activity_id 
    AND current_state = 'journal_selection';
  
  IF FOUND THEN
    -- Create external submission record
    INSERT INTO external_journal_submissions (activity_id, journal_id, journal_name)
    VALUES (p_activity_id, p_journal_id, p_journal_name)
    ON CONFLICT (activity_id, journal_id) DO NOTHING;
  END IF;
  
  -- Return true if activity was updated
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION submit_to_external_journal(INTEGER, TEXT, TEXT) IS 'Submits a peer review activity to an external journal';

-- Function to make activity private
CREATE OR REPLACE FUNCTION make_activity_private(
  p_activity_id INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  -- Update the activity to made_private state
  UPDATE pr_activities
  SET 
    current_state = 'made_private',
    journal_choice = 'private',
    state_change_reason = 'Activity made private by author'
  WHERE activity_id = p_activity_id 
    AND current_state = 'journal_selection';
  
  -- Return true if activity was updated
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION make_activity_private(INTEGER) IS 'Makes a peer review activity private (not published anywhere)';

-- Function to set journal selection choice (generic handler)
CREATE OR REPLACE FUNCTION set_journal_selection(
  p_activity_id INTEGER,
  p_choice TEXT
) RETURNS BOOLEAN AS $$
BEGIN
  CASE p_choice
    WHEN 'paperstacks-library' THEN
      RETURN publish_to_paperstacks_library(p_activity_id);
    WHEN 'private' THEN
      RETURN make_activity_private(p_activity_id);
    ELSE
      -- For external journals, this function just sets the choice
      -- The actual external journal submission should use submit_to_external_journal
      UPDATE pr_activities
      SET 
        journal_choice = p_choice,
        state_change_reason = 'Journal selection set to: ' || p_choice
      WHERE activity_id = p_activity_id 
        AND current_state = 'journal_selection';
      
      RETURN FOUND;
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION set_journal_selection(INTEGER, TEXT) IS 'Sets the journal selection choice for a peer review activity';

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION publish_to_paperstacks_library(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION submit_to_external_journal(INTEGER, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION make_activity_private(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION set_journal_selection(INTEGER, TEXT) TO authenticated;

-- Add comments to new table
COMMENT ON TABLE external_journal_submissions IS 'Tracks submissions to external journals separate from activity state';