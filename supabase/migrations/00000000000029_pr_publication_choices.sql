-- =============================================
-- 00000000000029_pr_publication_choices.sql
-- PR Activity Domain: Publication Choices
-- =============================================
-- Records author's choice for publication path after peer review completion

-- =============================================
-- PR Publication Choices Table
-- =============================================
CREATE TABLE IF NOT EXISTS pr_publication_choices (
  choice_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL UNIQUE REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  
  -- Publication choice
  choice TEXT NOT NULL CHECK (choice IN ('published_on_ps', 'submitted_externally', 'made_private')),
  
  -- Choice metadata
  chosen_by INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  chosen_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Additional details (optional)
  notes TEXT,  -- Author notes about their choice
  external_submission_details TEXT,  -- If submitted_externally: journal name, submission ID, etc.
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE pr_publication_choices IS 'Records publication path chosen by author after peer review completion';
COMMENT ON COLUMN pr_publication_choices.choice_id IS 'Primary key';
COMMENT ON COLUMN pr_publication_choices.activity_id IS 'Foreign key to pr_activities (one choice per activity)';
COMMENT ON COLUMN pr_publication_choices.choice IS 'Publication path: published_on_ps (public in library), submitted_externally (sent to journal), made_private (archived)';
COMMENT ON COLUMN pr_publication_choices.chosen_by IS 'User who made the choice (corresponding author)';
COMMENT ON COLUMN pr_publication_choices.chosen_at IS 'When choice was made';
COMMENT ON COLUMN pr_publication_choices.notes IS 'Optional notes from author about their decision';
COMMENT ON COLUMN pr_publication_choices.external_submission_details IS 'Details if choice is submitted_externally (for future use)';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_pr_publication_choices_activity ON pr_publication_choices (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_publication_choices_choice ON pr_publication_choices (choice);
CREATE INDEX IF NOT EXISTS idx_pr_publication_choices_chosen_by ON pr_publication_choices (chosen_by);
CREATE INDEX IF NOT EXISTS idx_pr_publication_choices_published ON pr_publication_choices (choice, chosen_at DESC) WHERE choice = 'published_on_ps';

-- =============================================
-- Row Level Security
-- =============================================
ALTER TABLE pr_publication_choices ENABLE ROW LEVEL SECURITY;

-- Participants can see publication choices for activities they're part of
CREATE POLICY pr_publication_choices_select_participants ON pr_publication_choices
  FOR SELECT
  USING (
    -- Author can see their own choice
    chosen_by = (SELECT auth_user_id()) OR
    -- Reviewers can see choice if they participated
    EXISTS (
      SELECT 1 FROM pr_reviewers pr
      WHERE pr.activity_id = pr_publication_choices.activity_id
        AND pr.user_id = (SELECT auth_user_id())
    ) OR
    -- Anyone can see if published (paper is public)
    choice = 'published_on_ps' OR
    -- Service role can see all
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify (via API routes that validate author permission)
CREATE POLICY pr_publication_choices_modify_service_role_only ON pr_publication_choices
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY pr_publication_choices_select_participants ON pr_publication_choices IS
  'Participants can see choices; published choices are public';

-- =============================================
-- Notes on Implementation
-- =============================================
-- FOR NOW (Alpha): Only implement 'published_on_ps' in application layer
-- FUTURE: Implement 'submitted_externally' tracking and 'made_private' archival
-- When choice is 'published_on_ps', paper should:
--   1. Be added to public library
--   2. Have full review history visible
--   3. Show final assessment to all users

