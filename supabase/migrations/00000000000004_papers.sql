-- =============================================
-- 00000000000003_papers.sql
-- Migration for Papers Table
-- =============================================

CREATE TABLE IF NOT EXISTS papers (
  paper_id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  abstract TEXT NOT NULL,
  paperstack_doi TEXT, -- DOI assigned by PaperStacks
  preprint_doi TEXT, -- DOI for the preprint, if applicable
  preprint_source TEXT, -- Source of the preprint (e.g., arXiv, bioRxiv)
  preprint_date DATE, -- Date the preprint was published
  license TEXT, -- License under which the paper is published (e.g., CC BY 4.0)
  storage_reference TEXT, -- Reference to the main paper file in storage, expected path format: papers/{user_id}/{year}/{month}/{paper_id}/{filename}
  is_peer_reviewed BOOLEAN DEFAULT false,
  activity_uuids UUID[] DEFAULT '{}'::UUID[], -- Array of activity UUIDs this paper is associated with
  uploaded_by INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  visual_abstract_storage_reference TEXT, -- Reference to the visual abstract image in storage, expected path format: visual-abstracts/{user_id}/{year}/{month}/{paper_id}/{filename}
  visual_abstract_caption JSONB DEFAULT '{}'::jsonb, -- JSONB data including caption, credits, etc.
  cited_sources JSONB DEFAULT '{}'::jsonb,
  supplementary_materials JSONB DEFAULT '[]'::jsonb,
  funding_info JSONB DEFAULT '[]'::jsonb,
  data_availability_statement TEXT,
  data_availability_url JSONB DEFAULT '{}'::jsonb,
  embedding_vector vector(1536) NULL, -- Vector embedding for the paper content, initially NULL and updated by background processes
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON TABLE papers IS 'Academic papers submitted to the platform';
COMMENT ON COLUMN papers.paper_id IS 'Primary key for the paper';
COMMENT ON COLUMN papers.paperstack_doi IS 'Digital Object Identifier assigned by PaperStacks';
COMMENT ON COLUMN papers.preprint_doi IS 'DOI for the preprint, if applicable';
COMMENT ON COLUMN papers.preprint_source IS 'Source of the preprint, if applicable';
COMMENT ON COLUMN papers.preprint_date IS 'Date the preprint was published, if applicable';
COMMENT ON COLUMN papers.license IS 'License under which the paper is published';
COMMENT ON COLUMN papers.storage_reference IS 'Reference to the paper file in storage, expected path format: papers/{user_id}/{year}/{month}/{paper_id}/{filename}';
COMMENT ON COLUMN papers.is_peer_reviewed IS 'Indicates if the paper has been peer reviewed via a completed activity';
COMMENT ON COLUMN papers.activity_uuids IS 'Array of activity UUIDs this paper is associated with, supporting multiple activities per paper';
COMMENT ON COLUMN papers.uploaded_by IS 'Foreign key to user_accounts (integer user_id) for the user who uploaded the paper';
COMMENT ON COLUMN papers.visual_abstract_storage_reference IS 'Reference to the visual abstract image, expected path format: visual-abstracts/{user_id}/{year}/{month}/{paper_id}/{filename}';
COMMENT ON COLUMN papers.visual_abstract_caption IS 'JSONB data for the visual abstract including caption and metadata';
COMMENT ON COLUMN papers.cited_sources IS 'JSON of sources cited in the paper';
COMMENT ON COLUMN papers.supplementary_materials IS 'JSON array of supplementary materials (links, descriptions)';
COMMENT ON COLUMN papers.funding_info IS 'JSON array of funding information (funder, grant ID)';
COMMENT ON COLUMN papers.data_availability_statement IS 'Statement about the availability of data used in the paper';
COMMENT ON COLUMN papers.data_availability_url IS 'JSON with info (e.g., URL, repository) to access the data used in the paper';
COMMENT ON COLUMN papers.embedding_vector IS 'Vector embedding for the paper; used for similarity searches and recommendations, initially NULL and filled by background process';
COMMENT ON COLUMN papers.created_at IS 'Timestamp when the paper record was created';
COMMENT ON COLUMN papers.updated_at IS 'Timestamp when the paper record was last updated';

-- Function update_papers_updated_at removed, using generic set_updated_at
DROP TRIGGER IF EXISTS update_papers_updated_at_trigger ON papers;
CREATE TRIGGER update_papers_updated_at_trigger
BEFORE UPDATE ON papers
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_papers_uploaded_by ON papers (uploaded_by);
