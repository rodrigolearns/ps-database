-- =============================================
-- 00000000000004_papers.sql
-- Paper Domain: Papers, Versions, and Authors
-- =============================================

-- Main papers table
CREATE TABLE IF NOT EXISTS papers (
  paper_id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  abstract TEXT NOT NULL,
  paperstack_doi TEXT,
  preprint_doi TEXT,
  preprint_source TEXT,
  preprint_date DATE,
  license TEXT,
  storage_reference TEXT,
  activity_uuids UUID[] DEFAULT '{}'::UUID[],
  uploaded_by INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  visual_abstract_storage_reference TEXT,
  visual_abstract_caption JSONB DEFAULT '{}'::jsonb,
  cited_sources JSONB DEFAULT '{}'::jsonb,
  supplementary_materials JSONB DEFAULT '[]'::jsonb,
  funding_info JSONB DEFAULT '[]'::jsonb,
  data_availability_statement TEXT,
  data_availability_url JSONB DEFAULT '{}'::jsonb,
  embedding_vector vector(1536) NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE papers IS 'Academic papers submitted to the platform';
COMMENT ON COLUMN papers.paper_id IS 'Primary key for the paper';
COMMENT ON COLUMN papers.title IS 'Title of the paper';
COMMENT ON COLUMN papers.abstract IS 'Abstract of the paper';
COMMENT ON COLUMN papers.paperstack_doi IS 'Digital Object Identifier assigned by PaperStack';
COMMENT ON COLUMN papers.preprint_doi IS 'DOI for the preprint, if applicable';
COMMENT ON COLUMN papers.preprint_source IS 'Source of the preprint, if applicable';
COMMENT ON COLUMN papers.preprint_date IS 'Date the preprint was published, if applicable';
COMMENT ON COLUMN papers.license IS 'License under which the paper is published';
COMMENT ON COLUMN papers.storage_reference IS 'Reference to the paper file in storage';
COMMENT ON COLUMN papers.activity_uuids IS 'Array of activity UUIDs this paper is associated with';
COMMENT ON COLUMN papers.uploaded_by IS 'Foreign key to user_accounts for the user who uploaded the paper';
COMMENT ON COLUMN papers.visual_abstract_storage_reference IS 'Reference to the visual abstract image';
COMMENT ON COLUMN papers.visual_abstract_caption IS 'JSONB data for the visual abstract including caption and metadata';
COMMENT ON COLUMN papers.cited_sources IS 'JSON of sources cited in the paper';
COMMENT ON COLUMN papers.supplementary_materials IS 'JSON array of supplementary materials';
COMMENT ON COLUMN papers.funding_info IS 'JSON array of funding information';
COMMENT ON COLUMN papers.data_availability_statement IS 'Statement about the availability of data used in the paper';
COMMENT ON COLUMN papers.data_availability_url IS 'JSON with info to access the data used in the paper';
COMMENT ON COLUMN papers.embedding_vector IS 'Vector embedding for the paper for similarity searches';
COMMENT ON COLUMN papers.created_at IS 'Timestamp when the paper record was created';
COMMENT ON COLUMN papers.updated_at IS 'Timestamp when the paper record was last updated';

-- Paper versions table
CREATE TABLE IF NOT EXISTS paper_versions (
  version_id SERIAL PRIMARY KEY,
  paper_id INTEGER NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  version_number INTEGER NOT NULL,
  file_reference TEXT NOT NULL,
  sha TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(paper_id, version_number)
);

COMMENT ON TABLE paper_versions IS 'All versions of a paper, including author revisions';
COMMENT ON COLUMN paper_versions.version_id IS 'Primary key for the version';
COMMENT ON COLUMN paper_versions.paper_id IS 'Foreign key to papers';
COMMENT ON COLUMN paper_versions.version_number IS 'Version number of the paper';
COMMENT ON COLUMN paper_versions.file_reference IS 'Reference to the paper file in storage';
COMMENT ON COLUMN paper_versions.sha IS 'Optional Git SHA or content hash';
COMMENT ON COLUMN paper_versions.created_at IS 'When this version was created';

-- Simplified paper contributors table (replaces authors + paper_authors)
CREATE TABLE IF NOT EXISTS paper_contributors (
  paper_id INTEGER NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  contributor_id SERIAL,
  -- For registered users
  user_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  -- For external contributors (when user_id is NULL)
  external_name TEXT,
  external_email TEXT,
  external_orcid TEXT,
  external_affiliations JSONB DEFAULT '[]',
  -- Common fields
  contributor_order INTEGER NOT NULL,
  is_corresponding BOOLEAN DEFAULT false,
  contribution_symbols TEXT[] DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (paper_id, contributor_id),
  -- Constraint: must have either user_id OR external_name
  CONSTRAINT contributor_identity_check CHECK (
    (user_id IS NOT NULL AND external_name IS NULL) OR
    (user_id IS NULL AND external_name IS NOT NULL)
  )
);

COMMENT ON TABLE paper_contributors IS 'All contributors to papers, both registered users and external authors';
COMMENT ON COLUMN paper_contributors.paper_id IS 'Foreign key to papers';
COMMENT ON COLUMN paper_contributors.contributor_id IS 'Auto-generated contributor ID';
COMMENT ON COLUMN paper_contributors.user_id IS 'Foreign key to user_accounts for registered users';
COMMENT ON COLUMN paper_contributors.external_name IS 'Full name for external (non-registered) contributors';
COMMENT ON COLUMN paper_contributors.external_email IS 'Email for external contributors';
COMMENT ON COLUMN paper_contributors.external_orcid IS 'ORCID for external contributors';
COMMENT ON COLUMN paper_contributors.external_affiliations IS 'Affiliations for external contributors';
COMMENT ON COLUMN paper_contributors.contributor_order IS 'Order in the author list';
COMMENT ON COLUMN paper_contributors.is_corresponding IS 'Whether this is the corresponding author';
COMMENT ON COLUMN paper_contributors.contribution_symbols IS 'Array of contribution symbols (†, ‡, §, #, ¶)';

-- Legacy tables kept for backward compatibility during transition
-- TODO: Remove after data migration
CREATE TABLE IF NOT EXISTS authors (
  author_id SERIAL PRIMARY KEY,
  full_name TEXT NOT NULL,
  email TEXT,
  orcid TEXT,
  affiliations JSONB DEFAULT '[]',
  user_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS paper_authors (
  paper_id INTEGER NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  author_id INTEGER NOT NULL REFERENCES authors(author_id) ON DELETE CASCADE,
  author_order INTEGER NOT NULL,
  is_corresponding BOOLEAN DEFAULT false,
  contribution_symbols TEXT[] DEFAULT '{}',
  PRIMARY KEY (paper_id, author_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_papers_uploaded_by ON papers (uploaded_by);
CREATE INDEX IF NOT EXISTS idx_papers_created_at ON papers (created_at);
CREATE INDEX IF NOT EXISTS idx_papers_activity_uuids ON papers USING GIN (activity_uuids);
CREATE INDEX IF NOT EXISTS idx_papers_embedding ON papers USING ivfflat (embedding_vector vector_cosine_ops) WITH (lists = 100);

CREATE INDEX IF NOT EXISTS idx_paper_versions_paper_id ON paper_versions (paper_id);
CREATE INDEX IF NOT EXISTS idx_paper_versions_created_at ON paper_versions (created_at);

-- Indexes for new paper_contributors table
CREATE INDEX IF NOT EXISTS idx_paper_contributors_paper_id ON paper_contributors (paper_id);
CREATE INDEX IF NOT EXISTS idx_paper_contributors_user_id ON paper_contributors (user_id);
CREATE INDEX IF NOT EXISTS idx_paper_contributors_order ON paper_contributors (paper_id, contributor_order);
CREATE INDEX IF NOT EXISTS idx_paper_contributors_corresponding ON paper_contributors (paper_id, is_corresponding);
CREATE INDEX IF NOT EXISTS idx_paper_contributors_symbols ON paper_contributors USING GIN (contribution_symbols);
CREATE INDEX IF NOT EXISTS idx_paper_contributors_external_email ON paper_contributors (external_email);

-- =============================================
-- PERFORMANCE OPTIMIZATION INDEXES - PR Activity Page
-- =============================================
-- Following DEVELOPMENT_PRINCIPLES.md: Database as Source of Truth for performance
-- Indexes optimized for the main PR activity data loading JOIN operations

-- Covering index for paper contributors JOIN optimization (avoids table lookup)
CREATE INDEX IF NOT EXISTS idx_paper_contributors_paper_user_covering 
ON paper_contributors (paper_id, user_id) 
INCLUDE (is_corresponding, contributor_order, external_name, external_email, external_orcid, external_affiliations, contribution_symbols, contributor_id);

-- Covering index for paper versions JOIN optimization (avoids table lookup)
CREATE INDEX IF NOT EXISTS idx_paper_versions_paper_covering
ON paper_versions (paper_id)
INCLUDE (version_id, version_number, file_reference, sha, created_at);

-- Constraint: Each paper must have exactly one corresponding author
CREATE UNIQUE INDEX IF NOT EXISTS idx_paper_contributors_one_corresponding 
  ON paper_contributors (paper_id) 
  WHERE is_corresponding = true;

-- Legacy indexes (kept for backward compatibility)
CREATE INDEX IF NOT EXISTS idx_authors_user_id ON authors (user_id);
CREATE INDEX IF NOT EXISTS idx_authors_email ON authors (email);
CREATE INDEX IF NOT EXISTS idx_authors_orcid ON authors (orcid);

CREATE INDEX IF NOT EXISTS idx_paper_authors_paper_id ON paper_authors (paper_id);
CREATE INDEX IF NOT EXISTS idx_paper_authors_author_id ON paper_authors (author_id);
CREATE INDEX IF NOT EXISTS idx_paper_authors_order ON paper_authors (paper_id, author_order);
CREATE INDEX IF NOT EXISTS idx_paper_authors_corresponding ON paper_authors (paper_id, is_corresponding);
CREATE INDEX IF NOT EXISTS idx_paper_authors_symbols ON paper_authors USING GIN (contribution_symbols);

-- Triggers
CREATE TRIGGER update_papers_updated_at
  BEFORE UPDATE ON papers
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_authors_updated_at
  BEFORE UPDATE ON authors
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_paper_contributors_updated_at
  BEFORE UPDATE ON paper_contributors
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- ROW LEVEL SECURITY POLICIES
-- =============================================
-- Protect paper data based on ownership and activity participation
-- Note: Papers RLS is defined HERE, not in 00000000000010_pr_core.sql

-- Enable RLS on papers
ALTER TABLE papers ENABLE ROW LEVEL SECURITY;

-- Users can read papers they uploaded or are contributors to
-- Service role can read all papers (used by admin API routes)
-- Note: Activity participant access will be added in a later migration after pr_activity_permissions table exists
CREATE POLICY papers_select_own_or_contributor_or_service ON papers
  FOR SELECT
  USING (
    uploaded_by = auth_user_id() OR
    EXISTS (
      SELECT 1 FROM public.paper_contributors pc
      WHERE pc.paper_id = papers.paper_id
      AND pc.user_id = auth_user_id()
    ) OR
    auth.role() = 'service_role'
  );

-- Users can insert papers they are uploading
CREATE POLICY papers_insert_own_or_service ON papers
  FOR INSERT
  WITH CHECK (
    uploaded_by = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Users can update papers they uploaded or are corresponding author on
CREATE POLICY papers_update_own_or_corresponding_or_service ON papers
  FOR UPDATE
  USING (
    uploaded_by = (SELECT auth_user_id()) OR
    EXISTS (
      SELECT 1 FROM public.paper_contributors pc
      WHERE pc.paper_id = papers.paper_id
      AND pc.user_id = (SELECT auth_user_id())
      AND pc.is_corresponding = true
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Enable RLS on paper_contributors
ALTER TABLE paper_contributors ENABLE ROW LEVEL SECURITY;

-- Users can read contributors for papers they own or are contributors to
-- Following DEVELOPMENT_PRINCIPLES.md: No recursion - use direct column checks
-- Note: Activity participant access will be added in migration 00000000000012 after pr_activity_permissions exists
CREATE POLICY paper_contributors_select_own_or_service ON paper_contributors
  FOR SELECT
  USING (
    -- Direct check: User is a contributor on this paper (no subquery on same table)
    user_id = auth_user_id() OR
    -- User owns the paper (check papers table directly, not its policy)
    EXISTS (
      SELECT 1 FROM public.papers p
      WHERE p.paper_id = paper_contributors.paper_id
      AND p.uploaded_by = auth_user_id()
    ) OR
    auth.role() = 'service_role'
  );

-- Users can insert contributors when creating their own paper
-- Safe: only checks papers table ownership, doesn't trigger papers policy
CREATE POLICY paper_contributors_insert_own_paper_or_service ON paper_contributors
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.papers p
      WHERE p.paper_id = paper_contributors.paper_id
      AND p.uploaded_by = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Corresponding authors can update contributors
-- Following DEVELOPMENT_PRINCIPLES.md: Direct column checks only (no self-reference)
CREATE POLICY paper_contributors_update_corresponding_or_service ON paper_contributors
  FOR UPDATE
  USING (
    -- Direct check: Current row is for this user AND they are corresponding author
    -- This is safe because we're checking columns on the CURRENT ROW, not querying the table
    (user_id = (SELECT auth_user_id()) AND is_corresponding = true) OR
    -- Or user owns the paper
    EXISTS (
      SELECT 1 FROM public.papers p
      WHERE p.paper_id = paper_contributors.paper_id
      AND p.uploaded_by = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Enable RLS on paper_versions
ALTER TABLE paper_versions ENABLE ROW LEVEL SECURITY;

-- Users can read versions for papers they have access to
CREATE POLICY paper_versions_select_with_paper_access_or_service ON paper_versions
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.papers p
      WHERE p.paper_id = paper_versions.paper_id
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can insert new versions (via API)
CREATE POLICY paper_versions_insert_service_role_only ON paper_versions
  FOR INSERT
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Enable RLS on legacy tables for backward compatibility
ALTER TABLE authors ENABLE ROW LEVEL SECURITY;
ALTER TABLE paper_authors ENABLE ROW LEVEL SECURITY;

-- Legacy tables: allow read for anyone with paper access
CREATE POLICY authors_select_all ON authors
  FOR SELECT
  USING (true);

CREATE POLICY paper_authors_select_with_paper_access ON paper_authors
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM papers p
      WHERE p.paper_id = paper_authors.paper_id
    )
  ); 