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
