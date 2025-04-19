-- =============================================
-- 00000000000024_user_papers_view.sql
-- View for fetching papers associated with a user (creator or author)
-- =============================================

-- Drop the old function first if it exists
DROP FUNCTION IF EXISTS get_user_papers(INTEGER);

-- Create the view
CREATE OR REPLACE VIEW "User_Papers_View" AS
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
    -- Use LEFT JOIN to get current_state from the first associated activity
    pra.current_state::TEXT AS current_state
FROM
    "Papers" p
LEFT JOIN "Peer_Review_Activities" pra 
    -- Join condition: activity_uuids array is not null, not empty, and first element matches pra.activity_uuid
    ON p.activity_uuids IS NOT NULL 
    AND array_length(p.activity_uuids, 1) > 0 
    AND pra.activity_uuid = p.activity_uuids[1];

COMMENT ON VIEW "User_Papers_View" IS 'Provides a consolidated view of papers and the current state of their primary associated peer review activity.'; 