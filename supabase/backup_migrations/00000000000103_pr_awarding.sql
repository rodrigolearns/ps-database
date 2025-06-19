-- =============================================
-- 00000000000103_pr_awarding.sql
-- Award types, award records, and reviewer rewarding
-- =============================================

-- 1. award_type enum
DO $$ BEGIN
  CREATE TYPE award_type AS ENUM ('helpfulness','clarity','challenger');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE award_type IS 'Categories of peer-review awards';

-- 2. award_types metadata
CREATE TABLE IF NOT EXISTS award_types (
  award_type      award_type PRIMARY KEY,
  description     TEXT        NOT NULL,
  author_points   INT         NOT NULL,
  reviewer_points INT         NOT NULL
);
COMMENT ON TABLE award_types IS 'Point values and descriptions for each award category';

INSERT INTO award_types (award_type, description, author_points, reviewer_points)
VALUES
  ('helpfulness','Most helpful and applicable evaluation',50,50),
  ('clarity','Most clear and detailed assessment',50,50),
  ('challenger','Most critical and constructive critique',75,75)
ON CONFLICT (award_type) DO NOTHING;

-- 3. awards_given record
CREATE TABLE IF NOT EXISTS awards_given (
  award_id       SERIAL        PRIMARY KEY,
  activity_id    INT           NOT NULL REFERENCES peer_review_activities(activity_id) ON DELETE CASCADE,
  round_number   INT           NOT NULL,
  giver_id       INT           NOT NULL REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  receiver_id    INT           NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  award_type     award_type    NOT NULL,
  points_awarded INT           NOT NULL,
  given_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CHECK (giver_id <> receiver_id)
);
COMMENT ON TABLE awards_given IS 'Individual award instances, with points for ranking';

-- 4. Function: give_award
CREATE OR REPLACE FUNCTION give_award(
  p_activity_id   INT,
  p_round_number  INT,
  p_giver_id      INT,
  p_receiver_id   INT,
  p_award_type    award_type
) RETURNS JSONB AS $$
DECLARE
  v_is_creator   BOOL;
  v_points       INT;
BEGIN
  IF p_giver_id = p_receiver_id THEN
    RETURN jsonb_build_object('success',false,'message','Cannot award yourself');
  END IF;

  -- Prevent duplicates
  IF EXISTS (
    SELECT 1 FROM awards_given
     WHERE activity_id = p_activity_id
       AND round_number = p_round_number
       AND giver_id     = p_giver_id
       AND award_type   = p_award_type
  ) THEN
    RETURN jsonb_build_object('success',false,
      'message','Already gave '||p_award_type||' this round');
  END IF;

  -- Determine creator vs. reviewer
  SELECT creator_id = p_giver_id
    INTO v_is_creator
    FROM peer_review_activities
   WHERE activity_id = p_activity_id;

  -- Fetch appropriate points
  SELECT CASE WHEN v_is_creator THEN author_points ELSE reviewer_points END
    INTO v_points
    FROM award_types
   WHERE award_type = p_award_type;

  -- Insert record
  INSERT INTO awards_given (
    activity_id, round_number, giver_id, receiver_id, award_type, points_awarded
  ) VALUES (
    p_activity_id, p_round_number, p_giver_id, p_receiver_id, p_award_type, v_points
  );

  RETURN jsonb_build_object('success',true,
    'message','Award recorded','points',v_points);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success',false,'message','Error: '||SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION give_award IS 'Record an award and its point value for ranking';

-- 5. Function: rank_and_reward_reviewers
CREATE OR REPLACE FUNCTION rank_and_reward_reviewers(p_activity_id INT)
RETURNS JSONB AS $$
DECLARE
  v_template_id  INT;
  v_escrow       INT;
  v_uuid         UUID;
  v_super_admin  INT;
  v_awarded      INT := 0;
  rec            RECORD;
BEGIN
  -- Load core activity info
  SELECT template_id, escrow_balance, activity_uuid, super_admin_id
    INTO v_template_id, v_escrow, v_uuid, v_super_admin
    FROM peer_review_activities
   WHERE activity_id = p_activity_id;

  -- Calculate and rank reviewer points
  WITH pts AS (
    SELECT rtm.user_id,
           COALESCE(SUM(ag.points_awarded),0) AS total_points
      FROM reviewer_team_members rtm
 LEFT JOIN awards_given ag ON ag.activity_id = rtm.activity_id
                           AND ag.receiver_id = rtm.user_id
     WHERE rtm.activity_id = p_activity_id
       AND rtm.status = 'joined'
  ), ranked AS (
    SELECT user_id,
           DENSE_RANK() OVER (ORDER BY total_points DESC) AS rank
      FROM pts
  ), template AS (
    SELECT array_agg(tokens ORDER BY rank_pos) AS tokens_by_rank
      FROM template_token_ranks
     WHERE template_id = v_template_id
  )
  -- Distribute tokens according to rank
  SELECT INTO v_awarded
    SUM(
      CASE
        WHEN rt.rank <= card(template.tokens_by_rank) 
          THEN template.tokens_by_rank[rt.rank]
        ELSE 0
      END
    )
    FROM ranked rt, template, LATERAL UNNEST(template.tokens_by_rank) WITH ORDINALITY AS t(tokens,rank_pos);

  -- Deduct from escrow and reward each reviewer
  PERFORM activity_reward_tokens(
    NULL,  -- we'll deduct individually below
    0,
    '',      -- placeholder
    p_activity_id,
    v_uuid
  ); -- (no-op, assuming it initializes something)

  FOR rec IN SELECT * FROM ranked LOOP
    PERFORM activity_reward_tokens(
      rec.user_id,
      template.tokens_by_rank[rec.rank],
      'Rank '||rec.rank||' reward',
      p_activity_id,
      v_uuid
    );
  END LOOP;

  -- Leftover to super_admin
  IF v_escrow - v_awarded > 0 AND v_super_admin IS NOT NULL THEN
    PERFORM activity_reward_tokens(
      v_super_admin,
      v_escrow - v_awarded,
      'Leftover escrow',
      p_activity_id,
      v_uuid
    );
  END IF;

  -- Mark activity completed
  UPDATE peer_review_activities
     SET escrow_balance = 0,
         current_state = 'completed',
         completed_at  = NOW()
   WHERE activity_id = p_activity_id;

  RETURN jsonb_build_object('success',true,
    'message','Distributed '||v_awarded||' tokens');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success',false,'message','Error: '||SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION rank_and_reward_reviewers IS 'Rank reviewers by awards, distribute tokens, and complete activity';

-- 6. Optional wrapper
CREATE OR REPLACE FUNCTION trigger_activity_completion(p_activity_id INT)
RETURNS JSONB AS $$
BEGIN
  RETURN rank_and_reward_reviewers(p_activity_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION trigger_activity_completion IS 'Trigger final ranking & rewarding';
