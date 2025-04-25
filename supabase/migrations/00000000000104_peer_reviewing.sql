-- =============================================
-- 00000000000104_peer_reviewing.sql
-- Peer-Review File Exchange, Versioning & Unified Timeline
-- =============================================

-- 1. review_submissions table
CREATE TABLE IF NOT EXISTS review_submissions (
  submission_id   SERIAL PRIMARY KEY,
  activity_id     INTEGER NOT NULL
    REFERENCES peer_review_activities(activity_id) ON DELETE CASCADE,
  reviewer_id     INTEGER NOT NULL
    REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  round_number    INTEGER NOT NULL,
  file_reference  TEXT NOT NULL,
  assessment      JSONB,                      -- Free text + (last round) structured ratings
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(activity_id, reviewer_id, round_number)
);
COMMENT ON TABLE review_submissions IS 'Files & assessments uploaded by reviewers for each round';

-- 2. author_responses table
CREATE TABLE IF NOT EXISTS author_responses (
  response_id      SERIAL PRIMARY KEY,
  activity_id      INTEGER NOT NULL
    REFERENCES peer_review_activities(activity_id) ON DELETE CASCADE,
  round_number     INTEGER NOT NULL,
  file_reference   TEXT NOT NULL,
  comments         JSONB,                      -- Per-reviewer point-by-point responses
  submitted_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(activity_id, round_number)
);
COMMENT ON TABLE author_responses IS 'Authors revised manuscripts and responses';

-- 3. paper_versions table
CREATE TABLE IF NOT EXISTS paper_versions (
  version_id       SERIAL PRIMARY KEY,
  paper_id         INTEGER NOT NULL
    REFERENCES papers(paper_id) ON DELETE CASCADE,
  version_number   INTEGER NOT NULL,
  file_reference   TEXT NOT NULL,
  sha              TEXT,                       -- Optional Git SHA or content hash
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(paper_id, version_number)
);
COMMENT ON TABLE paper_versions IS 'All versions of a paper, including author revisions';

-- 4. reviewer_penalties table
CREATE TABLE IF NOT EXISTS reviewer_penalties (
  penalty_id   SERIAL PRIMARY KEY,
  activity_id  INTEGER NOT NULL
    REFERENCES peer_review_activities(activity_id) ON DELETE CASCADE,
  user_id      INTEGER NOT NULL
    REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  penalty_type TEXT NOT NULL
    CHECK (penalty_type IN ('late','kicked_out')),
  amount       INTEGER NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE reviewer_penalties IS 'Records of penalties (token fines or kick-outs) for reviewers';

-- 5. Unified timeline view
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
  'reviewer_joined'::TEXT,
  rtm.joined_at,
  rtm.user_id,
  NULL           ::INT,
  '{}'           ::JSONB
FROM reviewer_team_members rtm

UNION ALL
-- Review submitted
SELECT
  rs.activity_id,
  'review_submitted'::TEXT,
  rs.submitted_at,
  rs.reviewer_id,
  rs.round_number      AS round_number,
  jsonb_build_object(
    'file_reference', rs.file_reference,
    'assessment', rs.assessment
  )                        AS event_data
FROM review_submissions rs

UNION ALL
-- Author response
SELECT
  ar.activity_id,
  'author_response'::TEXT,
  ar.submitted_at,
  NULL           ::INT,
  ar.round_number AS round_number,
  jsonb_build_object(
    'file_reference', ar.file_reference,
    'comments', ar.comments
  )                        AS event_data
FROM author_responses ar

UNION ALL
-- Paper version (join back to activity via paper_id)
SELECT
  pra.activity_id,
  'paper_version' ::TEXT,
  pv.created_at,
  NULL            ::INT,
  NULL            ::INT,
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
  'penalty'      ::TEXT,
  rp.created_at,
  rp.user_id,
  NULL           ::INT,
  jsonb_build_object(
    'penalty_type', rp.penalty_type,
    'amount', rp.amount
  )                        AS event_data
FROM reviewer_penalties rp

UNION ALL
-- Stage-change (audit log)
SELECT
  sl.activity_id,
  'stage_change' ::TEXT,
  sl.changed_at,
  sl.changed_by,
  NULL            ::INT,
  jsonb_build_object(
    'old', sl.old_state,
    'new', sl.new_state
  )                        AS event_data
FROM pr_activity_state_log sl

ORDER BY event_timestamp;

COMMENT ON VIEW pr_activity_timeline IS 'Unified timeline of all events in a peer-review activity';

-- 6. Enforce that submissions match the activity's current_state
CREATE OR REPLACE FUNCTION enforce_submission_round()
RETURNS TRIGGER AS $$
DECLARE
  current_stage activity_state;
BEGIN
  SELECT current_state
    INTO current_stage
  FROM peer_review_activities
  WHERE activity_id = NEW.activity_id;

  IF TG_TABLE_NAME = 'review_submissions'
     AND current_stage <> format('review_round_%s', NEW.round_number)::activity_state
  THEN
    RAISE EXCEPTION 'Cannot submit review for round % at stage %', 
      NEW.round_number, current_stage;
  END IF;

  IF TG_TABLE_NAME = 'author_responses'
     AND current_stage <> format('author_response_%s', NEW.round_number)::activity_state
  THEN
    RAISE EXCEPTION 'Cannot submit author response for round % at stage %', 
      NEW.round_number, current_stage;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_review_sub_round
  BEFORE INSERT ON review_submissions
  FOR EACH ROW EXECUTE FUNCTION enforce_submission_round();

CREATE TRIGGER trg_author_resp_round
  BEFORE INSERT ON author_responses
  FOR EACH ROW EXECUTE FUNCTION enforce_submission_round();

-- 7. (Optional) Materialized view for performance
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_pr_activity_timeline AS
  SELECT * FROM pr_activity_timeline;

CREATE INDEX IF NOT EXISTS idx_mv_pr_activity_timeline_activity_timestamp
  ON mv_pr_activity_timeline(activity_id, event_timestamp);
