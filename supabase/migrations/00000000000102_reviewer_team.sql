-- =============================================
-- 00000000000104_reviewer_team.sql
-- Reviewer Team Management + Penalties
-- =============================================

-- 1. ENUM for reviewer_status (defines all valid statuses)
DO $$ BEGIN
  CREATE TYPE reviewer_status AS ENUM (
    'joined',
    'removed',
    'defaulted',
    'kicked_out'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE reviewer_status IS 'Status of a reviewer in a peer review activity';

-- 2. Create reviewer_team_members table
CREATE TABLE IF NOT EXISTS reviewer_team_members (
  activity_id       INTEGER NOT NULL
    REFERENCES peer_review_activities(activity_id) ON DELETE CASCADE,
  user_id           INTEGER NOT NULL
    REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  status            reviewer_status NOT NULL DEFAULT 'joined',
  rank              INTEGER,                          -- Final ranking position (determines token reward)
  joined_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(), -- When the reviewer joined the team
  rounds_completed  INTEGER[] DEFAULT '{}'::INTEGER[], -- Which review rounds the reviewer has completed
  removed_reason    TEXT,                              -- Why they were removed/kicked out
  PRIMARY KEY (activity_id, user_id)
);
COMMENT ON TABLE reviewer_team_members IS 'Reviewers who have joined a peer review activity';
COMMENT ON COLUMN reviewer_team_members.activity_id IS 'Foreign key to peer_review_activities';
COMMENT ON COLUMN reviewer_team_members.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN reviewer_team_members.status IS 'Current status of the reviewer';
COMMENT ON COLUMN reviewer_team_members.rank IS 'Final ranking position';
COMMENT ON COLUMN reviewer_team_members.joined_at IS 'Timestamp when the reviewer joined';
COMMENT ON COLUMN reviewer_team_members.rounds_completed IS 'Which review rounds completed';
COMMENT ON COLUMN reviewer_team_members.removed_reason IS 'Reason for removal or kick-out';

-- 3. Indexes for reviewer_team_members
CREATE INDEX IF NOT EXISTS idx_reviewer_team_user_id
  ON reviewer_team_members(user_id);
CREATE INDEX IF NOT EXISTS idx_reviewer_team_status
  ON reviewer_team_members(status);

-- 4. Penalty records for late or kick-out events
CREATE TABLE IF NOT EXISTS reviewer_penalties (
  penalty_id   SERIAL PRIMARY KEY,
  activity_id  INTEGER NOT NULL
    REFERENCES peer_review_activities(activity_id) ON DELETE CASCADE,
  user_id      INTEGER NOT NULL
    REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  penalty_type TEXT NOT NULL
    CHECK (penalty_type IN ('late','kicked_out')),
  amount       INTEGER NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE reviewer_penalties IS 'Records of penalties (token fines or kick-outs) for reviewers';
COMMENT ON COLUMN reviewer_penalties.penalty_type IS 'Type of penalty: late (1-day) or kicked_out (1-week)';
COMMENT ON COLUMN reviewer_penalties.amount IS 'Number of tokens fined or transferred';

-- 5. Function: join_review_team
CREATE OR REPLACE FUNCTION join_review_team(
  p_activity_id INTEGER,
  p_user_id     INTEGER
) RETURNS JSONB AS $$
DECLARE
  v_act peer_review_activities%ROWTYPE;
  v_tmpl peer_review_templates%ROWTYPE;
  v_count INT;
  v_is_auth BOOLEAN;
BEGIN
  -- Fetch activity and ensure exists
  SELECT * INTO v_act FROM peer_review_activities WHERE activity_id = p_activity_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',false,'message','Activity not found');
  END IF;

  -- Only accept joins when still in submitted
  IF v_act.current_state <> 'submitted' THEN
    RETURN jsonb_build_object('success',false,'message','Not accepting reviewers at this stage');
  END IF;

  -- Prevent authors from reviewing their own paper
  SELECT is_author_or_creator(p_user_id,p_activity_id) INTO v_is_auth;
  IF v_is_auth THEN
    RETURN jsonb_build_object('success',false,'message','Authors cannot review their own paper');
  END IF;

  -- Prevent duplicate joins
  IF EXISTS(SELECT 1 FROM reviewer_team_members WHERE activity_id=p_activity_id AND user_id=p_user_id) THEN
    RETURN jsonb_build_object('success',false,'message','User already on review team');
  END IF;

  -- Fetch template to know max reviewers
  SELECT * INTO v_tmpl FROM peer_review_templates WHERE template_id = v_act.template_id;

  -- Count joined reviewers
  SELECT COUNT(*) INTO v_count
    FROM reviewer_team_members
   WHERE activity_id=p_activity_id AND status='joined';
  IF v_count >= v_tmpl.reviewer_count THEN
    RETURN jsonb_build_object('success',false,'message','Review team is full');
  END IF;

  -- Insert new reviewer
  INSERT INTO reviewer_team_members(activity_id,user_id,status,joined_at)
    VALUES(p_activity_id,p_user_id,'joined',NOW());

  RETURN jsonb_build_object('success',true,'message','Successfully joined review team');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION join_review_team(INTEGER,INTEGER) IS 'Adds a user to a review team if eligible';

-- 6. Function: get_review_team
CREATE OR REPLACE FUNCTION get_review_team(
  p_activity_id INTEGER
) RETURNS TABLE(
  user_id          INTEGER,
  username         TEXT,
  full_name        TEXT,
  status           reviewer_status,
  rank             INTEGER,
  rounds_completed INTEGER[],
  joined_at        TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT rtm.user_id, ua.username, ua.full_name,
         rtm.status, rtm.rank, rtm.rounds_completed, rtm.joined_at
    FROM reviewer_team_members rtm
    JOIN user_accounts ua ON ua.user_id = rtm.user_id
   WHERE rtm.activity_id = p_activity_id
   ORDER BY rtm.joined_at;
END;
$$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION get_review_team(INTEGER) IS 'Returns the current review team members';

-- 7. Function: update_reviewer_status
CREATE OR REPLACE FUNCTION update_reviewer_status(
  p_activity_id INTEGER,
  p_user_id     INTEGER,
  p_new_status  reviewer_status,
  p_reason      TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_old reviewer_status;
BEGIN
  SELECT status INTO v_old
    FROM reviewer_team_members
   WHERE activity_id=p_activity_id AND user_id=p_user_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',false,'message','Reviewer not found');
  END IF;

  -- Update status and record reason if kicked out
  IF p_new_status = 'kicked_out' THEN
    UPDATE reviewer_team_members
       SET status=p_new_status, removed_reason=p_reason
     WHERE activity_id=p_activity_id AND user_id=p_user_id;
  ELSE
    UPDATE reviewer_team_members
       SET status=p_new_status
     WHERE activity_id=p_activity_id AND user_id=p_user_id;
  END IF;

  RETURN jsonb_build_object('success',true,'message',
    'Status updated from '||v_old||' to '||p_new_status);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION update_reviewer_status(INTEGER,INTEGER,reviewer_status,TEXT) IS 'Updates a reviewer''s status';

-- 8. Function: can_join_review_team
CREATE OR REPLACE FUNCTION can_join_review_team(
  p_activity_id INTEGER,
  p_user_id     INTEGER
) RETURNS JSONB AS $$
DECLARE
  v_act peer_review_activities%ROWTYPE;
  v_tmpl peer_review_templates%ROWTYPE;
  v_count INT;
  v_is_auth BOOLEAN;
  v_is_mem BOOLEAN;
BEGIN
  SELECT * INTO v_act FROM peer_review_activities WHERE activity_id=p_activity_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',false,'canJoin',false,'message','Activity not found');
  END IF;
  IF v_act.current_state <> 'submitted' THEN
    RETURN jsonb_build_object('success',true,'canJoin',false,'reason','activity_started');
  END IF;
  SELECT is_author_or_creator(p_user_id,p_activity_id) INTO v_is_auth;
  IF v_is_auth THEN
    RETURN jsonb_build_object('success',true,'canJoin',false,'reason','is_author');
  END IF;
  SELECT EXISTS(
    SELECT 1 FROM reviewer_team_members
     WHERE activity_id=p_activity_id AND user_id=p_user_id
  ) INTO v_is_mem;
  IF v_is_mem THEN
    RETURN jsonb_build_object('success',true,'canJoin',false,'reason','already_joined');
  END IF;
  SELECT * INTO v_tmpl FROM peer_review_templates WHERE template_id=v_act.template_id;
  SELECT COUNT(*) INTO v_count
    FROM reviewer_team_members
   WHERE activity_id=p_activity_id AND status='joined';
  IF v_count >= v_tmpl.reviewer_count THEN
    RETURN jsonb_build_object('success',true,'canJoin',false,'reason','team_full');
  END IF;
  RETURN jsonb_build_object('success',true,'canJoin',true,'currentSize',v_count,'maxSize',v_tmpl.reviewer_count,'spotsRemaining',v_tmpl.reviewer_count - v_count);
END;
$$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION can_join_review_team(INTEGER,INTEGER) IS 'Checks eligibility for joining review team';
