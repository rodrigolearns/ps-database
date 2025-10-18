-- =============================================
-- 00000000000027_journal_club.sql
-- Journal Club Activities: Free, Manual, Invitation-Only PR Activities
-- =============================================
-- Note: activity_type enum and column are created in migration 26 (needed by progression functions)

-- =============================================
-- 1. INDEXES FOR ACTIVITY TYPE
-- =============================================
-- Add indexes for filtering by activity type
CREATE INDEX IF NOT EXISTS idx_pr_activities_activity_type ON pr_activities(activity_type);

-- Composite index for journal club queries (creator's journal clubs)
CREATE INDEX IF NOT EXISTS idx_pr_activities_type_creator 
ON pr_activities(activity_type, creator_id) 
WHERE activity_type = 'journal_club';

-- Composite index for active journal clubs
CREATE INDEX IF NOT EXISTS idx_pr_activities_type_state 
ON pr_activities(activity_type, current_state) 
WHERE activity_type = 'journal_club';

-- =============================================
-- 2. MODIFY PR_DEADLINES TABLE
-- =============================================
-- Make deadline_days nullable for journal club activities (which have no deadlines)
ALTER TABLE pr_deadlines 
ALTER COLUMN deadline_days DROP NOT NULL;

COMMENT ON COLUMN pr_deadlines.deadline_days IS 'Number of days from state entry to deadline (NULL for journal club activities)';

-- =============================================
-- 3. CREATE JOURNAL CLUB TEMPLATE
-- =============================================
-- Create free journal club template (1 round, unlimited reviewers, 0 tokens)
INSERT INTO pr_templates(name, reviewer_count, review_rounds, total_tokens, extra_tokens)
VALUES ('journal-club-free', 999, 1, 0, 0)
ON CONFLICT (name) DO UPDATE
  SET reviewer_count = EXCLUDED.reviewer_count,
      review_rounds = EXCLUDED.review_rounds,
      total_tokens = EXCLUDED.total_tokens,
      extra_tokens = EXCLUDED.extra_tokens,
      updated_at = NOW();

COMMENT ON COLUMN pr_templates.reviewer_count IS 'Number of reviewers required (999 = unlimited for journal club)';

-- No token ranks for journal club (0 tokens to distribute)
-- Journal club template intentionally has no entries in pr_template_ranks

-- =============================================
-- 4. JOURNAL CLUB INVITATIONS TABLE
-- =============================================
-- Track invitations sent for journal club activities
CREATE TABLE IF NOT EXISTS jc_invitations (
  invitation_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  inviter_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  invitee_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'declined', 'expired')) DEFAULT 'pending',
  invited_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  responded_at TIMESTAMPTZ,
  UNIQUE(activity_id, invitee_id)
);

COMMENT ON TABLE jc_invitations IS 'Invitation tracking for journal club activities';
COMMENT ON COLUMN jc_invitations.invitation_id IS 'Primary key for invitation';
COMMENT ON COLUMN jc_invitations.activity_id IS 'Foreign key to pr_activities (must be journal_club type)';
COMMENT ON COLUMN jc_invitations.inviter_id IS 'User who sent the invitation (activity creator)';
COMMENT ON COLUMN jc_invitations.invitee_id IS 'User who was invited';
COMMENT ON COLUMN jc_invitations.status IS 'Invitation status: pending, accepted, declined, expired';
COMMENT ON COLUMN jc_invitations.invited_at IS 'When invitation was sent';
COMMENT ON COLUMN jc_invitations.responded_at IS 'When invitee responded (accepted/declined)';

-- Indexes for invitation queries
CREATE INDEX IF NOT EXISTS idx_jc_invitations_activity ON jc_invitations(activity_id);
CREATE INDEX IF NOT EXISTS idx_jc_invitations_invitee ON jc_invitations(invitee_id);
CREATE INDEX IF NOT EXISTS idx_jc_invitations_status ON jc_invitations(status);

-- Composite index for pending invitations lookup
CREATE INDEX IF NOT EXISTS idx_jc_invitations_invitee_pending 
ON jc_invitations(invitee_id, status) 
WHERE status = 'pending';

-- =============================================
-- 5. UPDATE NOTIFICATION TYPE CONSTRAINT
-- =============================================
-- Extend notification_type CHECK constraint to include journal club invitation
ALTER TABLE user_notifications 
DROP CONSTRAINT IF EXISTS user_notifications_notification_type_check;

ALTER TABLE user_notifications
ADD CONSTRAINT user_notifications_notification_type_check 
CHECK (notification_type IN (
  'state_transition',
  'deadline_missed', 
  'review_submitted',
  'author_response_submitted',
  'reviewer_joined',
  'reviewer_removed',
  'awards_distributed',
  'activity_published',
  'journal_club_invitation'
));

-- =============================================
-- 6. UPDATE STATE TRANSITIONS FOR JOURNAL CLUB
-- =============================================
-- Journal club activities skip publication_choice stage
-- Add direct transition from awarding to made_private (completion)
INSERT INTO pr_state_transitions (from_state, to_state) VALUES
  ('awarding', 'made_private')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE pr_state_transitions IS 'Valid state transitions (journal club activities skip publication_choice)';

-- =============================================
-- 7. HELPER FUNCTIONS
-- =============================================

-- Function to check if activity is journal club type
CREATE OR REPLACE FUNCTION is_journal_club_activity(p_activity_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
STABLE
AS $$
  SELECT activity_type = 'journal_club'
  FROM public.pr_activities
  WHERE activity_id = p_activity_id;
$$;

COMMENT ON FUNCTION is_journal_club_activity(INTEGER) IS 'Checks if activity is a journal club (free, manual progression)';

-- Function to get journal club activities for a user
CREATE OR REPLACE FUNCTION get_user_journal_clubs(p_user_id INTEGER)
RETURNS TABLE (
  activity_id INTEGER,
  activity_uuid UUID,
  paper_title TEXT,
  current_state activity_state,
  created_at TIMESTAMPTZ,
  reviewer_count BIGINT,
  is_creator BOOLEAN
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    pa.activity_id,
    pa.activity_uuid,
    p.title as paper_title,
    pa.current_state,
    pa.created_at,
    COUNT(DISTINCT rt.user_id) as reviewer_count,
    (pa.creator_id = p_user_id) as is_creator
  FROM public.pr_activities pa
  JOIN public.papers p ON pa.paper_id = p.paper_id
  LEFT JOIN public.pr_reviewer_teams rt ON pa.activity_id = rt.activity_id 
    AND rt.status IN ('joined', 'locked_in')
  WHERE pa.activity_type = 'journal_club'
    AND (
      pa.creator_id = p_user_id OR
      EXISTS (
        SELECT 1 FROM public.pr_reviewer_teams rt2
        WHERE rt2.activity_id = pa.activity_id
        AND rt2.user_id = p_user_id
        AND rt2.status IN ('joined', 'locked_in')
      )
    )
  GROUP BY pa.activity_id, pa.activity_uuid, p.title, pa.current_state, pa.created_at, pa.creator_id
  ORDER BY pa.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION get_user_journal_clubs(INTEGER) IS 'Gets all journal club activities user created or participates in';

-- Function to get pending journal club invitations for a user
CREATE OR REPLACE FUNCTION get_pending_jc_invitations(p_user_id INTEGER)
RETURNS TABLE (
  invitation_id INTEGER,
  activity_id INTEGER,
  paper_title TEXT,
  inviter_name TEXT,
  invited_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    jci.invitation_id,
    jci.activity_id,
    p.title as paper_title,
    ua.username as inviter_name,
    jci.invited_at
  FROM public.jc_invitations jci
  JOIN public.pr_activities pa ON jci.activity_id = pa.activity_id
  JOIN public.papers p ON pa.paper_id = p.paper_id
  JOIN public.user_accounts ua ON jci.inviter_id = ua.user_id
  WHERE jci.invitee_id = p_user_id
    AND jci.status = 'pending'
  ORDER BY jci.invited_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION get_pending_jc_invitations(INTEGER) IS 'Gets pending journal club invitations for a user';

-- =============================================
-- 8. RLS POLICIES FOR JC_INVITATIONS
-- =============================================
ALTER TABLE jc_invitations ENABLE ROW LEVEL SECURITY;

-- Users can view invitations they sent or received
CREATE POLICY jc_invitations_select_own ON jc_invitations
  FOR SELECT
  USING (
    inviter_id = (SELECT auth_user_id()) OR
    invitee_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Activity creators can insert invitations
CREATE POLICY jc_invitations_insert_creator ON jc_invitations
  FOR INSERT
  WITH CHECK (
    inviter_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Invitees can update their invitation status (accept/decline)
CREATE POLICY jc_invitations_update_invitee ON jc_invitations
  FOR UPDATE
  USING (
    invitee_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can delete invitations
CREATE POLICY jc_invitations_delete_service_role_only ON jc_invitations
  FOR DELETE
  USING ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY jc_invitations_select_own ON jc_invitations IS
  'Users see invitations they sent or received';
COMMENT ON POLICY jc_invitations_insert_creator ON jc_invitations IS
  'Activity creators can send invitations';
COMMENT ON POLICY jc_invitations_update_invitee ON jc_invitations IS
  'Invitees can accept/decline invitations';

-- =============================================
-- 9. GRANT PERMISSIONS
-- =============================================
GRANT SELECT, INSERT, UPDATE ON jc_invitations TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE jc_invitations_invitation_id_seq TO authenticated;
GRANT EXECUTE ON FUNCTION is_journal_club_activity(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_journal_clubs(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_pending_jc_invitations(INTEGER) TO authenticated;

-- =============================================
-- 10. SEED NO-DEADLINE CONFIGURATION FOR JOURNAL CLUB
-- =============================================
-- Journal club template has NULL deadlines for all stages
INSERT INTO pr_deadlines (template_id, state_name, deadline_days, warning_days)
SELECT 
  t.template_id,
  d.state_name::public.activity_state,
  NULL as deadline_days,  -- NULL = no deadline
  NULL as warning_days
FROM pr_templates t
CROSS JOIN (
  VALUES 
    ('submitted'),
    ('review_round_1'),
    ('assessment'),
    ('awarding')
) AS d(state_name)
WHERE t.name = 'journal-club-free'
ON CONFLICT (template_id, state_name) DO UPDATE
  SET deadline_days = NULL,
      warning_days = NULL,
      updated_at = NOW();

COMMENT ON TABLE pr_deadlines IS 'Template-specific deadline configuration (NULL deadline_days for journal club)';

