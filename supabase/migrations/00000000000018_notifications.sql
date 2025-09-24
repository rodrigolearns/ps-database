-- =============================================
-- 00000000000017_notifications.sql
-- Notification System for PR Activities
-- =============================================

-- User notifications table
CREATE TABLE IF NOT EXISTS user_notifications (
  notification_id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  activity_id INTEGER REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  notification_type TEXT NOT NULL CHECK (notification_type IN (
    'state_transition',
    'deadline_missed', 
    'review_submitted',
    'author_response_submitted',
    'reviewer_joined',
    'reviewer_removed',
    'awards_distributed',
    'activity_published'
  )),
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  metadata JSONB DEFAULT '{}',
  is_read BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE user_notifications IS 'In-app notifications for users about PR activity events';
COMMENT ON COLUMN user_notifications.notification_id IS 'Primary key for the notification';
COMMENT ON COLUMN user_notifications.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN user_notifications.activity_id IS 'Foreign key to pr_activities (nullable for system notifications)';
COMMENT ON COLUMN user_notifications.notification_type IS 'Type of notification for categorization';
COMMENT ON COLUMN user_notifications.title IS 'Short notification title';
COMMENT ON COLUMN user_notifications.message IS 'Detailed notification message';
COMMENT ON COLUMN user_notifications.metadata IS 'Additional notification data (JSON)';
COMMENT ON COLUMN user_notifications.is_read IS 'Whether the user has read this notification';
COMMENT ON COLUMN user_notifications.created_at IS 'When the notification was created';

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_user_notifications_user_id ON user_notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_user_notifications_created_at ON user_notifications(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_user_notifications_is_read ON user_notifications(is_read);
CREATE INDEX IF NOT EXISTS idx_user_notifications_activity_id ON user_notifications(activity_id);
CREATE INDEX IF NOT EXISTS idx_user_notifications_type ON user_notifications(notification_type);

-- Composite index for common queries
CREATE INDEX IF NOT EXISTS idx_user_notifications_user_unread ON user_notifications(user_id, is_read, created_at DESC);

-- Function to create notification for a single user
CREATE OR REPLACE FUNCTION create_user_notification(
  p_user_id INTEGER,
  p_activity_id INTEGER,
  p_notification_type TEXT,
  p_title TEXT,
  p_message TEXT,
  p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS INTEGER AS $$
DECLARE
  v_notification_id INTEGER;
BEGIN
  INSERT INTO user_notifications (
    user_id,
    activity_id,
    notification_type,
    title,
    message,
    metadata
  ) VALUES (
    p_user_id,
    p_activity_id,
    p_notification_type,
    p_title,
    p_message,
    p_metadata
  ) RETURNING notification_id INTO v_notification_id;
  
  RETURN v_notification_id;
END;
$$ LANGUAGE plpgsql;

-- Function to create notifications for all activity participants
CREATE OR REPLACE FUNCTION notify_activity_participants(
  p_activity_id INTEGER,
  p_notification_type TEXT,
  p_title TEXT,
  p_message TEXT,
  p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS INTEGER[] AS $$
DECLARE
  v_notification_ids INTEGER[] := '{}';
  v_participant_id INTEGER;
  v_notification_id INTEGER;
BEGIN
  -- Notify activity creator (author)
  SELECT creator_id INTO v_participant_id
  FROM pr_activities
  WHERE activity_id = p_activity_id;
  
  IF v_participant_id IS NOT NULL THEN
    SELECT create_user_notification(
      v_participant_id,
      p_activity_id,
      p_notification_type,
      p_title,
      p_message,
      p_metadata
    ) INTO v_notification_id;
    v_notification_ids := array_append(v_notification_ids, v_notification_id);
  END IF;
  
  -- Notify all reviewers
  FOR v_participant_id IN
    SELECT DISTINCT user_id
    FROM pr_reviewer_teams
    WHERE activity_id = p_activity_id
      AND status IN ('joined', 'locked_in')
  LOOP
    SELECT create_user_notification(
      v_participant_id,
      p_activity_id,
      p_notification_type,
      p_title,
      p_message,
      p_metadata
    ) INTO v_notification_id;
    v_notification_ids := array_append(v_notification_ids, v_notification_id);
  END LOOP;
  
  RETURN v_notification_ids;
END;
$$ LANGUAGE plpgsql;

-- Function to mark notifications as read
CREATE OR REPLACE FUNCTION mark_notifications_read(
  p_user_id INTEGER,
  p_notification_ids INTEGER[] DEFAULT NULL
) RETURNS INTEGER AS $$
DECLARE
  v_updated_count INTEGER;
BEGIN
  IF p_notification_ids IS NULL THEN
    -- Mark all unread notifications as read
    UPDATE user_notifications
    SET is_read = TRUE
    WHERE user_id = p_user_id
      AND is_read = FALSE;
  ELSE
    -- Mark specific notifications as read
    UPDATE user_notifications
    SET is_read = TRUE
    WHERE user_id = p_user_id
      AND notification_id = ANY(p_notification_ids)
      AND is_read = FALSE;
  END IF;
  
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count;
END;
$$ LANGUAGE plpgsql;

-- Function to get user notification summary
CREATE OR REPLACE FUNCTION get_user_notification_summary(p_user_id INTEGER)
RETURNS TABLE (
  total_count INTEGER,
  unread_count INTEGER,
  latest_notification_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COUNT(*)::INTEGER as total_count,
    COUNT(*) FILTER (WHERE is_read = FALSE)::INTEGER as unread_count,
    MAX(created_at) as latest_notification_at
  FROM user_notifications
  WHERE user_id = p_user_id;
END;
$$ LANGUAGE plpgsql;

-- State transition notifications moved to application services

-- Grant permissions
GRANT SELECT, INSERT, UPDATE ON user_notifications TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE user_notifications_notification_id_seq TO authenticated;
GRANT EXECUTE ON FUNCTION create_user_notification(INTEGER, INTEGER, TEXT, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION notify_activity_participants(INTEGER, TEXT, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION mark_notifications_read(INTEGER, INTEGER[]) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_notification_summary(INTEGER) TO authenticated;

-- RLS Policies
ALTER TABLE user_notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own notifications"
  ON user_notifications FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM user_accounts ua
      WHERE ua.auth_id = auth.uid()
      AND ua.user_id = user_notifications.user_id
    )
  );

CREATE POLICY "Users can update their own notifications"
  ON user_notifications FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM user_accounts ua
      WHERE ua.auth_id = auth.uid()
      AND ua.user_id = user_notifications.user_id
    )
  );

-- System can create notifications for any user
CREATE POLICY "System can create notifications"
  ON user_notifications FOR INSERT
  WITH CHECK (true);
