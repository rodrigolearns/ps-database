-- =============================================
-- 00000000000050_notifications.sql
-- Platform Feature: User Notifications
-- =============================================
-- Cross-activity notification system

-- =============================================
-- User Notifications Table
-- =============================================
CREATE TABLE IF NOT EXISTS user_notifications (
  notification_id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  
  -- Polymorphic activity reference
  related_activity_id INTEGER,  -- Could reference pr_activities or jc_activities
  related_activity_type TEXT,  -- 'pr-activity', 'jc-activity', etc.
  
  -- Notification content
  notification_type TEXT NOT NULL,
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  metadata JSONB DEFAULT '{}',
  
  -- Status
  is_read BOOLEAN DEFAULT false,
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE user_notifications IS 'In-app notifications for users';
COMMENT ON COLUMN user_notifications.notification_id IS 'Primary key';
COMMENT ON COLUMN user_notifications.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN user_notifications.related_activity_id IS 'Related activity ID (polymorphic)';
COMMENT ON COLUMN user_notifications.related_activity_type IS 'Which activity type table to reference';
COMMENT ON COLUMN user_notifications.notification_type IS 'Notification category/type';
COMMENT ON COLUMN user_notifications.title IS 'Short notification title';
COMMENT ON COLUMN user_notifications.message IS 'Detailed message';
COMMENT ON COLUMN user_notifications.metadata IS 'Additional data (JSONB)';
COMMENT ON COLUMN user_notifications.is_read IS 'Whether user has read this';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_user_notifications_user ON user_notifications (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_user_notifications_unread ON user_notifications (user_id, is_read, created_at DESC) WHERE is_read = false;
CREATE INDEX IF NOT EXISTS idx_user_notifications_type ON user_notifications (notification_type);
CREATE INDEX IF NOT EXISTS idx_user_notifications_activity ON user_notifications (related_activity_type, related_activity_id) WHERE related_activity_id IS NOT NULL;

-- =============================================
-- Helper Functions
-- =============================================

-- Create a user notification
CREATE OR REPLACE FUNCTION create_user_notification(
  p_user_id INTEGER,
  p_activity_id INTEGER,
  p_notification_type TEXT,
  p_title TEXT,
  p_message TEXT,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS INTEGER AS $$
DECLARE
  v_notification_id INTEGER;
  v_activity_type TEXT;
BEGIN
  -- Determine activity type based on notification type
  IF p_notification_type LIKE 'jc_%' OR p_notification_type = 'journal_club_invitation' THEN
    v_activity_type := 'jc-activity';
  ELSIF p_notification_type LIKE 'pr_%' OR p_notification_type IN ('reviewer_invited', 'reviewer_joined', 'review_received') THEN
    v_activity_type := 'pr-activity';
  ELSE
    v_activity_type := NULL;
  END IF;

  INSERT INTO user_notifications (
    user_id,
    related_activity_id,
    related_activity_type,
    notification_type,
    title,
    message,
    metadata,
    is_read,
    created_at
  )
  VALUES (
    p_user_id,
    p_activity_id,
    v_activity_type,
    p_notification_type,
    p_title,
    p_message,
    p_metadata,
    false,
    NOW()
  )
  RETURNING notification_id INTO v_notification_id;

  RETURN v_notification_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Mark notifications as read
CREATE OR REPLACE FUNCTION mark_notifications_read(
  p_user_id INTEGER,
  p_notification_ids INTEGER[] DEFAULT NULL
)
RETURNS INTEGER AS $$
DECLARE
  v_updated_count INTEGER;
BEGIN
  IF p_notification_ids IS NULL THEN
    -- Mark all unread as read
    UPDATE user_notifications
    SET is_read = true
    WHERE user_id = p_user_id AND is_read = false;
  ELSE
    -- Mark specific notifications
    UPDATE user_notifications
    SET is_read = true
    WHERE user_id = p_user_id 
      AND notification_id = ANY(p_notification_ids)
      AND is_read = false;
  END IF;
  
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Get notification summary
CREATE OR REPLACE FUNCTION get_user_notification_summary(p_user_id INTEGER)
RETURNS TABLE (
  total_count BIGINT,
  unread_count BIGINT,
  latest_notification_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COUNT(*) as total_count,
    COUNT(*) FILTER (WHERE is_read = false) as unread_count,
    MAX(created_at) as latest_notification_at
  FROM user_notifications
  WHERE user_id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION create_user_notification TO authenticated;
GRANT EXECUTE ON FUNCTION mark_notifications_read TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_notification_summary TO authenticated;

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE user_notifications ENABLE ROW LEVEL SECURITY;

-- Users see own notifications
CREATE POLICY user_notifications_select_own ON user_notifications
  FOR SELECT
  USING (user_id = (SELECT auth_user_id()) OR (SELECT auth.role()) = 'service_role');

-- Users can update own notifications (mark as read)
CREATE POLICY user_notifications_update_own ON user_notifications
  FOR UPDATE
  USING (user_id = (SELECT auth_user_id()) OR (SELECT auth.role()) = 'service_role');

-- Only service role can insert (via notification services)
CREATE POLICY user_notifications_insert_service_role_only ON user_notifications
  FOR INSERT
  WITH CHECK ((SELECT auth.role()) = 'service_role');

