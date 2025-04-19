-- =============================================
-- 00000000000023_awarding.sql
-- Award types and awards given
-- =============================================

-- Reuse or create award_type enum if not exists
DO $$ BEGIN
  CREATE TYPE award_type AS ENUM ('helpfulness','clarity','challenger');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON TYPE award_type IS 'Types of peer-review awards';

-- Award types table (optional metadata override)
CREATE TABLE IF NOT EXISTS "Award_Types" (
  award_type     award_type PRIMARY KEY,
  description    TEXT NOT NULL,
  author_points  INTEGER NOT NULL,  -- points when awarded by the corresponding author
  reviewer_points INTEGER NOT NULL  -- points when awarded by other reviewers
);
COMMENT ON TABLE "Award_Types" IS 'Definitions for each award category';
COMMENT ON COLUMN "Award_Types".author_points IS 'Token points awarded when given by the paper author';
COMMENT ON COLUMN "Award_Types".reviewer_points IS 'Token points awarded when given by another reviewer';

-- Seed base descriptions & points
INSERT INTO "Award_Types"(award_type, description, author_points, reviewer_points)
VALUES
  ('helpfulness', 'Most helpful and applicable evaluation', 2, 1),
  ('clarity',     'Most clear and detailed assessment', 2, 1),
  ('challenger',  'Most critical and constructive critique', 2, 1)
ON CONFLICT (award_type) DO NOTHING;

-- Awards given by authors or reviewers
CREATE TABLE IF NOT EXISTS "Awards_Given" (
  award_id       SERIAL PRIMARY KEY,
  activity_id    INTEGER NOT NULL
    REFERENCES "Peer_Review_Activities"(activity_id) ON DELETE CASCADE,
  round_number   INTEGER NOT NULL,
  giver_id       INTEGER NOT NULL
    REFERENCES "User_Accounts"(user_id),
  receiver_id    INTEGER NOT NULL
    REFERENCES "User_Accounts"(user_id),
  points_awarded INTEGER NOT NULL,  -- Actual points awarded (stored for record)
  award_type     award_type NOT NULL,
  given_at       TIMESTAMPTZ DEFAULT NOW(),
  CHECK (giver_id <> receiver_id)
);
COMMENT ON TABLE "Awards_Given" IS 'Instances of awards bestowed during awarding stage';
COMMENT ON COLUMN "Awards_Given".points_awarded IS 'Actual token points awarded (varies based on giver role)';

-- Function to give an award and distribute tokens
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
  v_points_to_award INTEGER;
  v_escrow_balance INTEGER;
  v_is_author BOOLEAN;
  v_award_id INTEGER;
  v_activity_uuid UUID;
BEGIN
  -- Validate giver != receiver
  IF p_giver_id = p_receiver_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Cannot give an award to yourself'
    );
  END IF;
  
  -- Check if award already given by this giver for this activity+round
  IF EXISTS (
    SELECT 1 FROM "Awards_Given"
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
  FROM "Award_Types"
  WHERE award_type = p_award_type;
  
  -- Determine if giver is the paper author
  SELECT (creator_id = p_giver_id), activity_uuid
  INTO v_is_author, v_activity_uuid
  FROM "Peer_Review_Activities"
  WHERE activity_id = p_activity_id;
  
  -- Set points based on giver role
  IF v_is_author THEN
    v_points_to_award := v_author_points;
  ELSE
    v_points_to_award := v_reviewer_points;
  END IF;
  
  -- Check activity escrow balance
  SELECT escrow_balance INTO v_escrow_balance
  FROM "Peer_Review_Activities"
  WHERE activity_id = p_activity_id;
  
  IF v_escrow_balance < v_points_to_award THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient tokens in activity escrow'
    );
  END IF;
  
  -- Begin transaction
  BEGIN
    -- Insert the award
    INSERT INTO "Awards_Given" (
      activity_id, round_number, giver_id, receiver_id, 
      points_awarded, award_type
    ) VALUES (
      p_activity_id, p_round_number, p_giver_id, p_receiver_id, 
      v_points_to_award, p_award_type
    ) RETURNING award_id INTO v_award_id;
    
    -- Reduce escrow balance
    UPDATE "Peer_Review_Activities"
    SET escrow_balance = escrow_balance - v_points_to_award
    WHERE activity_id = p_activity_id;
    
    -- Add tokens to receiver's wallet
    PERFORM activity_reward_tokens(
      p_receiver_id,
      v_points_to_award,
      'Award: ' || p_award_type || ' (' || v_points_to_award || ' tokens) for round ' || p_round_number,
      p_activity_id,
      v_activity_uuid
    );
    
    RETURN jsonb_build_object(
      'success', true,
      'message', 'Award given successfully',
      'award_id', v_award_id,
      'tokens_awarded', v_points_to_award,
      'awarded_by', CASE WHEN v_is_author THEN 'author' ELSE 'reviewer' END
    );
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RETURN jsonb_build_object(
        'success', false,
        'message', 'Error giving award: ' || SQLERRM
      );
  END;
  
  COMMIT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
