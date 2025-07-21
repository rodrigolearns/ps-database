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
  assessment      JSONB,        -- for last round, free text + structured ratings
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

-- 3. Paper versioning with git-style versioning support
CREATE TABLE IF NOT EXISTS "Paper_Versions" (
  version_id      SERIAL PRIMARY KEY,
  paper_id        INTEGER NOT NULL
    REFERENCES "Papers"(paper_id) ON DELETE CASCADE,
  version_number  INTEGER NOT NULL,
  file_reference  TEXT NOT NULL,
  sha             TEXT,         -- optional git SHA or content hash
  activity_id     INTEGER REFERENCES "Peer_Review_Activities"(activity_id) ON DELETE SET NULL,
  response_round  INTEGER,
  version_type    TEXT CHECK (version_type IN ('initial', 'revision', 'final', 'other')),
  version_notes   TEXT,
  commit_hash     TEXT,         -- Git commit hash
  parent_commit_hash TEXT,      -- Parent commit hash for tracking history
  branch_name     TEXT DEFAULT 'main', -- Git branch name
  commit_message  TEXT,         -- Git commit message
  diff            JSONB,        -- Store git diff information
  metadata        JSONB DEFAULT '{}'::jsonb,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(paper_id, version_number)
);
COMMENT ON TABLE "Paper_Versions" IS 'All versions of a paper, including author revisions';
COMMENT ON COLUMN "Paper_Versions".activity_id IS 'Optional reference to the PR activity this version is associated with';
COMMENT ON COLUMN "Paper_Versions".response_round IS 'If this is a revision, which review round it responds to';
COMMENT ON COLUMN "Paper_Versions".version_type IS 'Type of version (initial submission, revision, final version, etc.)';
COMMENT ON COLUMN "Paper_Versions".version_notes IS 'Notes about this version, such as change summary';
COMMENT ON COLUMN "Paper_Versions".commit_hash IS 'Git commit hash for this version';
COMMENT ON COLUMN "Paper_Versions".parent_commit_hash IS 'Parent git commit hash for tracking version history';
COMMENT ON COLUMN "Paper_Versions".branch_name IS 'Git branch name for this version';
COMMENT ON COLUMN "Paper_Versions".commit_message IS 'Git commit message describing changes';
COMMENT ON COLUMN "Paper_Versions".diff IS 'JSON representation of git diff from parent version';
COMMENT ON COLUMN "Paper_Versions".metadata IS 'Additional metadata about this version';

-- Create a function to generate a mock commit hash (for testing without actual git integration)
CREATE OR REPLACE FUNCTION generate_mock_commit_hash()
RETURNS TEXT AS $$
DECLARE
  chars TEXT := 'abcdef0123456789';
  result TEXT := '';
  i INTEGER;
BEGIN
  -- Generate a 40-character mock SHA-1 hash
  FOR i IN 1..40 LOOP
    result := result || substr(chars, floor(random() * length(chars) + 1)::INTEGER, 1);
  END LOOP;
  RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Function to automatically create a paper version when a paper is uploaded
CREATE OR REPLACE FUNCTION auto_create_initial_paper_version()
RETURNS TRIGGER AS $$
DECLARE
  v_commit_hash TEXT;
BEGIN
  -- Generate a mock commit hash
  v_commit_hash := generate_mock_commit_hash();
  
  -- Insert an initial version record when a new paper is created
  INSERT INTO "Paper_Versions" (
    paper_id,
    version_number,
    file_reference,
    version_type,
    version_notes,
    commit_hash,
    parent_commit_hash,
    branch_name,
    commit_message
  ) VALUES (
    NEW.paper_id,
    1, -- First version
    NEW.storage_reference,
    'initial',
    'Initial paper submission',
    v_commit_hash,
    NULL, -- No parent for initial version
    'main',
    'Initial paper submission'
  );
  
  -- Store the commit hash in the paper's metadata
  UPDATE "Papers"
  SET 
    metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('latest_commit', v_commit_hash)
  WHERE paper_id = NEW.paper_id;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to automatically create initial paper version
DROP TRIGGER IF EXISTS auto_create_initial_paper_version_trigger ON "Papers";
CREATE TRIGGER auto_create_initial_paper_version_trigger
AFTER INSERT ON "Papers"
FOR EACH ROW
EXECUTE FUNCTION auto_create_initial_paper_version();

-- Function to link author responses with paper versions using git-style versioning
CREATE OR REPLACE FUNCTION link_author_response_to_paper_version()
RETURNS TRIGGER AS $$
DECLARE
  v_paper_id INTEGER;
  v_next_version INTEGER;
  v_commit_hash TEXT;
  v_parent_commit_hash TEXT;
  v_branch_name TEXT := 'review';
BEGIN
  -- Get the paper_id from the activity
  SELECT paper_id INTO v_paper_id
  FROM "Peer_Review_Activities"
  WHERE activity_id = NEW.activity_id;
  
  IF v_paper_id IS NULL THEN
    RAISE WARNING 'Could not find paper_id for activity_id %', NEW.activity_id;
    RETURN NEW;
  END IF;
  
  -- Find the next version number for this paper
  SELECT COALESCE(MAX(version_number) + 1, 1) INTO v_next_version
  FROM "Paper_Versions"
  WHERE paper_id = v_paper_id;
  
  -- Get the current latest commit hash to use as parent
  SELECT commit_hash INTO v_parent_commit_hash
  FROM "Paper_Versions"
  WHERE paper_id = v_paper_id
  ORDER BY version_number DESC
  LIMIT 1;
  
  -- Generate a new commit hash
  v_commit_hash := generate_mock_commit_hash();
  
  -- Create a new paper version linked to this author response
  INSERT INTO "Paper_Versions" (
    paper_id,
    version_number,
    file_reference,
    activity_id,
    response_round,
    version_type,
    version_notes,
    created_at,
    commit_hash,
    parent_commit_hash,
    branch_name,
    commit_message
  ) VALUES (
    v_paper_id,
    v_next_version,
    NEW.file_reference,
    NEW.activity_id,
    NEW.round_number,
    'revision',
    'Author response to review round ' || NEW.round_number,
    NEW.submitted_at,
    v_commit_hash,
    v_parent_commit_hash,
    v_branch_name || '_round_' || NEW.round_number,
    'Author response to review round ' || NEW.round_number
  );
  
  -- Update the paper's storage_reference to point to the latest version
  -- and update the latest commit hash in metadata
  UPDATE "Papers"
  SET 
    storage_reference = NEW.file_reference,
    metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
      'latest_commit', v_commit_hash,
      'latest_branch', v_branch_name || '_round_' || NEW.round_number
    ),
    updated_at = NOW()
  WHERE paper_id = v_paper_id;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to automatically link author responses to paper versions
DROP TRIGGER IF EXISTS link_author_response_to_paper_version_trigger ON "Author_Responses";
CREATE TRIGGER link_author_response_to_paper_version_trigger
AFTER INSERT ON "Author_Responses"
FOR EACH ROW
WHEN (NEW.file_reference IS NOT NULL)
EXECUTE FUNCTION link_author_response_to_paper_version();

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
