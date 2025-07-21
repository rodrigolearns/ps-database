-- =============================================
-- 00000000000102_reviewer_team.sql
-- Reviewer Team Management
-- =============================================

-- Create ENUM type for reviewer status
DO $$ BEGIN
  CREATE TYPE reviewer_status AS ENUM (
    'joined',
    'removed',
    'defaulted'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON TYPE reviewer_status IS 'Status of a reviewer in a peer review activity';

-- Create Reviewer Team Members table
CREATE TABLE IF NOT EXISTS "Reviewer_Team_Members" (
  activity_id INTEGER NOT NULL REFERENCES "Peer_Review_Activities"(activity_id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES "User_Accounts"(user_id) ON DELETE CASCADE,
  status reviewer_status NOT NULL DEFAULT 'joined',
  rank INTEGER, -- Null until assigned during final ranking stage
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  rounds_completed INTEGER[] DEFAULT '{}'::INTEGER[], -- Which review rounds they've completed
  removed_reason TEXT, -- Why they were removed (if applicable)
  PRIMARY KEY (activity_id, user_id) -- A user can only be on a review team once
);
COMMENT ON TABLE "Reviewer_Team_Members" IS 'Reviewers who have joined a peer review activity';
COMMENT ON COLUMN "Reviewer_Team_Members".activity_id IS 'Foreign key to the Peer_Review_Activities table';
COMMENT ON COLUMN "Reviewer_Team_Members".user_id IS 'Foreign key to the User_Accounts table';
COMMENT ON COLUMN "Reviewer_Team_Members".status IS 'Current status of the reviewer';
COMMENT ON COLUMN "Reviewer_Team_Members".rank IS 'Final ranking position (determines token reward)';
COMMENT ON COLUMN "Reviewer_Team_Members".joined_at IS 'When the reviewer joined the team';
COMMENT ON COLUMN "Reviewer_Team_Members".rounds_completed IS 'Array of review round numbers the reviewer has completed';
COMMENT ON COLUMN "Reviewer_Team_Members".removed_reason IS 'Reason provided when removing a reviewer';

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_reviewer_team_user_id ON "Reviewer_Team_Members" (user_id);
CREATE INDEX IF NOT EXISTS idx_reviewer_team_status ON "Reviewer_Team_Members" (status);

-- Function to join a review team
CREATE OR REPLACE FUNCTION join_review_team(
  p_activity_id INTEGER,
  p_user_id INTEGER
)
RETURNS JSONB AS $$
DECLARE
  v_activity_record "Peer_Review_Activities"%ROWTYPE;
  v_template_record "Peer_Review_Templates"%ROWTYPE;
  v_current_team_size INTEGER;
  v_is_author BOOLEAN;
BEGIN
  -- Check if activity exists
  SELECT * INTO v_activity_record
  FROM "Peer_Review_Activities"
  WHERE activity_id = p_activity_id;
  
  IF v_activity_record IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Activity not found with ID: ' || p_activity_id
    );
  END IF;

  -- Check if activity is in a joinable state
  IF v_activity_record.current_state != 'submitted' THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Activity is not currently accepting new reviewers'
    );
  END IF;

  -- Get template information
  SELECT * INTO v_template_record
  FROM "Peer_Review_Templates"
  WHERE template_id = v_activity_record.template_id;

  -- Check if user is already on the team
  IF EXISTS (SELECT 1 FROM "Reviewer_Team_Members" WHERE activity_id = p_activity_id AND user_id = p_user_id) THEN
    RETURN jsonb_build_object(
      'success', false, 
      'message', 'User is already on this review team'
    );
  END IF;

  -- Check if user is an author or creator (should not be allowed to review)
  SELECT is_author_or_creator(p_user_id, p_activity_id) INTO v_is_author;
  IF v_is_author THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Authors cannot join as reviewers for their own paper'
    );
  END IF;

  -- Check if team is already full
  SELECT COUNT(*) INTO v_current_team_size
  FROM "Reviewer_Team_Members"
  WHERE activity_id = p_activity_id AND status = 'joined';
  
  IF v_current_team_size >= v_template_record.reviewer_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Review team is already full'
    );
  END IF;

  -- Add user to the review team
  INSERT INTO "Reviewer_Team_Members" (activity_id, user_id, status, joined_at)
  VALUES (p_activity_id, p_user_id, 'joined', NOW());

  -- Check if this completes the team and should start the activity
  SELECT COUNT(*) INTO v_current_team_size
  FROM "Reviewer_Team_Members"
  WHERE activity_id = p_activity_id AND status = 'joined';
  
  IF v_current_team_size = v_template_record.reviewer_count THEN
    -- Team is now full, update activity state
    UPDATE "Peer_Review_Activities"
    SET 
      current_state = 'Review Round 1',
      start_date = NOW(),
      stage_deadline = NOW() + INTERVAL '14 days'
    WHERE activity_id = p_activity_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Successfully joined the review team',
    'teamIsFull', (v_current_team_size >= v_template_record.reviewer_count)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION join_review_team(INTEGER, INTEGER) IS 'Adds a user to a review team if eligible and handles activity state transition when team is filled';

-- Function to get current review team
CREATE OR REPLACE FUNCTION get_review_team(
  p_activity_id INTEGER
)
RETURNS TABLE (
  user_id INTEGER,
  username TEXT,
  full_name TEXT,
  status reviewer_status,
  rank INTEGER,
  rounds_completed INTEGER[],
  joined_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    rtm.user_id,
    ua.username,
    ua.full_name,
    rtm.status,
    rtm.rank,
    rtm.rounds_completed,
    rtm.joined_at
  FROM "Reviewer_Team_Members" rtm
  JOIN "User_Accounts" ua ON rtm.user_id = ua.user_id
  WHERE rtm.activity_id = p_activity_id
  ORDER BY rtm.joined_at ASC;
END;
$$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION get_review_team(INTEGER) IS 'Returns the current review team members with user details for an activity';

-- Function to update reviewer status
CREATE OR REPLACE FUNCTION update_reviewer_status(
  p_activity_id INTEGER,
  p_user_id INTEGER,
  p_new_status reviewer_status,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_old_status reviewer_status;
BEGIN
  -- Get current status
  SELECT status INTO v_old_status
  FROM "Reviewer_Team_Members"
  WHERE activity_id = p_activity_id AND user_id = p_user_id;
  
  IF v_old_status IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Reviewer team member not found'
    );
  END IF;

  -- Update status with appropriate reason field
  IF p_new_status = 'removed' THEN
    UPDATE "Reviewer_Team_Members"
    SET status = p_new_status, removed_reason = p_reason
    WHERE activity_id = p_activity_id AND user_id = p_user_id;
  ELSE
    UPDATE "Reviewer_Team_Members"
    SET status = p_new_status
    WHERE activity_id = p_activity_id AND user_id = p_user_id;
  END IF;
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Reviewer status updated from ' || v_old_status || ' to ' || p_new_status,
    'activityId', p_activity_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION update_reviewer_status(INTEGER, INTEGER, reviewer_status, TEXT) IS 'Updates a reviewer''s status and optionally records a reason';

-- Function to check if a user can join a review team
CREATE OR REPLACE FUNCTION can_join_review_team(
  p_activity_id INTEGER,
  p_user_id INTEGER
)
RETURNS JSONB AS $$
DECLARE
  v_activity_record "Peer_Review_Activities"%ROWTYPE;
  v_template_record "Peer_Review_Templates"%ROWTYPE;
  v_current_team_size INTEGER;
  v_is_author BOOLEAN;
  v_is_member BOOLEAN;
BEGIN
  -- Check if activity exists
  SELECT * INTO v_activity_record
  FROM "Peer_Review_Activities"
  WHERE activity_id = p_activity_id;
  
  IF v_activity_record IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Activity not found',
      'canJoin', false
    );
  END IF;

  -- Check if activity is in a joinable state
  IF v_activity_record.current_state != 'submitted' THEN
    RETURN jsonb_build_object(
      'success', true,
      'message', 'Activity is not accepting new reviewers',
      'canJoin', false,
      'reason', 'activity_started'
    );
  END IF;

  -- Get template information
  SELECT * INTO v_template_record
  FROM "Peer_Review_Templates"
  WHERE template_id = v_activity_record.template_id;

  -- Check if user is already on the team
  SELECT EXISTS (
    SELECT 1 FROM "Reviewer_Team_Members"
    WHERE activity_id = p_activity_id AND user_id = p_user_id
  ) INTO v_is_member;
  
  IF v_is_member THEN
    RETURN jsonb_build_object(
      'success', true, 
      'message', 'User is already on this review team',
      'canJoin', false,
      'reason', 'already_joined'
    );
  END IF;

  -- Check if user is an author or creator
  SELECT is_author_or_creator(p_user_id, p_activity_id) INTO v_is_author;
  IF v_is_author THEN
    RETURN jsonb_build_object(
      'success', true,
      'message', 'Authors cannot review their own paper',
      'canJoin', false,
      'reason', 'is_author'
    );
  END IF;

  -- Check if team is already full
  SELECT COUNT(*) INTO v_current_team_size
  FROM "Reviewer_Team_Members"
  WHERE activity_id = p_activity_id AND status = 'joined';
  
  IF v_current_team_size >= v_template_record.reviewer_count THEN
    RETURN jsonb_build_object(
      'success', true,
      'message', 'Review team is already full',
      'canJoin', false,
      'reason', 'team_full',
      'currentSize', v_current_team_size,
      'maxSize', v_template_record.reviewer_count
    );
  END IF;

  -- User can join
  RETURN jsonb_build_object(
    'success', true,
    'message', 'User can join this review team',
    'canJoin', true,
    'currentSize', v_current_team_size,
    'maxSize', v_template_record.reviewer_count,
    'spotsRemaining', v_template_record.reviewer_count - v_current_team_size
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
COMMENT ON FUNCTION can_join_review_team(INTEGER, INTEGER) IS 'Checks if a user is eligible to join a review team';
