-- =============================================
-- 00000000000105_users_papers.sql
-- Defines get_user_papers function and User_Papers_View
-- =============================================

-- Helper function to get papers uploaded by or authored by a specific user
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
    FROM "Papers" p_sub
    WHERE p_sub.uploaded_by = p_user_id
    OR EXISTS (
        SELECT 1 FROM "Paper_Authors" pa_link
        JOIN "Authors" a_link ON pa_link.author_id = a_link.author_id
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
    (SELECT pra.current_state::TEXT FROM "Peer_Review_Activities" pra WHERE pra.activity_uuid = p.activity_uuids[1] LIMIT 1) AS current_state
  FROM "Papers" p
  -- Join only the relevant papers identified in the CTE
  JOIN relevant_papers rp ON p.paper_id = rp.paper_id
  -- Left join authors to aggregate names
  LEFT JOIN "Paper_Authors" pa ON pa.paper_id = p.paper_id
  LEFT JOIN "Authors" a         ON a.author_id = pa.author_id
  -- Group by paper to aggregate authors
  GROUP BY p.paper_id
  ORDER BY p.updated_at DESC;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION get_user_papers(INTEGER) IS
  'Returns papers uploaded by or authored by the given user, with ordered author names and current activity state.';

-- =============================================
-- CREATE VIEW User_Papers_View
-- View combining Papers with Authors and current activity state
-- =============================================

DROP VIEW IF EXISTS public."User_Papers_View";

-- Create the View with correct column references and necessary joins
CREATE OR REPLACE VIEW public."User_Papers_View" AS
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
    -- Aggregate author details into a JSONB array
    COALESCE(
        (
            SELECT jsonb_agg(
                       jsonb_build_object(
                           'name', a.full_name,
                           'affiliations', a.affiliations,
                           'email', a.email,
                           'orcid', a.orcid,
                           'psUsername', ua.username,
                           'userId', a.ps_user_id,
                           'author_order', pa.author_order,
                           'contribution_group', pa.contribution_group,
                           'author_role', pa.author_role
                       ) ORDER BY pa.author_order
                   )
            FROM "Paper_Authors" pa
            JOIN "Authors" a ON pa.author_id = a.author_id
            LEFT JOIN "User_Accounts" ua ON a.ps_user_id = ua.user_id
            WHERE pa.paper_id = p.paper_id
        ),
        '[]'::jsonb
    ) AS authors,
    -- Get the current state and ID from the primary activity (first in array)
    pra.current_state::TEXT AS current_state,
    pra.activity_id -- Added activity_id
FROM "Papers" p
-- Left join to get primary activity details using the first UUID
LEFT JOIN "Peer_Review_Activities" pra ON pra.activity_uuid = p.activity_uuids[1];

COMMENT ON VIEW public."User_Papers_View" IS
  'View combining Paper details with aggregated author information (JSONB array) and the current state and ID of the primary peer review activity.'; 