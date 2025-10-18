-- =============================================
-- 00000000000003_papers.sql
-- Paper Domain: Papers, Contributors, and Versions
-- =============================================

-- =============================================
-- Papers Table
-- =============================================
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
COMMENT ON COLUMN papers.preprint_source IS 'Source of the preprint (e.g., bioRxiv, arXiv)';
COMMENT ON COLUMN papers.preprint_date IS 'Date the preprint was published';
COMMENT ON COLUMN papers.license IS 'License under which the paper is published';
COMMENT ON COLUMN papers.storage_reference IS 'Reference to the paper PDF file in storage';
COMMENT ON COLUMN papers.activity_uuids IS 'Array of activity UUIDs this paper is associated with (across all activity types)';
COMMENT ON COLUMN papers.uploaded_by IS 'Foreign key to user_accounts for the user who uploaded the paper';
COMMENT ON COLUMN papers.visual_abstract_storage_reference IS 'Reference to the visual abstract image in storage';
COMMENT ON COLUMN papers.visual_abstract_caption IS 'JSONB data for the visual abstract caption and metadata';
COMMENT ON COLUMN papers.cited_sources IS 'JSON of sources cited in the paper';
COMMENT ON COLUMN papers.supplementary_materials IS 'JSON array of supplementary materials';
COMMENT ON COLUMN papers.funding_info IS 'JSON array of funding information';
COMMENT ON COLUMN papers.data_availability_statement IS 'Statement about the availability of data used in the paper';
COMMENT ON COLUMN papers.data_availability_url IS 'JSON with info to access the data';
COMMENT ON COLUMN papers.embedding_vector IS 'Vector embedding for similarity searches';
COMMENT ON COLUMN papers.created_at IS 'When the paper record was created';
COMMENT ON COLUMN papers.updated_at IS 'When the paper record was last updated';

-- =============================================
-- Paper Versions Table
-- =============================================
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
COMMENT ON COLUMN paper_versions.version_number IS 'Version number (1, 2, 3, etc.)';
COMMENT ON COLUMN paper_versions.file_reference IS 'Reference to the paper file in storage';
COMMENT ON COLUMN paper_versions.sha IS 'Optional Git SHA or content hash';
COMMENT ON COLUMN paper_versions.created_at IS 'When this version was created';

-- =============================================
-- Paper Contributors Table
-- =============================================
-- Unified table for both registered users and external contributors
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
COMMENT ON COLUMN paper_contributors.contribution_symbols IS 'CRediT taxonomy symbols (†, ‡, §, #, ¶)';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_papers_uploaded_by ON papers (uploaded_by);
CREATE INDEX IF NOT EXISTS idx_papers_created_at ON papers (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_papers_activity_uuids ON papers USING GIN (activity_uuids);
CREATE INDEX IF NOT EXISTS idx_papers_embedding ON papers USING ivfflat (embedding_vector vector_cosine_ops) WITH (lists = 100);

CREATE INDEX IF NOT EXISTS idx_paper_versions_paper_id ON paper_versions (paper_id);
CREATE INDEX IF NOT EXISTS idx_paper_versions_created_at ON paper_versions (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_paper_contributors_paper_id ON paper_contributors (paper_id);
CREATE INDEX IF NOT EXISTS idx_paper_contributors_user_id ON paper_contributors (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_paper_contributors_order ON paper_contributors (paper_id, contributor_order);
CREATE INDEX IF NOT EXISTS idx_paper_contributors_corresponding ON paper_contributors (paper_id, is_corresponding) WHERE is_corresponding = true;
CREATE INDEX IF NOT EXISTS idx_paper_contributors_symbols ON paper_contributors USING GIN (contribution_symbols);
CREATE INDEX IF NOT EXISTS idx_paper_contributors_external_email ON paper_contributors (external_email) WHERE external_email IS NOT NULL;

-- Covering indexes for JOIN optimization
CREATE INDEX IF NOT EXISTS idx_paper_contributors_paper_user_covering 
ON paper_contributors (paper_id, user_id) 
INCLUDE (is_corresponding, contributor_order, external_name, external_email, external_orcid, external_affiliations, contribution_symbols, contributor_id);

CREATE INDEX IF NOT EXISTS idx_paper_versions_paper_covering
ON paper_versions (paper_id)
INCLUDE (version_id, version_number, file_reference, sha, created_at);

-- Constraint: Each paper must have exactly one corresponding author
CREATE UNIQUE INDEX IF NOT EXISTS idx_paper_contributors_one_corresponding 
ON paper_contributors (paper_id) 
WHERE is_corresponding = true;

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_papers_updated_at
  BEFORE UPDATE ON papers
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_paper_contributors_updated_at
  BEFORE UPDATE ON paper_contributors
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Helper Functions
-- =============================================

-- Check if user is a contributor on a paper (used in RLS policies)
-- Uses SECURITY DEFINER to bypass RLS and prevent infinite recursion
CREATE OR REPLACE FUNCTION is_paper_contributor(p_paper_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.paper_contributors pc
    WHERE pc.paper_id = p_paper_id
    AND pc.user_id = (SELECT user_id FROM public.user_accounts WHERE auth_id = auth.uid())
  );
$$;

COMMENT ON FUNCTION is_paper_contributor(INTEGER) IS 'Checks if current user is a contributor on the given paper. Uses SECURITY DEFINER to bypass RLS and prevent infinite recursion.';

-- =============================================
-- Row Level Security Policies
-- =============================================

-- Enable RLS on papers
ALTER TABLE papers ENABLE ROW LEVEL SECURITY;

-- Users can read papers they uploaded, are contributors to, or that are associated with their activities
-- Note: Activity participant access will be extended in PR/JC migrations after permissions tables exist
CREATE POLICY papers_select_own_or_contributor_or_service ON papers
  FOR SELECT
  USING (
    uploaded_by = (SELECT auth_user_id()) OR
    (SELECT is_paper_contributor(paper_id)) OR
    (SELECT auth.role()) = 'service_role'
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

-- Users can read contributors for papers they have access to
CREATE POLICY paper_contributors_select_with_paper_access_or_service ON paper_contributors
  FOR SELECT
  USING (
    -- User is a contributor on this paper
    user_id = (SELECT auth_user_id()) OR
    -- User owns the paper
    EXISTS (
      SELECT 1 FROM public.papers p
      WHERE p.paper_id = paper_contributors.paper_id
      AND p.uploaded_by = (SELECT auth_user_id())
    ) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Users can insert contributors when creating their own paper
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
CREATE POLICY paper_contributors_update_corresponding_or_service ON paper_contributors
  FOR UPDATE
  USING (
    (user_id = (SELECT auth_user_id()) AND is_corresponding = true) OR
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

