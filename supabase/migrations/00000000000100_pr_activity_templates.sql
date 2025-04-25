-- =============================================
-- 00000000000100_pr_activity_templates.sql
-- PR ACTICITY TEMPLATE
-- =============================================
-- 1. ENUMs
DO $$ BEGIN
  CREATE TYPE activity_state AS ENUM (
    'submitted',
    'review_round_1',
    'author_response_1',
    'review_round_2',
    'author_response_2',
    'evaluation',
    'awarding',
    'completed'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE activity_state IS 'Current stage of the peer review activity';

DO $$ BEGIN
  CREATE TYPE moderation_state AS ENUM ('none','pending','resolved');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON TYPE moderation_state IS 'Moderation state of the activity';

-- 2. peer_review_templates & token ranks
CREATE TABLE IF NOT EXISTS peer_review_templates (
  template_id     SERIAL PRIMARY KEY,
  name            TEXT NOT NULL UNIQUE,
  reviewer_count  INTEGER NOT NULL,
  review_rounds   INTEGER NOT NULL,
  total_tokens    INTEGER NOT NULL,
  extra_tokens    INTEGER NOT NULL DEFAULT 2,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS template_token_ranks (
  template_id  INT NOT NULL REFERENCES peer_review_templates(template_id) ON DELETE CASCADE,
  rank_pos     INT NOT NULL,
  tokens       INT NOT NULL,
  PRIMARY KEY (template_id, rank_pos)
);

-- 3. peer_review_activities
CREATE TABLE IF NOT EXISTS peer_review_activities (
  activity_id     SERIAL PRIMARY KEY,
  activity_uuid   UUID NOT NULL DEFAULT gen_random_uuid(),
  paper_id        INT NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  creator_id      INT REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  template_id     INT NOT NULL REFERENCES peer_review_templates(template_id),
  funding_amount  INT NOT NULL,
  escrow_balance  INT NOT NULL,
  current_state   activity_state NOT NULL DEFAULT 'submitted',
  stage_deadline  TIMESTAMPTZ,
  moderation_state moderation_state NOT NULL DEFAULT 'none',
  posted_at       TIMESTAMPTZ DEFAULT NOW(),
  start_date      TIMESTAMPTZ,
  completed_at    TIMESTAMPTZ,
  super_admin_id  INT REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_escrow_nonnegative      CHECK (escrow_balance >= 0),
  CONSTRAINT chk_escrow_not_exceed_funding CHECK (escrow_balance <= funding_amount)
);

-- =============================================
-- PR Activtiy Template Seed Data
-- =============================================

INSERT INTO peer_review_templates(name, reviewer_count, review_rounds, total_tokens, extra_tokens)
VALUES
  ('1-round,3-reviewers,10-tokens', 3, 1, 10, 2),
  ('2-round,4-reviewers,15-tokens', 4, 2, 15, 2)
ON CONFLICT (name) DO UPDATE
  SET reviewer_count=EXCLUDED.reviewer_count,
      review_rounds=EXCLUDED.review_rounds,
      total_tokens=EXCLUDED.total_tokens,
      extra_tokens=EXCLUDED.extra_tokens,
      updated_at=NOW();

-- Unnest each template’s token split
INSERT INTO template_token_ranks(template_id, rank_pos, tokens)
SELECT
  t.template_id,
  u.ordinality,
  u.val
FROM peer_review_templates t
JOIN LATERAL (
  SELECT ARRAY[3,3,2]::INT[] AS arr WHERE t.name='1-round,3-reviewers,10-tokens'
  UNION ALL
  SELECT ARRAY[4,4,3,2]::INT[]      WHERE t.name='2-round,4-reviewers,15-tokens'
) AS cfg ON TRUE
JOIN LATERAL unnest(cfg.arr) WITH ORDINALITY AS u(val, ordinality) ON TRUE
ON CONFLICT DO NOTHING;

-- =============================================
-- Triggers & Audit for Peer Review Activity State
-- =============================================

-- 1. Generic updated_at trigger for templates & activities
CREATE OR REPLACE FUNCTION public.set_updated_at()
  RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach to peer_review_templates
CREATE TRIGGER trg_pr_templates_set_updated
  BEFORE UPDATE ON peer_review_templates
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Attach to peer_review_activities
CREATE TRIGGER trg_pr_activities_set_updated
  BEFORE UPDATE ON peer_review_activities
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- 2. Valid state transitions table
CREATE TABLE IF NOT EXISTS activity_state_transitions (
  from_state activity_state NOT NULL,
  to_state   activity_state NOT NULL,
  PRIMARY KEY (from_state, to_state)
);

-- Seed your allowed transitions here:
INSERT INTO activity_state_transitions(from_state, to_state) VALUES
  ('submitted','review_round_1'),
  ('review_round_1','author_response_1'),
  ('author_response_1','review_round_2'),
  ('review_round_2','author_response_2'),
  ('author_response_1','evaluation'),
  ('author_response_2','evaluation'),
  ('evaluation','awarding'),
  ('awarding','completed')
ON CONFLICT DO NOTHING;


-- 3. Audit‐and‐enforce trigger function
CREATE OR REPLACE FUNCTION enforce_activity_state_change()
  RETURNS TRIGGER AS $$
BEGIN
  -- 3a. Enforce only allowed transitions
  IF NOT EXISTS (
    SELECT 1
      FROM activity_state_transitions
     WHERE from_state = OLD.current_state
       AND to_state   = NEW.current_state
  ) THEN
    RAISE EXCEPTION 'Invalid state transition % → %', OLD.current_state, NEW.current_state;
  END IF;

  -- 3b. Record it in the audit log
  INSERT INTO pr_activity_state_log (
    activity_id,
    old_state,
    new_state,
    changed_at,
    changed_by    -- you can update this trigger later to capture the user
  ) VALUES (
    OLD.activity_id,
    OLD.current_state,
    NEW.current_state,
    NOW(),
    NULL
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- 4. Attach enforcement to state changes
CREATE TRIGGER trg_validate_pr_state
  BEFORE UPDATE OF current_state ON peer_review_activities
  FOR EACH ROW
  EXECUTE FUNCTION enforce_activity_state_change();


-- 5. Audit log table
CREATE TABLE IF NOT EXISTS pr_activity_state_log (
  log_id      SERIAL PRIMARY KEY,
  activity_id INT NOT NULL REFERENCES peer_review_activities(activity_id),
  old_state   activity_state NOT NULL,
  new_state   activity_state NOT NULL,
  changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  changed_by  INT NULL REFERENCES user_accounts(user_id)
);
COMMENT ON TABLE pr_activity_state_log IS 'History of peer-review activity state transitions';
