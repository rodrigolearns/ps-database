-- =====================================================
-- Library Publishing Migration
-- Adds support for publishing pr-activities to library
-- =====================================================

-- Add 'publication_choice' and 'published' to the activity_state enum
ALTER TYPE activity_state ADD VALUE IF NOT EXISTS 'publication_choice';
ALTER TYPE activity_state ADD VALUE IF NOT EXISTS 'published';

-- Add columns to pr_activities table for publishing
ALTER TABLE pr_activities 
ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS published_to TEXT,
ADD COLUMN IF NOT EXISTS publication_choice TEXT; -- 'paperstacks-library', 'external-journal', 'private'

-- Create index for published activities
CREATE INDEX IF NOT EXISTS idx_pr_activities_published 
ON pr_activities(current_state, published_to, published_at);

-- Create index for publication choices
CREATE INDEX IF NOT EXISTS idx_pr_activities_publication_choice 
ON pr_activities(publication_choice, current_state);

-- Add comment to document the new columns
COMMENT ON COLUMN pr_activities.published_at IS 'Timestamp when the activity was published to a journal/library';
COMMENT ON COLUMN pr_activities.published_to IS 'Identifier of the journal/library where the activity was published (e.g., paperstacks-library, elife)';
COMMENT ON COLUMN pr_activities.publication_choice IS 'Authors publication choice: paperstacks-library, external-journal, or private';

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

-- Simple function to publish activity to PaperStacks Library
CREATE OR REPLACE FUNCTION publish_to_paperstacks_library(
  p_activity_id INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  -- Update the activity to published state
  UPDATE pr_activities
  SET 
    current_state = 'published',
    published_at = CURRENT_TIMESTAMP,
    published_to = 'paperstacks-library',
    publication_choice = 'paperstacks-library',
    state_change_reason = 'Published to PaperStacks Library'
  WHERE activity_id = p_activity_id 
    AND current_state = 'publication_choice';
  
  -- Return true if activity was updated
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION publish_to_paperstacks_library(INTEGER) IS 'Publishes a peer review activity to PaperStacks Library';

-- Simple function to set publication choice
CREATE OR REPLACE FUNCTION set_publication_choice(
  p_activity_id INTEGER,
  p_choice TEXT
) RETURNS BOOLEAN AS $$
BEGIN
  -- Update the activity publication choice
  UPDATE pr_activities
  SET 
    publication_choice = p_choice,
    state_change_reason = 'Publication choice set to ' || p_choice
  WHERE activity_id = p_activity_id 
    AND current_state = 'publication_choice';
  
  -- Return true if activity was updated
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION set_publication_choice(INTEGER, TEXT) IS 'Sets the publication choice for a peer review activity';

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION publish_to_paperstacks_library(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION set_publication_choice(INTEGER, TEXT) TO authenticated;

-- Add comments to new table
COMMENT ON TABLE external_journal_submissions IS 'Tracks submissions to external journals separate from activity state'; 