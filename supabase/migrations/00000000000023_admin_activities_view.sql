-- =====================================================
-- Admin Activities View Migration
-- Creates optimized view and indexes for admin dashboard
-- =====================================================

-- Enable pg_trgm extension for fuzzy search
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Create materialized view for admin activities
CREATE MATERIALIZED VIEW admin_activities_view AS
SELECT 
  a.activity_id,
  a.activity_uuid,
  a.current_state,
  a.posted_at,
  a.created_at,
  
  -- Paper information
  p.title as paper_title,
  p.paper_id,
  
  -- Template information
  t.name as template_name,
  t.reviewer_count as template_reviewers,
  t.template_id,
  
  -- Corresponding author (registered user)
  ca.full_name as corresponding_author,
  ca.email as corresponding_author_email,
  ca.user_id as corresponding_author_id,
  
  -- External corresponding author (fallback)
  pc.external_name as external_corresponding_author,
  pc.external_email as external_corresponding_author_email,
  
  -- Author count
  (SELECT COUNT(*) FROM paper_contributors pc2 WHERE pc2.paper_id = p.paper_id) as total_authors,
  
  -- Reviewer information
  (SELECT COUNT(*) 
   FROM pr_activity_permissions pap 
   WHERE pap.activity_id = a.activity_id 
     AND pap.role = 'reviewer') as active_reviewers,
  (SELECT COUNT(*) 
   FROM pr_activity_permissions pap 
   WHERE pap.activity_id = a.activity_id 
     AND pap.role = 'reviewer') as total_reviewers,
  
  -- Stage timeline information
  (SELECT te.created_at 
   FROM pr_timeline_events te 
   WHERE te.activity_id = a.activity_id 
     AND te.event_type = 'state_transition' 
     AND te.metadata->>'to_state' = a.current_state::text
   ORDER BY te.created_at DESC 
   LIMIT 1) as current_stage_date,
   
  -- Fallback to activity creation if no stage transition found
  COALESCE(
    (SELECT te.created_at 
     FROM pr_timeline_events te 
     WHERE te.activity_id = a.activity_id 
       AND te.event_type = 'state_transition' 
       AND te.metadata->>'to_state' = a.current_state::text
     ORDER BY te.created_at DESC 
     LIMIT 1),
    a.created_at
  ) as stage_date,
  
  -- All participants for search (authors and reviewers)
  (SELECT string_agg(DISTINCT COALESCE(ua.full_name, ''), ' ')
   FROM pr_activity_permissions pap
   LEFT JOIN user_accounts ua ON pap.user_id = ua.user_id
   WHERE pap.activity_id = a.activity_id) as all_participants,
   
  (SELECT string_agg(DISTINCT COALESCE(ua.email, ''), ' ')
   FROM pr_activity_permissions pap
   LEFT JOIN user_accounts ua ON pap.user_id = ua.user_id
   WHERE pap.activity_id = a.activity_id) as all_participant_emails,
   
  -- Search text for full-text search
  p.title || ' ' ||
  COALESCE(ca.full_name, pc.external_name, '') || ' ' ||
  COALESCE(ca.email, pc.external_email, '') || ' ' ||
  COALESCE(
    (SELECT string_agg(DISTINCT COALESCE(ua.full_name, ''), ' ')
     FROM pr_activity_permissions pap
     LEFT JOIN user_accounts ua ON pap.user_id = ua.user_id
     WHERE pap.activity_id = a.activity_id), ''
  ) as search_text

FROM pr_activities a
JOIN papers p ON a.paper_id = p.paper_id
JOIN pr_templates t ON a.template_id = t.template_id
LEFT JOIN paper_contributors pc ON pc.paper_id = p.paper_id AND pc.is_corresponding = true
LEFT JOIN user_accounts ca ON pc.user_id = ca.user_id

ORDER BY a.posted_at DESC;

-- Create unique index for concurrent refresh
CREATE UNIQUE INDEX idx_admin_activities_view_activity_id 
ON admin_activities_view (activity_id);

-- Full-text search indexes
CREATE INDEX idx_admin_activities_search_text_gin 
ON admin_activities_view USING GIN(to_tsvector('english', search_text));

-- Trigram indexes for fuzzy search
CREATE INDEX idx_admin_activities_title_trgm 
ON admin_activities_view USING GIN(paper_title gin_trgm_ops);

CREATE INDEX idx_admin_activities_author_trgm 
ON admin_activities_view USING GIN(
  COALESCE(corresponding_author, external_corresponding_author, '') gin_trgm_ops
);

CREATE INDEX idx_admin_activities_participants_trgm 
ON admin_activities_view USING GIN(
  COALESCE(all_participants, '') gin_trgm_ops
);

-- Filter indexes
CREATE INDEX idx_admin_activities_template 
ON admin_activities_view (template_name);

CREATE INDEX idx_admin_activities_template_id 
ON admin_activities_view (template_id);

CREATE INDEX idx_admin_activities_stage 
ON admin_activities_view (current_state);

CREATE INDEX idx_admin_activities_posted 
ON admin_activities_view (posted_at DESC);

CREATE INDEX idx_admin_activities_stage_date 
ON admin_activities_view (stage_date DESC);

-- Composite indexes for common queries
CREATE INDEX idx_admin_activities_template_stage 
ON admin_activities_view (template_name, current_state);

CREATE INDEX idx_admin_activities_stage_posted 
ON admin_activities_view (current_state, posted_at DESC);

-- Function to refresh materialized view (existing)
CREATE OR REPLACE FUNCTION refresh_admin_activities_view()
RETURNS void AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY admin_activities_view;
  RAISE NOTICE 'Admin activities view refreshed at %', NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to check if view needs refresh (for background refresh)
CREATE OR REPLACE FUNCTION check_admin_view_staleness()
RETURNS TABLE(needs_refresh BOOLEAN, latest_activity TIMESTAMPTZ, view_count INTEGER) AS $$
DECLARE
  last_activity TIMESTAMPTZ;
  current_view_count INTEGER;
  actual_activity_count INTEGER;
BEGIN
  -- Get latest activity timestamp
  SELECT MAX(GREATEST(posted_at, updated_at, created_at)) INTO last_activity
  FROM pr_activities;
  
  -- Get current counts to detect new activities
  SELECT COUNT(*) INTO current_view_count FROM admin_activities_view;
  SELECT COUNT(*) INTO actual_activity_count FROM pr_activities;
  
  -- Return true if activity count mismatch (indicates new activities)
  RETURN QUERY SELECT 
    (actual_activity_count > current_view_count) as needs_refresh,
    last_activity,
    current_view_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function for manual refresh with detailed response
CREATE OR REPLACE FUNCTION refresh_admin_activities_view_manual()
RETURNS TABLE(success BOOLEAN, message TEXT, refreshed_at TIMESTAMPTZ, activities_count INTEGER) AS $$
DECLARE
  activity_count INTEGER;
BEGIN
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY admin_activities_view;
    
    -- Get count after refresh
    SELECT COUNT(*) INTO activity_count FROM admin_activities_view;
    
    RETURN QUERY SELECT 
      TRUE as success, 
      format('Admin activities view refreshed successfully. Found %s activities.', activity_count)::TEXT as message,
      NOW() as refreshed_at,
      activity_count as activities_count;
      
  EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 
      FALSE as success, 
      SQLERRM::TEXT as message, 
      NULL::TIMESTAMPTZ as refreshed_at,
      0 as activities_count;
  END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant permissions
GRANT SELECT ON admin_activities_view TO authenticated;
GRANT EXECUTE ON FUNCTION refresh_admin_activities_view() TO service_role;
GRANT EXECUTE ON FUNCTION check_admin_view_staleness() TO authenticated;
GRANT EXECUTE ON FUNCTION refresh_admin_activities_view_manual() TO authenticated;

-- Initial refresh
SELECT refresh_admin_activities_view();

COMMENT ON MATERIALIZED VIEW admin_activities_view IS 'Optimized view for admin dashboard activities with search and filter capabilities';
COMMENT ON FUNCTION refresh_admin_activities_view() IS 'Function to refresh the admin activities materialized view';
