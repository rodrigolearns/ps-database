-- =============================================
-- 00000000000104_user_reviews.sql
-- Exposes get_user_papers as RPC and creates user_review_activities view
-- =============================================

-- 1) Expose get_user_papers as an RPC in the public schema
DROP VIEW IF EXISTS public.user_papers_view;
CREATE OR REPLACE VIEW public.user_papers_view AS
SELECT
  p.*,
  authors.jsonb_agg AS authors,
  pra.current_state,
  pra.activity_id
FROM papers p
LEFT JOIN peer_review_activities pra
  ON pra.activity_uuid = p.activity_uuids[1]
LEFT JOIN LATERAL (
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
  ) AS jsonb_agg
  FROM paper_authors pa
  JOIN authors a ON pa.author_id = a.author_id
  LEFT JOIN user_accounts ua ON a.ps_user_id = ua.user_id
  WHERE pa.paper_id = p.paper_id
) AS authors ON TRUE;

COMMENT ON VIEW public.user_papers_view IS
  'View combining Paper details with aggregated author information (JSONB array) and the current state and ID of the primary peer review activity.';

-- 2) Expose get_user_papers as SETOF that view
-- First drop the existing function - this is the key fix!
DROP FUNCTION IF EXISTS public.get_user_papers(INTEGER);

-- Now recreate with new return type
CREATE FUNCTION public.get_user_papers(p_user_id INTEGER)
RETURNS SETOF public.user_papers_view
LANGUAGE SQL STABLE SECURITY DEFINER AS $$
  SELECT *
    FROM public.user_papers_view up
   WHERE up.uploaded_by = p_user_id
      OR EXISTS (
         SELECT 1
           FROM jsonb_array_elements(up.authors) AS a(obj)
          WHERE (obj->>'userId')::INT = p_user_id
      )
  ORDER BY up.updated_at DESC;
$$;

COMMENT ON FUNCTION public.get_user_papers IS
  'RPC for client to fetch all papers the given user created or co-authored';

-- 3) Create user_review_activities view
DROP VIEW IF EXISTS public.user_review_activities;
CREATE VIEW public.user_review_activities AS
SELECT
  rtm.*,
  pra.activity_uuid,
  pra.current_state,
  pra.stage_deadline,
  p.paper_id,
  p.title AS paper_title,
  p.created_at AS paper_created_at
FROM reviewer_team_members rtm
JOIN peer_review_activities pra ON pra.activity_id = rtm.activity_id
JOIN papers p ON p.paper_id = pra.paper_id
ORDER BY pra.stage_deadline ASC NULLS LAST;

COMMENT ON VIEW public.user_review_activities IS
  'All review activities with paper info and reviewer status';
