-- =============================================
-- 00000000000025_authorship.sql
-- Authors master table and Paper-Author link table
-- =============================================

-- Authors master table (registered or external)
CREATE TABLE IF NOT EXISTS authors (
  author_id    SERIAL PRIMARY KEY,
  full_name    TEXT NOT NULL,
  email        TEXT UNIQUE, -- Made email unique to help prevent duplicates
  orcid        TEXT UNIQUE,
  affiliations JSONB DEFAULT '[]'::jsonb, -- Changed from TEXT to JSONB, added default
  ps_user_id   INTEGER UNIQUE REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON TABLE authors IS 'All people who have authored at least one paper, registered or not';
COMMENT ON COLUMN authors.ps_user_id IS 'Links to user_accounts.user_id when an author registers';
COMMENT ON COLUMN authors.email IS 'Author email, unique where provided';
COMMENT ON COLUMN authors.affiliations IS 'Author affiliations stored as a JSONB array'; -- Updated comment

-- Add trigger for updated_at on authors table
-- Function update_authors_updated_at removed, using generic set_updated_at
DROP TRIGGER IF EXISTS update_authors_updated_at_trigger ON authors;
CREATE TRIGGER update_authors_updated_at_trigger
BEFORE UPDATE ON authors
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- paper_authors Join table
CREATE TABLE IF NOT EXISTS paper_authors (
  paper_id           INTEGER NOT NULL
    REFERENCES papers(paper_id) ON DELETE CASCADE,
  author_id          INTEGER NOT NULL
    REFERENCES authors(author_id) ON DELETE CASCADE,
  author_order       INTEGER NOT NULL, -- Defines the order of authors on the paper
  contribution_group INTEGER NOT NULL DEFAULT 0, -- Group ID for equal contribution
  author_role        TEXT, -- e.g., PI, corresponding, co-first
  PRIMARY KEY (paper_id, author_id)
);
COMMENT ON TABLE paper_authors IS 'Associates papers to authors, preserving order, equal-contrib groups, and special roles';
COMMENT ON COLUMN paper_authors.author_order IS 'Defines the display order of authors on the paper (0-indexed or 1-indexed)';
COMMENT ON COLUMN paper_authors.contribution_group IS 'Group identifier for equal-contribution authors; same number = equal contribution (e.g., 0 for all unique, 1 for first group, etc.)';
COMMENT ON COLUMN paper_authors.author_role IS 'Optional role: e.g. PI, corresponding, co-first';

-- Indexes for paper_authors join table
CREATE INDEX IF NOT EXISTS idx_paper_authors_author_id
  ON paper_authors(author_id);
CREATE INDEX IF NOT EXISTS idx_paper_authors_paper_id
  ON paper_authors(paper_id); 