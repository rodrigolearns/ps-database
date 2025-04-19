-- =============================================
-- 00000000000003_papers.sql
-- Migration for Papers Table
-- =============================================

CREATE TABLE IF NOT EXISTS "Papers" (
  paper_id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  abstract TEXT NOT NULL,
  authors JSONB DEFAULT '{}'::jsonb, -- JSONB array of authors with name, affiliation, email, ORCID, and importantly ps_username to map to PaperStacks user accounts
  paperstack_doi TEXT, -- DOI assigned by PaperStacks
  preprint_doi TEXT, -- DOI for the preprint, if applicable
  preprint_source TEXT, -- Source of the preprint (e.g., arXiv, bioRxiv)
  preprint_date DATE, -- Date the preprint was published
  license TEXT, -- License under which the paper is published (e.g., CC BY 4.0)
  storage_reference TEXT, -- Reference to the main paper file in storage, expected path format: papers/{user_id}/{year}/{month}/{paper_id}/{filename}
  is_peer_reviewed BOOLEAN DEFAULT false,
  activity_uuids UUID[] DEFAULT '{}'::UUID[], -- Array of activity UUIDs this paper is associated with
  uploaded_by INTEGER NOT NULL REFERENCES "User_Accounts"(user_id) ON DELETE CASCADE,
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
COMMENT ON TABLE "Papers" IS 'Academic papers submitted to the platform';
COMMENT ON COLUMN "Papers".paper_id IS 'Primary key for the paper';
COMMENT ON COLUMN "Papers".authors IS 'JSONB array of authors containing name, affiliation, email, ORCID, and ps_username field to map to PaperStacks user accounts';
COMMENT ON COLUMN "Papers".paperstack_doi IS 'Digital Object Identifier assigned by PaperStacks';
COMMENT ON COLUMN "Papers".preprint_doi IS 'DOI for the preprint, if applicable';
COMMENT ON COLUMN "Papers".preprint_source IS 'Source of the preprint, if applicable';
COMMENT ON COLUMN "Papers".preprint_date IS 'Date the preprint was published, if applicable';
COMMENT ON COLUMN "Papers".license IS 'License under which the paper is published';
COMMENT ON COLUMN "Papers".storage_reference IS 'Reference to the paper file in storage, expected path format: papers/{user_id}/{year}/{month}/{paper_id}/{filename}';
COMMENT ON COLUMN "Papers".is_peer_reviewed IS 'Indicates if the paper has been peer reviewed via a completed activity';
COMMENT ON COLUMN "Papers".activity_uuids IS 'Array of activity UUIDs this paper is associated with, supporting multiple activities per paper';
COMMENT ON COLUMN "Papers".uploaded_by IS 'Foreign key to User_Accounts (integer user_id) for the user who uploaded the paper';
COMMENT ON COLUMN "Papers".visual_abstract_storage_reference IS 'Reference to the visual abstract image, expected path format: visual-abstracts/{user_id}/{year}/{month}/{paper_id}/{filename}';
COMMENT ON COLUMN "Papers".visual_abstract_caption IS 'JSONB data for the visual abstract including caption and metadata';
COMMENT ON COLUMN "Papers".cited_sources IS 'JSON of sources cited in the paper';
COMMENT ON COLUMN "Papers".supplementary_materials IS 'JSON array of supplementary materials (links, descriptions)';
COMMENT ON COLUMN "Papers".funding_info IS 'JSON array of funding information (funder, grant ID)';
COMMENT ON COLUMN "Papers".data_availability_statement IS 'Statement about the availability of data used in the paper';
COMMENT ON COLUMN "Papers".data_availability_url IS 'JSON with info (e.g., URL, repository) to access the data used in the paper';
COMMENT ON COLUMN "Papers".embedding_vector IS 'Vector embedding for the paper; used for similarity searches and recommendations, initially NULL and filled by background process';
COMMENT ON COLUMN "Papers".created_at IS 'Timestamp when the paper record was created';
COMMENT ON COLUMN "Papers".updated_at IS 'Timestamp when the paper record was last updated';

-- Function and Trigger to update updated_at timestamp on row update
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

-- ==============================================
-- Function to get all papers associated with a user (creator or author)
-- ==============================================
CREATE OR REPLACE FUNCTION get_user_papers(p_user_id INTEGER)
RETURNS TABLE (
    -- Explicitly list all columns from Papers to ensure stable return type
    paper_id INTEGER,
    title TEXT,
    abstract TEXT,
    authors JSONB,
    paperstack_doi TEXT,
    preprint_doi TEXT,
    preprint_source TEXT,
    preprint_date DATE,
    license TEXT,
    storage_reference TEXT,
    is_peer_reviewed BOOLEAN,
    activity_uuids UUID[],
    uploaded_by INTEGER,
    visual_abstract_storage_reference TEXT,
    visual_abstract_caption JSONB,
    cited_sources JSONB,
    supplementary_materials JSONB,
    funding_info JSONB,
    data_availability_statement TEXT,
    data_availability_url JSONB,
    embedding_vector vector(1536),
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    -- Add the activity state
    current_state TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.paper_id,
        p.title,
        p.abstract,
        p.authors,
        p.paperstack_doi,
        p.preprint_doi,
        p.preprint_source,
        p.preprint_date,
        p.license,
        p.storage_reference,
        p.is_peer_reviewed,
        p.activity_uuids,
        p.uploaded_by,
        p.visual_abstract_storage_reference,
        p.visual_abstract_caption,
        p.cited_sources,
        p.supplementary_materials,
        p.funding_info,
        p.data_availability_statement,
        p.data_availability_url,
        p.embedding_vector,
        p.created_at,
        p.updated_at,
        -- Fetch current_state from the activity linked by the first UUID, if available
        (SELECT pra.current_state::TEXT FROM "Peer_Review_Activities" pra WHERE pra.activity_uuid = p.activity_uuids[1] LIMIT 1)
    FROM "Papers" p
    WHERE
        p.uploaded_by = p_user_id
        OR (
            p.authors IS NOT NULL AND
            jsonb_path_exists(p.authors, '$[*] ? (@.userId == $userId)', jsonb_build_object('userId', p_user_id))
           )
    ORDER BY
        p.updated_at DESC;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION get_user_papers(INTEGER) IS 'Returns all papers where the user is either the creator (uploaded_by) or listed as a co-author (authors JSONB contains userId), along with the current state of the associated activity.';

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_papers_uploaded_by ON "Papers" (uploaded_by);
-- GIN index for querying the authors JSONB array
CREATE INDEX IF NOT EXISTS idx_papers_authors_gin ON "Papers" USING GIN (authors jsonb_path_ops);
