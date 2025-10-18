-- =============================================
-- 00000000000070_admin_views.sql
-- Admin & Monitoring: Dashboard Views and Analytics
-- =============================================
-- Cross-activity admin views for monitoring and analytics

-- =============================================
-- Admin Activity Overview View
-- =============================================
-- Combines PR and JC activities for admin dashboard
CREATE OR REPLACE VIEW admin_all_activities AS
SELECT 
  'pr-activity'::text as activity_type,
  pa.activity_id,
  pa.activity_uuid,
  pa.paper_id,
  p.title as paper_title,
  pa.creator_id,
  ua.username as creator_username,
  pa.posted_at as created_at,
  pa.completed_at,
  ass.current_stage_key,
  ass.stage_deadline,
  pa.funding_amount,
  pa.escrow_balance,
  pt.name as template_name,
  (SELECT COUNT(*) FROM pr_reviewers WHERE activity_id = pa.activity_id AND status IN ('joined', 'locked_in')) as reviewer_count
FROM pr_activities pa
JOIN papers p ON pa.paper_id = p.paper_id
LEFT JOIN user_accounts ua ON pa.creator_id = ua.user_id
LEFT JOIN pr_templates pt ON pa.template_id = pt.template_id
LEFT JOIN activity_stage_state ass ON ass.activity_id = pa.activity_id AND ass.activity_type = 'pr-activity'

UNION ALL

SELECT
  'jc-activity'::text as activity_type,
  jca.activity_id,
  jca.activity_uuid,
  jca.paper_id,
  p.title as paper_title,
  jca.creator_id,
  ua.username as creator_username,
  jca.created_at,
  jca.completed_at,
  ass.current_stage_key,
  ass.stage_deadline,
  NULL::integer as funding_amount,
  NULL::integer as escrow_balance,
  NULL::text as template_name,
  (SELECT COUNT(*) FROM jc_reviewers WHERE activity_id = jca.activity_id) as reviewer_count
FROM jc_activities jca
JOIN papers p ON jca.paper_id = p.paper_id
LEFT JOIN user_accounts ua ON jca.creator_id = ua.user_id
LEFT JOIN activity_stage_state ass ON ass.activity_id = jca.activity_id AND ass.activity_type = 'jc-activity';

COMMENT ON VIEW admin_all_activities IS 'Unified view of all activities for admin dashboard';

-- =============================================
-- User Dashboard View
-- =============================================
-- User activity summary for dashboard
CREATE OR REPLACE VIEW user_activity_summary AS
SELECT
  ua.user_id,
  ua.username,
  ua.full_name,
  -- PR activities created
  (SELECT COUNT(*) FROM pr_activities WHERE creator_id = ua.user_id) as pr_activities_created,
  -- PR activities as reviewer
  (SELECT COUNT(DISTINCT activity_id) FROM pr_reviewers WHERE user_id = ua.user_id) as pr_activities_as_reviewer,
  -- JC activities created
  (SELECT COUNT(*) FROM jc_activities WHERE creator_id = ua.user_id) as jc_activities_created,
  -- JC activities as reviewer
  (SELECT COUNT(DISTINCT activity_id) FROM jc_reviewers WHERE user_id = ua.user_id) as jc_activities_as_reviewer,
  -- Wallet balance
  wb.balance as wallet_balance
FROM user_accounts ua
LEFT JOIN wallet_balances wb ON ua.user_id = wb.user_id;

COMMENT ON VIEW user_activity_summary IS 'User activity summary for dashboard';

-- =============================================
-- Grant Permissions
-- =============================================
GRANT SELECT ON admin_all_activities TO authenticated;
GRANT SELECT ON user_activity_summary TO authenticated;

