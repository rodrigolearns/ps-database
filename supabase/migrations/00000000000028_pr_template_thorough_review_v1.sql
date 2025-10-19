-- =============================================
-- 00000000000028_pr_template_thorough_review_v1.sql
-- PR Template: Thorough Review (v1)
-- =============================================
-- Two-round review: in-depth evaluation with author response between rounds
-- Workflow: review_1 → author_resp_1 → review_2 → assessment → awarding → publication_choice

-- 1. Create template record
INSERT INTO pr_templates (name, user_facing_name, description, reviewer_count, total_tokens, insurance_tokens, is_public, display_order)
VALUES (
  'thorough_review_2_rounds_4_reviewers_20_tokens_v1',
  'Thorough Review',  -- User-facing display name
  '2 review rounds with author responses, 4 reviewers, 20 tokens. In-depth evaluation for complex papers.',
  4,    -- reviewer_count
  20,   -- total_tokens
  2,    -- insurance_tokens (10% = 2 tokens)
  true,  -- is_public
  2     -- display_order
)
ON CONFLICT (name) DO UPDATE
  SET user_facing_name = EXCLUDED.user_facing_name,
      description = EXCLUDED.description,
      reviewer_count = EXCLUDED.reviewer_count,
      total_tokens = EXCLUDED.total_tokens,
      insurance_tokens = EXCLUDED.insurance_tokens,
      is_public = EXCLUDED.is_public,
      display_order = EXCLUDED.display_order,
      updated_at = NOW();

-- 2. Define workflow stages
INSERT INTO template_stage_graph 
  (template_id, activity_type, stage_key, stage_type, stage_order, deadline_days, display_name, is_initial_stage, is_terminal_stage)
SELECT 
  t.template_id,
  'pr-activity',
  stage_key,
  stage_type,
  stage_order,
  deadline_days,
  display_name,
  is_initial_stage,
  is_terminal_stage
FROM pr_templates t,
LATERAL (
  VALUES
    ('posted', 'posted', 0, NULL, 'Posted on Feed', true, false),
    ('review_1', 'review_round_1', 1, 3, 'Round 1: Initial Review', false, false),
    ('author_resp_1', 'author_response_round_1', 2, 14, 'Author Response to Round 1', false, false),
    ('review_2', 'review_round_2', 3, 14, 'Round 2: Revision Review', false, false),
    ('assessment', 'collaborative_assessment', 4, 3, 'Consensus Assessment', false, false),
    ('awarding', 'award_distribution', 5, 3, 'Award Distribution', false, false),
    ('publication_choice', 'publication_choice', 6, NULL, 'Publication Decision', false, true)
) AS stages(stage_key, stage_type, stage_order, deadline_days, display_name, is_initial_stage, is_terminal_stage)
WHERE t.name = 'thorough_review_2_rounds_4_reviewers_20_tokens_v1'
ON CONFLICT (template_id, activity_type, stage_key) DO NOTHING;

-- 3. Define stage transitions
INSERT INTO template_stage_transitions 
  (template_id, activity_type, from_stage_key, to_stage_key, condition_expression, is_automatic, transition_order)
SELECT
  t.template_id,
  'pr-activity',
  from_stage_key,
  to_stage_key,
  condition_expression::jsonb,
  is_automatic,
  transition_order
FROM pr_templates t,
LATERAL (
  VALUES
    -- posted → review_1 (when first review submitted)
    ('posted', 'review_1', '{"type": "first_review_submitted", "config": {"round_number": 1}}', true, 1),
    
    -- review_1 → author_resp_1 (when all round 1 reviews submitted)
    ('review_1', 'author_resp_1', '{"type": "all_reviews_submitted", "config": {"round_number": 1}}', true, 1),
    
    -- author_resp_1 → review_2 (when author responds)
    ('author_resp_1', 'review_2', '{"type": "author_response_submitted", "config": {"round_number": 1}}', true, 1),
    
    -- review_2 → assessment (when all round 2 reviews submitted)
    ('review_2', 'assessment', '{"type": "all_reviews_submitted", "config": {"round_number": 2}}', true, 1),
    
    -- assessment → awarding (when all finalized)
    ('assessment', 'awarding', '{"type": "all_finalized", "config": {}}', true, 1),
    
    -- awarding → publication_choice (when all distributed)
    ('awarding', 'publication_choice', '{"type": "all_awards_distributed", "config": {}}', true, 1)
) AS transitions(from_stage_key, to_stage_key, condition_expression, is_automatic, transition_order)
WHERE t.name = 'thorough_review_2_rounds_4_reviewers_20_tokens_v1';

-- 4. Define token ranks (1st through 4th place)
-- Distribution: 20 tokens total - 2 insurance = 18 tokens for reviewers
-- Top-heavy approach: 1st gets 39%, 2nd gets 28%, 3rd gets 22%, 4th gets 11%
INSERT INTO pr_template_ranks (template_id, rank_position, tokens)
SELECT t.template_id, rank_position, tokens
FROM pr_templates t,
LATERAL (
  VALUES
    (1, 7),  -- 1st place: 7 tokens (39%)
    (2, 5),  -- 2nd place: 5 tokens (28%)
    (3, 4),  -- 3rd place: 4 tokens (22%)
    (4, 2)   -- 4th place: 2 tokens (11%)
           -- Insurance: 2 tokens  (10%) - stored in template
) AS ranks(rank_position, tokens)
WHERE t.name = 'thorough_review_2_rounds_4_reviewers_20_tokens_v1'
ON CONFLICT (template_id, rank_position) DO UPDATE
  SET tokens = EXCLUDED.tokens;

