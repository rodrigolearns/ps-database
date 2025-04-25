-- =============================================
-- 00000000000020_peer_reviewing.sql
-- Peer‑Review file‑exchange and versioning
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
  assessment      JSONB,        -- free text + (for last round) structured ratings
  submitted_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, reviewer_id, round_number)
);
COMMENT ON TABLE review_submissions IS 'Files & assessments uploaded by reviewers for each round';

-- 2. author_responses table
CREATE TABLE IF NOT EXISTS author_responses (
  response_id     SERIAL PRIMARY KEY,
  activity_id     INTEGER NOT NULL
    REFERENCES peer_review_activities(activity_id) ON DELETE CASCADE,
  round_number    INTEGER NOT NULL,
  file_reference  TEXT NOT NULL,
  comments        JSONB,        -- per-reviewer point‑by‑point responses
  submitted_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, round_number)
);
COMMENT ON TABLE author_responses IS 'Authors revised manuscripts and responses';

-- 3. paper_versions table
CREATE TABLE IF NOT EXISTS paper_versions (
  version_id      SERIAL PRIMARY KEY,
  paper_id        INTEGER NOT NULL
    REFERENCES papers(paper_id) ON DELETE CASCADE,
  version_number  INTEGER NOT NULL,
  file_reference  TEXT NOT NULL,
  sha             TEXT,         -- optional git SHA or content hash
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(paper_id, version_number)
);
COMMENT ON TABLE paper_versions IS 'All versions of a paper, including author revisions';

-- =============================================
-- View Creation
-- =============================================

-- View for user's review activities (completed and active)
DROP VIEW IF EXISTS user_review_activities;
CREATE OR REPLACE VIEW user_review_activities AS
SELECT 
  rtm.user_id,
  pra.activity_id,
  pra.activity_uuid,
  pra.paper_id,
  p.title AS paper_title,
  rtm.status AS reviewer_status,
  pra.current_state,
  pra.stage_deadline,
  rtm.joined_at,
  pra.start_date,
  pra.completed_at,
  rtm.rank,
  (SELECT COUNT(*) FROM review_submissions rs 
   WHERE rs.activity_id = pra.activity_id AND rs.reviewer_id = rtm.user_id) AS reviews_submitted,
  (SELECT MAX(rs.round_number) FROM review_submissions rs 
   WHERE rs.activity_id = pra.activity_id AND rs.reviewer_id = rtm.user_id) AS last_round_completed
FROM reviewer_team_members rtm
JOIN peer_review_activities pra ON rtm.activity_id = pra.activity_id
JOIN papers p ON pra.paper_id = p.paper_id
-- NOTE: This view intentionally does NOT filter by status, allowing frontend to decide which statuses to show.
-- It also does NOT include author details or abstract to keep it simpler.
-- It might need further joins if more detailed info is needed directly from the view.
ORDER BY 
  CASE WHEN pra.completed_at IS NULL THEN 0 ELSE 1 END,
  pra.stage_deadline ASC NULLS LAST,
  rtm.joined_at DESC;
COMMENT ON VIEW user_review_activities IS 'Basic view of peer review activities a user is associated with, regardless of status';
