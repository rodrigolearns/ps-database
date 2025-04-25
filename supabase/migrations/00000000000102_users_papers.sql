-- =============================================
-- 00000000000102_users_papers.sql
-- Defines internal get_user_papers function
-- =============================================

-- Internal helper function to get papers uploaded by or authored by a specific user
-- This version only returns the basic paper data and is used internally
CREATE OR REPLACE FUNCTION get_user_papers(p_user_id INTEGER)
RETURNS TABLE (
    paper_id        INTEGER,
    title           TEXT,
    abstract        TEXT,
    paperstack_doi  TEXT,
    preprint_doi    TEXT,
    preprint_source TEXT,
    preprint_date   DATE,
    license         TEXT,
    storage_reference TEXT,
    is_peer_reviewed BOOLEAN,
    activity_uuids  UUID[],
    uploaded_by     INTEGER,
    visual_abstract_storage_reference TEXT,
    visual_abstract_caption JSONB,
    cited_sources   JSONB,
    supplementary_materials JSONB,
    funding_info    JSONB,
    data_availability_statement TEXT,
    data_availability_url JSONB,
    embedding_vector vector(1536),
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ,
    author_names    TEXT[], -- Array of author full names in order
    current_state   TEXT -- Current state of the primary associated activity
) AS $$
BEGIN
  RETURN QUERY
  WITH relevant_papers AS (
    -- Select paper IDs where the user is the creator OR an author
    SELECT p_sub.paper_id
    FROM papers p_sub
    WHERE p_sub.uploaded_by = p_user_id
    OR EXISTS (
        SELECT 1 FROM paper_authors pa_link
        JOIN authors a_link ON pa_link.author_id = a_link.author_id
        WHERE pa_link.paper_id = p_sub.paper_id
        AND a_link.ps_user_id = p_user_id
    )
  )
  -- Select all details for the relevant papers and aggregate authors
  SELECT
    p.paper_id,
    p.title,
    p.abstract,
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
    array_agg(a.full_name ORDER BY pa.author_order) AS author_names,
    (SELECT pra.current_state::TEXT FROM peer_review_activities pra WHERE pra.activity_uuid = p.activity_uuids[1] LIMIT 1) AS current_state
  FROM papers p
  -- Join only the relevant papers identified in the CTE
  JOIN relevant_papers rp ON p.paper_id = rp.paper_id
  -- Left join authors to aggregate names
  LEFT JOIN paper_authors pa ON pa.paper_id = p.paper_id
  LEFT JOIN authors a         ON a.author_id = pa.author_id
  -- Group by paper to aggregate authors
  GROUP BY p.paper_id
  ORDER BY p.updated_at DESC;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION get_user_papers(INTEGER) IS
  'Internal helper function that returns papers uploaded by or authored by the given user.';
