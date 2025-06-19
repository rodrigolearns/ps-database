-- =============================================
-- 00000000000106_user_dashboard_views.sql
-- Expose user_papers_view & user_review_activities_view 
--   for your AuthoringPage and ReviewingPage
-- =============================================

-- 1) Build a view of EVERY paper + its co-authors JSONB + current PR state
DROP VIEW IF EXISTS public.user_papers_view;
CREATE OR REPLACE VIEW public.user_papers_view AS
SELECT
  p.*,
  authors.jsonb_agg      AS authors,
  pra.current_state      AS current_state,
  pra.activity_id        AS activity_id
FROM papers p
LEFT JOIN peer_review_activities pra
  ON pra.activity_uuid = p.activity_uuids[1]
LEFT JOIN LATERAL (
  SELECT jsonb_agg(
           jsonb_build_object(
             'name',               a.full_name,
             'affiliations',       a.affiliations,
             'email',              a.email,
             'orcid',              a.orcid,
             'psUsername',         ua.username,
             'userId',             a.ps_user_id,
             'author_order',       pa.author_order,
             'contribution_group', pa.contribution_group,
             'author_role',        pa.author_role
           ) ORDER BY pa.author_order
         ) AS jsonb_agg
  FROM paper_authors pa
  JOIN authors a            ON pa.author_id = a.author_id
  LEFT JOIN user_accounts ua ON a.ps_user_id = ua.user_id
  WHERE pa.paper_id = p.paper_id
) AS authors ON TRUE;
COMMENT ON VIEW public.user_papers_view IS
  'All papers with aggregated co-authors JSONB, plus their primary PR activity state & ID';

-- 2) Expose get_user_papers RPC to return exactly those rows the user created or co-authored
DROP FUNCTION IF EXISTS public.get_user_papers(INTEGER);
CREATE FUNCTION public.get_user_papers(p_user_id INTEGER)
  RETURNS SETOF public.user_papers_view
  LANGUAGE SQL STABLE SECURITY DEFINER AS $$
    SELECT *
      FROM public.user_papers_view up
     WHERE up.uploaded_by = p_user_id
        OR EXISTS (
             SELECT 1
               FROM jsonb_array_elements(up.authors) AS author(obj)
              WHERE (obj->>'userId')::INTEGER = p_user_id
           )
     ORDER BY up.updated_at DESC
  $$;
COMMENT ON FUNCTION public.get_user_papers IS
  'RPC for AuthoringPage: fetch all papers a user uploaded or co-authored';

-- 3) Build a view of every review activity the user is on, with paper info + status
DROP VIEW IF EXISTS public.user_review_activities;
CREATE OR REPLACE VIEW public.user_review_activities AS
SELECT
  rtm.user_id,
  rtm.activity_id,
  pra.activity_uuid,
  pra.current_state,
  pra.stage_deadline,
  p.paper_id,
  p.title         AS paper_title,
  p.created_at    AS paper_created_at,
  rtm.status      AS reviewer_status
FROM reviewer_team_members rtm
JOIN peer_review_activities pra
  ON pra.activity_id = rtm.activity_id
JOIN papers p
  ON p.paper_id = pra.paper_id
ORDER BY pra.stage_deadline ASC NULLS LAST;
COMMENT ON VIEW public.user_review_activities IS
  'All review teams you belong to, with the paper title, current PR stage, deadline, and your status';
