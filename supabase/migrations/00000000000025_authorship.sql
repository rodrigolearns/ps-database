-- =============================================
-- 00000000000025_authorship.sql
-- Authors master table and Paper-Author link table
-- =============================================

-- Authors master table (registered or external researchers)
CREATE TABLE IF NOT EXISTS "Authors" (
  author_id    SERIAL PRIMARY KEY,
  full_name    TEXT NOT NULL,
  email        TEXT UNIQUE, -- Made email unique to help prevent duplicates
  orcid        TEXT UNIQUE,
  affiliations JSONB DEFAULT '[]'::jsonb, -- Changed from TEXT to JSONB, added default
  ps_user_id   INTEGER UNIQUE REFERENCES "User_Accounts"(user_id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON TABLE "Authors" IS 'All people who have authored at least one paper, registered or not';
COMMENT ON COLUMN "Authors".ps_user_id IS 'Links to User_Accounts.user_id when an author registers';
COMMENT ON COLUMN "Authors".email IS 'Author email, unique where provided';
COMMENT ON COLUMN "Authors".affiliations IS 'Author affiliations stored as a JSONB array'; -- Updated comment

-- Add trigger for updated_at on Authors table
CREATE OR REPLACE FUNCTION update_authors_updated_at() 
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_authors_updated_at_trigger ON "Authors";
CREATE TRIGGER update_authors_updated_at_trigger
BEFORE UPDATE ON "Authors"
FOR EACH ROW
EXECUTE FUNCTION update_authors_updated_at();

-- Paper_Authors Join table
CREATE TABLE IF NOT EXISTS "Paper_Authors" (
  paper_id           INTEGER NOT NULL
    REFERENCES "Papers"(paper_id) ON DELETE CASCADE,
  author_id          INTEGER NOT NULL
    REFERENCES "Authors"(author_id) ON DELETE CASCADE,
  author_order       INTEGER NOT NULL, -- Defines the order of authors on the paper
  contribution_group INTEGER NOT NULL DEFAULT 0, -- Group ID for equal contribution
  author_role        TEXT, -- e.g., PI, corresponding, co-first
  PRIMARY KEY (paper_id, author_id)
);
COMMENT ON TABLE "Paper_Authors" IS 'Associates papers to authors, preserving order, equal-contrib groups, and special roles';
COMMENT ON COLUMN "Paper_Authors".author_order IS 'Defines the display order of authors on the paper (0-indexed or 1-indexed)';
COMMENT ON COLUMN "Paper_Authors".contribution_group IS 'Group identifier for equal-contribution authors; same number = equal contribution (e.g., 0 for all unique, 1 for first group, etc.)';
COMMENT ON COLUMN "Paper_Authors".author_role IS 'Optional role: e.g. PI, corresponding, co-first';

-- Indexes for Paper_Authors join table
CREATE INDEX IF NOT EXISTS idx_paper_authors_author_id
  ON "Paper_Authors"(author_id);
CREATE INDEX IF NOT EXISTS idx_paper_authors_paper_id
  ON "Paper_Authors"(paper_id); 