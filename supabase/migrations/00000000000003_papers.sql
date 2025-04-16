-- =============================================
-- 00000000000003_papers.sql
-- Migration for Papers Table
-- =============================================

CREATE TABLE IF NOT EXISTS "Papers" (
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
  activity_id TEXT,
  activity_type TEXT,
  uploaded_by INTEGER NOT NULL REFERENCES "User_Accounts"(user_id) ON DELETE CASCADE,
  visual_abstract TEXT,
  visual_abstract_caption TEXT,
  cited_sources JSONB DEFAULT '{}'::jsonb,
  supplementary_materials JSONB DEFAULT '[]'::jsonb,
  funding_info JSONB DEFAULT '[]'::jsonb,
  data_availability_statement TEXT,
  data_availability_url JSONB DEFAULT '{}'::jsonb,
  embedding_vector FLOAT8[] DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON TABLE "Papers" IS 'Academic papers submitted to the platform';
COMMENT ON COLUMN "Papers".paper_id IS 'Primary key for the paper';
COMMENT ON COLUMN "Papers".paperstack_doi IS 'Digital Object Identifier assigned by PaperStacks';
COMMENT ON COLUMN "Papers".preprint_doi IS 'DOI for the preprint, if applicable';
COMMENT ON COLUMN "Papers".preprint_source IS 'Source of the preprint, if applicable';
COMMENT ON COLUMN "Papers".preprint_date IS 'Date the preprint was published, if applicable';
COMMENT ON COLUMN "Papers".license IS 'License under which the paper is published';
COMMENT ON COLUMN "Papers".storage_reference IS 'Reference to the paper file in storage';
COMMENT ON COLUMN "Papers".is_peer_reviewed IS 'Indicates if the paper has been peer reviewed via a completed activity';
COMMENT ON COLUMN "Papers".activity_id IS 'ID of the associated peer review activity';
COMMENT ON COLUMN "Papers".activity_type IS 'Type of the associated activity';
COMMENT ON COLUMN "Papers".uploaded_by IS 'Foreign key to User_Accounts for the user who uploaded the paper';
COMMENT ON COLUMN "Papers".visual_abstract IS 'Path to visual abstract image';
COMMENT ON COLUMN "Papers".visual_abstract_caption IS 'Caption for the visual abstract image';
COMMENT ON COLUMN "Papers".cited_sources IS 'JSON of sources cited in the paper';
COMMENT ON COLUMN "Papers".supplementary_materials IS 'JSON array of supplementary materials';
COMMENT ON COLUMN "Papers".funding_info IS 'JSON array of funding information';
COMMENT ON COLUMN "Papers".data_availability_statement IS 'Statement about the availability of data used in the paper';
COMMENT ON COLUMN "Papers".data_availability_url IS 'JSON with info to access the data used in the paper';
COMMENT ON COLUMN "Papers".embedding_vector IS 'Vector embedding for the paper; initially empty and updated by background processes';
COMMENT ON COLUMN "Papers".created_at IS 'When the paper was created';
COMMENT ON COLUMN "Papers".updated_at IS 'When the paper was last updated';

CREATE OR REPLACE FUNCTION update_papers_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS update_papers_updated_at_trigger ON "Papers";
CREATE TRIGGER update_papers_updated_at_trigger
BEFORE UPDATE ON "Papers"
FOR EACH ROW
EXECUTE FUNCTION update_papers_updated_at();
