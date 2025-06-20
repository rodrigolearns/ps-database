-- =============================================
-- 00000000000011_user_dashboard.sql
-- User Dashboard Views and Functions
-- Adapted from backup_migrations/00000000000104_user_dashboard_views.sql
-- Updated to use simplified naming: pr_activities, pr_reviewer_teams
-- =============================================

-- Simplified materialized view for better performance
DROP MATERIALIZED VIEW IF EXISTS public.user_paper_summary;
CREATE MATERIALIZED VIEW public.user_paper_summary AS
SELECT 
  p.paper_id,
  p.title,
  p.abstract,
  p.uploaded_by,
  p.created_at,
  p.updated_at,
  -- Author summary using new simplified structure
  string_agg(
    CASE 
      WHEN pc.user_id IS NOT NULL THEN 
        COALESCE(ua.full_name, 'Unknown User')
      ELSE 
        pc.external_name
    END, 
    ', ' ORDER BY pc.contributor_order
  ) as author_names,
  COUNT(pc.contributor_id) as author_count,
  bool_or(pc.is_corresponding) as has_corresponding_author,
  -- Get corresponding author info
  MAX(CASE WHEN pc.is_corresponding THEN 
    CASE WHEN pc.user_id IS NOT NULL THEN ua.user_id ELSE NULL END
  END) as corresponding_user_id,
  MAX(CASE WHEN pc.is_corresponding THEN 
    CASE WHEN pc.user_id IS NOT NULL THEN ua.username ELSE pc.external_email END
  END) as corresponding_author_contact,
  -- PR activity info
  pra.current_state,
  pra.activity_id,
  pra.activity_uuid
FROM papers p
LEFT JOIN paper_contributors pc ON pc.paper_id = p.paper_id
LEFT JOIN user_accounts ua ON ua.user_id = pc.user_id
LEFT JOIN pr_activities pra ON pra.paper_id = p.paper_id
GROUP BY p.paper_id, p.title, p.abstract, p.uploaded_by, p.created_at, p.updated_at,
         pra.current_state, pra.activity_id, pra.activity_uuid;

-- Create unique index for concurrent refresh
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_paper_summary_paper_id 
  ON user_paper_summary (paper_id);

COMMENT ON MATERIALIZED VIEW public.user_paper_summary IS
  'Optimized summary of papers with author info and PR state - refreshed periodically';

-- Fallback view using legacy structure for backward compatibility
DROP VIEW IF EXISTS public.user_papers_view_legacy;
CREATE OR REPLACE VIEW public.user_papers_view_legacy AS
SELECT
  p.*,
  authors.jsonb_agg      AS authors,
  pra.current_state      AS current_state,
  pra.activity_id        AS activity_id
FROM papers p
LEFT JOIN pr_activities pra
  ON pra.activity_uuid = p.activity_uuids[1]
  LEFT JOIN LATERAL (
  SELECT jsonb_agg(
           jsonb_build_object(
             'name',               a.full_name,
             'affiliations',       a.affiliations,
             'email',              a.email,
             'orcid',              a.orcid,
             'psUsername',         ua.username,
             'userId',             a.user_id,
             'author_order',       pa.author_order,
             'is_corresponding',   pa.is_corresponding,
             'contribution_symbols', pa.contribution_symbols
           ) ORDER BY pa.author_order
         ) AS jsonb_agg
  FROM paper_authors pa
  JOIN authors a            ON pa.author_id = a.author_id
  LEFT JOIN user_accounts ua ON a.user_id = ua.user_id
  WHERE pa.paper_id = p.paper_id
) AS authors ON TRUE;

-- Efficient function using new structure
DROP FUNCTION IF EXISTS public.get_user_papers(INTEGER);
CREATE FUNCTION public.get_user_papers(p_user_id INTEGER)
  RETURNS TABLE(
    paper_id INTEGER,
    title TEXT,
    abstract TEXT,
    author_names TEXT,
    author_count BIGINT,
    is_corresponding BOOLEAN,
    current_state activity_state,
    activity_id INTEGER,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
  )
  LANGUAGE SQL STABLE SECURITY DEFINER AS $$
    SELECT 
      ups.paper_id,
      ups.title,
      ups.abstract,
      ups.author_names,
      ups.author_count,
      (ups.corresponding_user_id = p_user_id) as is_corresponding,
      ups.current_state,
      ups.activity_id,
      ups.created_at,
      ups.updated_at
    FROM user_paper_summary ups
    WHERE ups.uploaded_by = p_user_id
       OR ups.corresponding_user_id = p_user_id
       OR EXISTS (
         SELECT 1 FROM paper_contributors pc 
         WHERE pc.paper_id = ups.paper_id 
         AND pc.user_id = p_user_id
       )
    ORDER BY ups.updated_at DESC
  $$;

-- Function to refresh the materialized view
CREATE OR REPLACE FUNCTION refresh_user_paper_summary()
RETURNS void AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY user_paper_summary;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_user_papers IS
  'Optimized RPC: fetch all papers a user uploaded or contributed to';
COMMENT ON FUNCTION refresh_user_paper_summary IS
  'Refresh the materialized view for paper summaries';

-- 3) Build a view of every review activity the user is on, with paper info + status
DROP VIEW IF EXISTS public.user_review_activities;
CREATE OR REPLACE VIEW public.user_review_activities AS
SELECT
  rt.user_id,
  rt.activity_id,
  pra.activity_uuid,
  pra.current_state,
  pra.stage_deadline,
  p.paper_id,
  p.title         AS paper_title,
  p.created_at    AS paper_created_at,
  rt.status       AS reviewer_status
FROM pr_reviewer_teams rt
JOIN pr_activities pra
  ON pra.activity_id = rt.activity_id
JOIN papers p
  ON p.paper_id = pra.paper_id
ORDER BY pra.stage_deadline ASC NULLS LAST;

COMMENT ON VIEW public.user_review_activities IS
  'All review teams you belong to, with the paper title, current PR stage, deadline, and your status'; 