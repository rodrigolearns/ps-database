-- =============================================
-- 00000000000020_peer_reviewing.sql
-- Peer‑Review file‑exchange and versioning
-- =============================================

-- 1. Review submissions table
CREATE TABLE IF NOT EXISTS "Review_Submissions" (
  submission_id   SERIAL PRIMARY KEY,
  activity_id     INTEGER NOT NULL
    REFERENCES "Peer_Review_Activities"(activity_id) ON DELETE CASCADE,
  reviewer_id     INTEGER NOT NULL
    REFERENCES "User_Accounts"(user_id) ON DELETE CASCADE,
  round_number    INTEGER NOT NULL,
  file_reference  TEXT NOT NULL,
  assessment      JSONB,        -- free text + (for last round) structured ratings
  submitted_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, reviewer_id, round_number)
);
COMMENT ON TABLE "Review_Submissions" IS 'Files & assessments uploaded by reviewers for each round';

-- 2. Author responses table
CREATE TABLE IF NOT EXISTS "Author_Responses" (
  response_id     SERIAL PRIMARY KEY,
  activity_id     INTEGER NOT NULL
    REFERENCES "Peer_Review_Activities"(activity_id) ON DELETE CASCADE,
  round_number    INTEGER NOT NULL,
  file_reference  TEXT NOT NULL,
  comments        JSONB,        -- per-reviewer point‑by‑point responses
  submitted_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, round_number)
);
COMMENT ON TABLE "Author_Responses" IS 'Authors revised manuscripts and responses';

-- 3. Paper versioning
CREATE TABLE IF NOT EXISTS "Paper_Versions" (
  version_id      SERIAL PRIMARY KEY,
  paper_id        INTEGER NOT NULL
    REFERENCES "Papers"(paper_id) ON DELETE CASCADE,
  version_number  INTEGER NOT NULL,
  file_reference  TEXT NOT NULL,
  sha             TEXT,         -- optional git SHA or content hash
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(paper_id, version_number)
);
COMMENT ON TABLE "Paper_Versions" IS 'All versions of a paper, including author revisions';

-- =============================================
-- View Creation
-- =============================================

-- View for user's review activities (completed and active)
DROP VIEW IF EXISTS "User_Review_Activities";
CREATE OR REPLACE VIEW "User_Review_Activities" AS
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
  (SELECT COUNT(*) FROM "Review_Submissions" rs 
   WHERE rs.activity_id = pra.activity_id AND rs.reviewer_id = rtm.user_id) AS reviews_submitted,
  (SELECT MAX(rs.round_number) FROM "Review_Submissions" rs 
   WHERE rs.activity_id = pra.activity_id AND rs.reviewer_id = rtm.user_id) AS last_round_completed
FROM "Reviewer_Team_Members" rtm
JOIN "Peer_Review_Activities" pra ON rtm.activity_id = pra.activity_id
JOIN "Papers" p ON pra.paper_id = p.paper_id
-- NOTE: This view intentionally does NOT filter by status, allowing frontend to decide which statuses to show.
-- It also does NOT include author details or abstract to keep it simpler.
-- It might need further joins if more detailed info is needed directly from the view.
ORDER BY 
  CASE WHEN pra.completed_at IS NULL THEN 0 ELSE 1 END,
  pra.stage_deadline ASC NULLS LAST,
  rtm.joined_at DESC;
COMMENT ON VIEW "User_Review_Activities" IS 'Basic view of peer review activities a user is associated with, regardless of status';
