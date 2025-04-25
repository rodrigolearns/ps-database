-- =============================================
-- 00000000000023_awarding.sql
-- Award types and rewards given
-- =============================================

-- Reuse or create award_type enum if not exists
DO $$ BEGIN
  CREATE TYPE award_type AS ENUM ('helpfulness','clarity','challenger');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON TYPE award_type IS 'Types of peer-review awards';

-- award_types table (optional metadata override)
CREATE TABLE IF NOT EXISTS award_types (
  award_type     award_type PRIMARY KEY,
  description    TEXT NOT NULL,
  author_points  INTEGER NOT NULL,  -- points when awarded by the corresponding author
  reviewer_points INTEGER NOT NULL  -- points when awarded by other reviewers
);
COMMENT ON TABLE award_types IS 'Definitions for each award category';
COMMENT ON COLUMN award_types.author_points IS 'Potential token points awarded when given by the paper author';
COMMENT ON COLUMN award_types.reviewer_points IS 'Potential token points awarded when given by another reviewer';

-- Seed base descriptions & points
INSERT INTO award_types(award_type, description, author_points, reviewer_points)
VALUES
  ('helpfulness', 'Most helpful and applicable evaluation', 50, 50),
  ('clarity',     'Most clear and detailed assessment', 50, 50),
  ('challenger',  'Most critical and constructive critique', 75, 75)
ON CONFLICT (award_type) DO NOTHING;

-- awards_given by authors or reviewers
CREATE TABLE IF NOT EXISTS awards_given (
  award_id       SERIAL PRIMARY KEY,
  activity_id    INTEGER NOT NULL
    REFERENCES peer_review_activities(activity_id) ON DELETE CASCADE,
  round_number   INTEGER NOT NULL, -- Store round number for context if needed
  giver_id       INTEGER NOT NULL
    REFERENCES user_accounts(user_id) ON DELETE SET NULL, -- Use SET NULL to keep award record if user deleted
  receiver_id    INTEGER NOT NULL
    REFERENCES user_accounts(user_id) ON DELETE CASCADE, -- Cascade delete if receiver deleted
  points_awarded INTEGER NOT NULL,  -- Points assigned based on award type and giver role (used for ranking)
  award_type     award_type NOT NULL,
  given_at       TIMESTAMPTZ DEFAULT NOW(),
  CHECK (giver_id <> receiver_id)
);
COMMENT ON TABLE awards_given IS 'Instances of awards bestowed during awarding stage, records potential points for ranking';
COMMENT ON COLUMN awards_given.points_awarded IS 'Potential points assigned based on award type and giver role (used for ranking)';
COMMENT ON COLUMN awards_given.round_number IS 'The review round during which the award relates to';

-- Function to record an award
-- This function NO LONGER distributes tokens directly.
CREATE OR REPLACE FUNCTION give_award(
  p_activity_id INTEGER,
  p_round_number INTEGER,
  p_giver_id INTEGER,
  p_receiver_id INTEGER,
  p_award_type award_type
)
RETURNS JSONB AS $$
DECLARE
  v_author_points INTEGER;
  v_reviewer_points INTEGER;
  v_points_to_record INTEGER;
  v_is_author BOOLEAN;
  v_award_id INTEGER;
  v_activity_state activity_state;
BEGIN
  -- Validate giver != receiver
  IF p_giver_id = p_receiver_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Cannot give an award to yourself'
    );
  END IF;

  -- Check activity state (e.g., should be in 'awarding' state)
  SELECT current_state INTO v_activity_state
  FROM peer_review_activities
  WHERE activity_id = p_activity_id;

  -- Optional: Add check for activity state if awards are only allowed during a specific phase
  -- IF v_activity_state != 'awarding' THEN
  --   RETURN jsonb_build_object(
  --     'success', false,
  --     'message', 'Awards can only be given during the awarding phase'
  --   );
  -- END IF;
  
  -- Check if award already given by this giver for this activity+round+type
  IF EXISTS (
    SELECT 1 FROM awards_given
    WHERE activity_id = p_activity_id
      AND round_number = p_round_number
      AND giver_id = p_giver_id
      AND award_type = p_award_type
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'You have already given a ' || p_award_type || ' award for this round'
    );
  END IF;
  
  -- Get points for this award type
  SELECT author_points, reviewer_points 
  INTO v_author_points, v_reviewer_points
  FROM award_types
  WHERE award_type = p_award_type;
  
  -- Determine if giver is the paper author (creator)
  SELECT (creator_id = p_giver_id)
  INTO v_is_author
  FROM peer_review_activities
  WHERE activity_id = p_activity_id;
  
  -- Set points to record based on giver role
  IF v_is_author THEN
    v_points_to_record := v_author_points;
  ELSE
    v_points_to_record := v_reviewer_points;
  END IF;
  
  -- Insert the award record
  INSERT INTO awards_given (
    activity_id, round_number, giver_id, receiver_id, 
    points_awarded, award_type
  ) VALUES (
    p_activity_id, p_round_number, p_giver_id, p_receiver_id, 
    v_points_to_record, p_award_type
  ) RETURNING award_id INTO v_award_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Award recorded successfully',
    'award_id', v_award_id,
    'points_recorded', v_points_to_record
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error recording award: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION give_award(INTEGER, INTEGER, INTEGER, INTEGER, award_type) IS 'Records an award given by a user to another user for a specific activity and round. Does not distribute tokens.';


-- =============================================
-- Rewarding Logic
-- =============================================

-- Function to rank reviewers based on awards and distribute tokens
CREATE OR REPLACE FUNCTION rank_and_reward_reviewers(p_activity_id INTEGER)
RETURNS JSONB AS $$
DECLARE
  v_activity_record RECORD;
  v_template_record RECORD;
  v_reviewer_points RECORD;
  v_ranked_reviewers RECORD;
  v_rank INTEGER := 0;
  v_last_points INTEGER := -1;
  v_rank_increment INTEGER := 1;
  v_tokens_by_rank INTEGER[];
  v_reward_amount INTEGER;
  v_escrow_balance INTEGER;
  v_activity_uuid UUID;
  v_super_admin_id INTEGER;
  v_total_rewarded INTEGER := 0;
BEGIN
  -- Get activity details
  SELECT activity_uuid, template_id, escrow_balance, current_state, super_admin_id
  INTO v_activity_uuid, v_template_record.template_id, v_escrow_balance, v_activity_record.current_state, v_super_admin_id
  FROM peer_review_activities
  WHERE activity_id = p_activity_id;

  IF v_activity_record.current_state IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Activity not found');
  END IF;

  -- Check if activity is in the correct state (e.g., 'awarding')
  -- Adjust this state check as needed for your workflow
  IF v_activity_record.current_state != 'awarding' THEN
     RETURN jsonb_build_object(
       'success', false, 
       'message', 'Activity is not in the awarding state. Current state: ' || v_activity_record.current_state
     );
  END IF;

  -- Get template details (specifically tokens_by_rank)
  SELECT tokens_by_rank INTO v_tokens_by_rank
  FROM peer_review_templates
  WHERE template_id = v_template_record.template_id;

  IF v_tokens_by_rank IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Template token distribution not found');
  END IF;

  -- 1. Calculate points for each reviewer
  -- Using a CTE to calculate points per reviewer
  WITH ReviewerPoints AS (
    SELECT 
      rtm.user_id,
      COALESCE(SUM(ag.points_awarded), 0) AS total_points
    FROM reviewer_team_members rtm
    LEFT JOIN awards_given ag ON rtm.user_id = ag.receiver_id AND rtm.activity_id = ag.activity_id
    WHERE rtm.activity_id = p_activity_id
      AND rtm.status = 'joined' -- Only consider active/joined reviewers for ranking
    GROUP BY rtm.user_id
  )
  -- 2. Rank reviewers and update the reviewer_team_members table
  UPDATE reviewer_team_members AS rtm
  SET rank = r.final_rank
  FROM (
    SELECT 
      user_id,
      total_points,
      -- Dense rank handles ties correctly (assigns same rank, next rank increments)
      DENSE_RANK() OVER (ORDER BY total_points DESC) as final_rank
    FROM ReviewerPoints
  ) AS r
  WHERE rtm.activity_id = p_activity_id AND rtm.user_id = r.user_id;

  -- 3. Distribute rewards based on rank
  FOR v_ranked_reviewers IN
    SELECT user_id, rank
    FROM reviewer_team_members
    WHERE activity_id = p_activity_id
      AND rank IS NOT NULL
      AND status = 'joined' -- Ensure only currently joined members get rewards
    ORDER BY rank ASC
  LOOP
    -- Get reward amount from template based on rank (adjust for 0-based array index)
    IF v_ranked_reviewers.rank > 0 AND v_ranked_reviewers.rank <= array_length(v_tokens_by_rank, 1) THEN
      v_reward_amount := v_tokens_by_rank[v_ranked_reviewers.rank];
    ELSE
      v_reward_amount := 0; -- No reward if rank is invalid or outside the defined ranks
    END IF;

    -- Check escrow balance
    IF v_escrow_balance >= v_reward_amount AND v_reward_amount > 0 THEN
      -- Reward the user
      PERFORM activity_reward_tokens(
        v_ranked_reviewers.user_id,
        v_reward_amount,
        'Rank ' || v_ranked_reviewers.rank || ' reward for PR activity #' || p_activity_id,
        p_activity_id,
        v_activity_uuid
      );
      
      -- Decrease local escrow balance tracker
      v_escrow_balance := v_escrow_balance - v_reward_amount;
      v_total_rewarded := v_total_rewarded + v_reward_amount;
    ELSE
      -- Log or handle insufficient balance for this specific reward
      RAISE WARNING 'Insufficient escrow balance (% remaining) to reward user % (% tokens for rank %)', 
                    v_escrow_balance, v_ranked_reviewers.user_id, v_reward_amount, v_ranked_reviewers.rank;
    END IF;
  END LOOP;

  -- 4. Handle leftover escrow balance
  IF v_escrow_balance > 0 AND v_super_admin_id IS NOT NULL THEN
    RAISE NOTICE 'Rewarding super admin % with leftover % tokens from activity %.', 
                  v_super_admin_id, v_escrow_balance, p_activity_id;
    PERFORM activity_reward_tokens(
      v_super_admin_id,
      v_escrow_balance,
      'Leftover escrow balance from PR activity #' || p_activity_id,
      p_activity_id,
      v_activity_uuid
    );
    -- Update the total rewarded to reflect the transfer to super admin
    v_total_rewarded := v_total_rewarded + v_escrow_balance;
    v_escrow_balance := 0; -- Escrow should be empty now
  ELSIF v_escrow_balance > 0 THEN
     RAISE WARNING 'Activity % completed with % tokens remaining in escrow, but no super admin configured.', 
                    p_activity_id, v_escrow_balance;
  END IF;

  -- 5. Update activity status to completed
  UPDATE peer_review_activities
  SET 
    escrow_balance = v_escrow_balance, -- Update with the final balance (should be 0 if super admin exists)
    current_state = 'completed',
    completed_at = NOW()
  WHERE activity_id = p_activity_id;

  RETURN jsonb_build_object(
    'success', true, 
    'message', 'Reviewers ranked and rewarded. Activity completed.',
    'total_tokens_rewarded', v_total_rewarded,
    'final_escrow_balance', v_escrow_balance
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error during ranking and rewarding: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rank_and_reward_reviewers(INTEGER) IS 'Calculates reviewer points, ranks them, distributes rewards based on template ranks, handles leftover escrow, and marks the activity as completed.';

-- Optional: Function to trigger the completion process (e.g., called after awarding phase ends)
CREATE OR REPLACE FUNCTION trigger_activity_completion(p_activity_id INTEGER)
RETURNS JSONB AS $$
BEGIN
  -- Basic wrapper, could add more logic here (e.g., checks, notifications)
  RETURN rank_and_reward_reviewers(p_activity_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION trigger_activity_completion(INTEGER) IS 'Triggers the final ranking and rewarding process for a peer review activity.';
