-- =============================================
-- 00000000000107_pr_evaluations.sql
-- Collaborative Evaluation System with Git-like Versioning
-- =============================================

-- 1. Collaborative Evaluations Table
-- Stores the main evaluation document for each activity
CREATE TABLE IF NOT EXISTS collaborative_evaluations (
  evaluation_id    SERIAL PRIMARY KEY,
  activity_id      INTEGER NOT NULL
    REFERENCES peer_review_activities(activity_id) ON DELETE CASCADE,
  current_content  TEXT NOT NULL DEFAULT '',
  version_number   INTEGER NOT NULL DEFAULT 1,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  is_finalized     BOOLEAN NOT NULL DEFAULT FALSE,
  finalized_at     TIMESTAMPTZ NULL,
  finalized_by     INTEGER NULL
    REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  UNIQUE(activity_id)
);
COMMENT ON TABLE collaborative_evaluations IS 'Main evaluation documents for peer review activities';

-- 2. Evaluation Versions Table (Git-like versioning)
-- Tracks every change made to the evaluation content
CREATE TABLE IF NOT EXISTS evaluation_versions (
  version_id       SERIAL PRIMARY KEY,
  evaluation_id    INTEGER NOT NULL
    REFERENCES collaborative_evaluations(evaluation_id) ON DELETE CASCADE,
  version_number   INTEGER NOT NULL,
  content          TEXT NOT NULL,
  change_summary   TEXT,
  author_id        INTEGER NOT NULL
    REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  parent_version_id INTEGER NULL
    REFERENCES evaluation_versions(version_id) ON DELETE SET NULL,
  content_diff     JSONB NULL,  -- Store diff for efficient history viewing
  UNIQUE(evaluation_id, version_number)
);
COMMENT ON TABLE evaluation_versions IS 'Version history for collaborative evaluations (Git-like)';

-- 3. Real-time Editing Sessions Table
-- Tracks who is currently editing for live collaboration
CREATE TABLE IF NOT EXISTS evaluation_editing_sessions (
  session_id       SERIAL PRIMARY KEY,
  evaluation_id    INTEGER NOT NULL
    REFERENCES collaborative_evaluations(evaluation_id) ON DELETE CASCADE,
  user_id          INTEGER NOT NULL
    REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  cursor_position  INTEGER DEFAULT 0,
  selection_start  INTEGER DEFAULT 0,
  selection_end    INTEGER DEFAULT 0,
  last_activity    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  session_token    TEXT NOT NULL,  -- For WebSocket authentication
  UNIQUE(evaluation_id, user_id)
);
COMMENT ON TABLE evaluation_editing_sessions IS 'Active editing sessions for real-time collaboration';

-- 4. Evaluation Comments Table
-- Allow reviewers to leave comments on specific parts of the evaluation
CREATE TABLE IF NOT EXISTS evaluation_comments (
  comment_id       SERIAL PRIMARY KEY,
  evaluation_id    INTEGER NOT NULL
    REFERENCES collaborative_evaluations(evaluation_id) ON DELETE CASCADE,
  author_id        INTEGER NOT NULL
    REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  content          TEXT NOT NULL,
  position_start   INTEGER NOT NULL,  -- Character position in the document
  position_end     INTEGER NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  is_resolved      BOOLEAN NOT NULL DEFAULT FALSE,
  resolved_by      INTEGER NULL
    REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  resolved_at      TIMESTAMPTZ NULL
);
COMMENT ON TABLE evaluation_comments IS 'Comments on specific parts of the evaluation text';

-- 5. Reviewer Finalization Status Table
-- Track which reviewers have approved the current version of the evaluation
CREATE TABLE IF NOT EXISTS reviewer_finalization_status (
  status_id        SERIAL PRIMARY KEY,
  evaluation_id    INTEGER NOT NULL
    REFERENCES collaborative_evaluations(evaluation_id) ON DELETE CASCADE,
  reviewer_id      INTEGER NOT NULL
    REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  has_finalized    BOOLEAN NOT NULL DEFAULT FALSE,
  finalized_at     TIMESTAMPTZ NULL,
  content_version  INTEGER NOT NULL DEFAULT 1,  -- Version they finalized
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(evaluation_id, reviewer_id)
);
COMMENT ON TABLE reviewer_finalization_status IS 'Track reviewer approval status for evaluations';

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_collaborative_evaluations_activity
  ON collaborative_evaluations(activity_id);
CREATE INDEX IF NOT EXISTS idx_evaluation_versions_evaluation
  ON evaluation_versions(evaluation_id, version_number DESC);
CREATE INDEX IF NOT EXISTS idx_evaluation_sessions_evaluation
  ON evaluation_editing_sessions(evaluation_id);
CREATE INDEX IF NOT EXISTS idx_evaluation_sessions_activity
  ON evaluation_editing_sessions(last_activity);
CREATE INDEX IF NOT EXISTS idx_evaluation_comments_evaluation
  ON evaluation_comments(evaluation_id);
CREATE INDEX IF NOT EXISTS idx_reviewer_finalization_evaluation
  ON reviewer_finalization_status(evaluation_id);
CREATE INDEX IF NOT EXISTS idx_reviewer_finalization_reviewer
  ON reviewer_finalization_status(reviewer_id);

-- 5. Functions for evaluation management

-- Function to create a new version when content changes
CREATE OR REPLACE FUNCTION create_evaluation_version()
RETURNS TRIGGER AS $$
BEGIN
  -- Only create version if content actually changed
  IF OLD.current_content IS DISTINCT FROM NEW.current_content THEN
    -- Increment version number
    NEW.version_number := OLD.version_number + 1;
    NEW.updated_at := NOW();
    
    -- Insert new version record
    INSERT INTO evaluation_versions (
      evaluation_id,
      version_number,
      content,
      change_summary,
      author_id,
      parent_version_id
    ) VALUES (
      NEW.evaluation_id,
      NEW.version_number,
      NEW.current_content,
      COALESCE(NEW.change_summary, 'Content updated'),
      COALESCE(NEW.finalized_by, (
        SELECT user_id 
        FROM evaluation_editing_sessions 
        WHERE evaluation_id = NEW.evaluation_id 
        ORDER BY last_activity DESC 
        LIMIT 1
      )),
      (
        SELECT version_id 
        FROM evaluation_versions 
        WHERE evaluation_id = NEW.evaluation_id 
        ORDER BY version_number DESC 
        LIMIT 1
      )
    );
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to automatically create versions
CREATE TRIGGER trg_create_evaluation_version
  BEFORE UPDATE ON collaborative_evaluations
  FOR EACH ROW
  EXECUTE FUNCTION create_evaluation_version();

-- Function to clean up old editing sessions
CREATE OR REPLACE FUNCTION cleanup_old_editing_sessions()
RETURNS void AS $$
BEGIN
  DELETE FROM evaluation_editing_sessions
  WHERE last_activity < NOW() - INTERVAL '1 hour';
END;
$$ LANGUAGE plpgsql;

-- 6. Add evaluation events to the timeline
-- Update the existing timeline view to include evaluation events
CREATE OR REPLACE VIEW pr_activity_timeline AS
-- Paper posted
SELECT
  pra.activity_id,
  'paper_posted'  ::TEXT    AS event_type,
  pra.posted_at            AS event_timestamp,
  pra.creator_id           AS user_id,
  NULL             ::INT    AS round_number,
  jsonb_build_object(
    'paperId', pra.paper_id
  )                        AS event_data
FROM peer_review_activities pra

UNION ALL

-- Reviewer joined
SELECT
  rtm.activity_id,
  'reviewer_joined'::TEXT   AS event_type,
  rtm.joined_at             AS event_timestamp,
  rtm.user_id               AS user_id,
  NULL           ::INT      AS round_number,
  '{}'           ::JSONB    AS event_data
FROM reviewer_team_members rtm

UNION ALL

-- Review submitted
SELECT
  rs.activity_id,
  'review_submitted'::TEXT   AS event_type,
  rs.submitted_at            AS event_timestamp,
  rs.reviewer_id             AS user_id,
  rs.round_number            AS round_number,
  jsonb_build_object(
    'file_reference', rs.file_reference,
    'assessment', rs.assessment
  )                        AS event_data
FROM review_submissions rs

UNION ALL

-- Author response
SELECT
  ar.activity_id,
  'author_response'::TEXT    AS event_type,
  ar.submitted_at            AS event_timestamp,
  ar.user_id                 AS user_id,
  ar.round_number            AS round_number,
  jsonb_build_object(
    'file_reference', ar.file_reference,
    'comments', ar.comments
  )                        AS event_data
FROM author_responses ar

UNION ALL

-- Evaluation created
SELECT
  ce.activity_id,
  'evaluation_created'::TEXT AS event_type,
  ce.created_at             AS event_timestamp,
  NULL           ::INT      AS user_id,
  NULL           ::INT      AS round_number,
  jsonb_build_object(
    'evaluation_id', ce.evaluation_id
  )                        AS event_data
FROM collaborative_evaluations ce

UNION ALL

-- Evaluation updated (significant versions only)
SELECT
  ce.activity_id,
  'evaluation_updated'::TEXT AS event_type,
  ev.created_at             AS event_timestamp,
  ev.author_id              AS user_id,
  NULL           ::INT      AS round_number,
  jsonb_build_object(
    'evaluation_id', ce.evaluation_id,
    'version_number', ev.version_number,
    'change_summary', ev.change_summary
  )                        AS event_data
FROM collaborative_evaluations ce
JOIN evaluation_versions ev ON ce.evaluation_id = ev.evaluation_id
WHERE ev.version_number % 5 = 0 OR ev.change_summary IS NOT NULL

UNION ALL

-- Evaluation finalized
SELECT
  ce.activity_id,
  'evaluation_finalized'::TEXT AS event_type,
  ce.finalized_at           AS event_timestamp,
  ce.finalized_by           AS user_id,
  NULL           ::INT      AS round_number,
  jsonb_build_object(
    'evaluation_id', ce.evaluation_id,
    'final_version', ce.version_number
  )                        AS event_data
FROM collaborative_evaluations ce
WHERE ce.is_finalized = TRUE

UNION ALL

-- Paper version (join back to activity via paper_id)
SELECT
  pra.activity_id,
  'paper_version' ::TEXT     AS event_type,
  pv.created_at             AS event_timestamp,
  NULL            ::INT      AS user_id,
  NULL            ::INT      AS round_number,
  jsonb_build_object(
    'file_reference', pv.file_reference,
    'version_number', pv.version_number,
    'sha', pv.sha
  )                        AS event_data
FROM paper_versions pv
JOIN peer_review_activities pra ON pra.paper_id = pv.paper_id

UNION ALL

-- Penalty
SELECT
  rp.activity_id,
  'penalty'      ::TEXT      AS event_type,
  rp.created_at             AS event_timestamp,
  rp.user_id                AS user_id,
  NULL           ::INT      AS round_number,
  jsonb_build_object(
    'penalty_type', rp.penalty_type,
    'amount', rp.amount
  )                        AS event_data
FROM reviewer_penalties rp

UNION ALL

-- Stage-change (audit log)
SELECT
  sl.activity_id,
  'stage_change' ::TEXT      AS event_type,
  sl.changed_at             AS event_timestamp,
  sl.changed_by             AS user_id,
  NULL            ::INT      AS round_number,
  jsonb_build_object(
    'old', sl.old_state,
    'new', sl.new_state
  )                        AS event_data
FROM pr_activity_state_log sl;

-- 7. Update the materialized view
DROP MATERIALIZED VIEW IF EXISTS mv_pr_activity_timeline;
CREATE MATERIALIZED VIEW mv_pr_activity_timeline AS
  SELECT * FROM pr_activity_timeline
  ORDER BY event_timestamp;

CREATE INDEX IF NOT EXISTS idx_mv_pr_activity_timeline_activity_timestamp
  ON mv_pr_activity_timeline(activity_id, event_timestamp);

-- 8. RLS (Row Level Security) policies for evaluation tables
ALTER TABLE collaborative_evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE evaluation_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE evaluation_editing_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE evaluation_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE reviewer_finalization_status ENABLE ROW LEVEL SECURITY;

-- Policy for collaborative_evaluations: Only reviewers can access
CREATE POLICY "evaluation_reviewer_access" ON collaborative_evaluations
FOR ALL USING (
  activity_id IN (
    SELECT rtm.activity_id 
    FROM reviewer_team_members rtm
    JOIN user_accounts ua ON rtm.user_id = ua.user_id
    WHERE ua.auth_id = auth.uid() AND rtm.status = 'joined'
  )
);

-- Policy for evaluation_versions: Only reviewers can access
CREATE POLICY "evaluation_versions_reviewer_access" ON evaluation_versions
FOR ALL USING (
  evaluation_id IN (
    SELECT ce.evaluation_id
    FROM collaborative_evaluations ce
    JOIN reviewer_team_members rtm ON ce.activity_id = rtm.activity_id
    JOIN user_accounts ua ON rtm.user_id = ua.user_id
    WHERE ua.auth_id = auth.uid() AND rtm.status = 'joined'
  )
);

-- Policy for evaluation_editing_sessions: Only reviewers can access
CREATE POLICY "evaluation_sessions_reviewer_access" ON evaluation_editing_sessions
FOR ALL USING (
  evaluation_id IN (
    SELECT ce.evaluation_id
    FROM collaborative_evaluations ce
    JOIN reviewer_team_members rtm ON ce.activity_id = rtm.activity_id
    JOIN user_accounts ua ON rtm.user_id = ua.user_id
    WHERE ua.auth_id = auth.uid() AND rtm.status = 'joined'
  )
);

-- Policy for evaluation_comments: Only reviewers can access
CREATE POLICY "evaluation_comments_reviewer_access" ON evaluation_comments
FOR ALL USING (
  evaluation_id IN (
    SELECT ce.evaluation_id
    FROM collaborative_evaluations ce
    JOIN reviewer_team_members rtm ON ce.activity_id = rtm.activity_id
    JOIN user_accounts ua ON rtm.user_id = ua.user_id
    WHERE ua.auth_id = auth.uid() AND rtm.status = 'joined'
  )
);

-- Policy for reviewer_finalization_status: Only reviewers can access
CREATE POLICY "reviewer_finalization_reviewer_access" ON reviewer_finalization_status
FOR ALL USING (
  evaluation_id IN (
    SELECT ce.evaluation_id
    FROM collaborative_evaluations ce
    JOIN reviewer_team_members rtm ON ce.activity_id = rtm.activity_id
    JOIN user_accounts ua ON rtm.user_id = ua.user_id
    WHERE ua.auth_id = auth.uid() AND rtm.status = 'joined'
  )
);
