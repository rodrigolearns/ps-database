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
  is_peer_reviewed BOOLEAN DEFAULT false,
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
COMMENT ON COLUMN papers.paperstack_doi IS 'Digital Object Identifier assigned by PaperStacks';
COMMENT ON COLUMN papers.preprint_doi IS 'DOI for the preprint, if applicable';
COMMENT ON COLUMN papers.preprint_source IS 'Source of the preprint, if applicable';
COMMENT ON COLUMN papers.preprint_date IS 'Date the preprint was published, if applicable';
COMMENT ON COLUMN papers.license IS 'License under which the paper is published';
COMMENT ON COLUMN papers.storage_reference IS 'Reference to the paper file in storage';
COMMENT ON COLUMN papers.is_peer_reviewed IS 'Indicates if the paper has been peer reviewed';
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

-- Authors table (separate from user_accounts to handle non-registered authors)
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

COMMENT ON TABLE authors IS 'Authors of papers, may or may not be registered users';
COMMENT ON COLUMN authors.author_id IS 'Primary key for the author';
COMMENT ON COLUMN authors.full_name IS 'Full name of the author';
COMMENT ON COLUMN authors.email IS 'Email address of the author';
COMMENT ON COLUMN authors.orcid IS 'ORCID identifier for the author';
COMMENT ON COLUMN authors.affiliations IS 'Institutional affiliations of the author';
COMMENT ON COLUMN authors.user_id IS 'Foreign key to user_accounts if author is registered';
COMMENT ON COLUMN authors.created_at IS 'When the author record was created';
COMMENT ON COLUMN authors.updated_at IS 'When the author record was last updated';

-- Paper-author relationship table
CREATE TABLE IF NOT EXISTS paper_authors (
  paper_id INTEGER NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  author_id INTEGER NOT NULL REFERENCES authors(author_id) ON DELETE CASCADE,
  author_order INTEGER NOT NULL,
  is_corresponding BOOLEAN DEFAULT false,
  PRIMARY KEY (paper_id, author_id)
);

COMMENT ON TABLE paper_authors IS 'Relationship between papers and their authors';
COMMENT ON COLUMN paper_authors.paper_id IS 'Foreign key to papers';
COMMENT ON COLUMN paper_authors.author_id IS 'Foreign key to authors';
COMMENT ON COLUMN paper_authors.author_order IS 'Order of the author in the author list';
COMMENT ON COLUMN paper_authors.is_corresponding IS 'Whether this author is a corresponding author';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_papers_uploaded_by ON papers (uploaded_by);
CREATE INDEX IF NOT EXISTS idx_papers_created_at ON papers (created_at);
CREATE INDEX IF NOT EXISTS idx_papers_is_peer_reviewed ON papers (is_peer_reviewed);
CREATE INDEX IF NOT EXISTS idx_papers_activity_uuids ON papers USING GIN (activity_uuids);
CREATE INDEX IF NOT EXISTS idx_papers_embedding ON papers USING ivfflat (embedding_vector vector_cosine_ops) WITH (lists = 100);

CREATE INDEX IF NOT EXISTS idx_paper_versions_paper_id ON paper_versions (paper_id);
CREATE INDEX IF NOT EXISTS idx_paper_versions_created_at ON paper_versions (created_at);

CREATE INDEX IF NOT EXISTS idx_authors_user_id ON authors (user_id);
CREATE INDEX IF NOT EXISTS idx_authors_email ON authors (email);
CREATE INDEX IF NOT EXISTS idx_authors_orcid ON authors (orcid);

CREATE INDEX IF NOT EXISTS idx_paper_authors_paper_id ON paper_authors (paper_id);
CREATE INDEX IF NOT EXISTS idx_paper_authors_author_id ON paper_authors (author_id);
CREATE INDEX IF NOT EXISTS idx_paper_authors_order ON paper_authors (paper_id, author_order);

-- Triggers
CREATE TRIGGER update_papers_updated_at
  BEFORE UPDATE ON papers
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_authors_updated_at
  BEFORE UPDATE ON authors
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at(); 