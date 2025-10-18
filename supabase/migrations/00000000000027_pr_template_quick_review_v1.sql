-- =============================================
-- 00000000000027_pr_template_quick_review_v1.sql
-- PR Template: Quick Review (v1)
-- =============================================
-- Single round review: quick turnaround for straightforward papers
-- Workflow: review_1 → assessment → awarding → publication_choice

-- 1. Create template record
INSERT INTO pr_templates (name, description, reviewer_count, total_tokens, extra_tokens, is_public, display_order)
VALUES (
  'quick_review_1_round_3_reviewers_10_tokens_v1',
  'Quick Review: 1 review round, 3 reviewers, 10 tokens total. Fast turnaround for straightforward papers.',
  3,    -- reviewer_count
  10,   -- total_tokens
  2,    -- extra_tokens (for top performers)
  true,  -- is_public
  1     -- display_order
)
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      reviewer_count = EXCLUDED.reviewer_count,
      total_tokens = EXCLUDED.total_tokens,
      extra_tokens = EXCLUDED.extra_tokens,
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
    ('review_1', 'review_round_1', 1, 3, 'Initial Review', true, false),
    ('assessment', 'collaborative_assessment', 2, 3, 'Consensus Assessment', false, false),
    ('awarding', 'award_distribution', 3, 3, 'Award Distribution', false, false),
    ('publication_choice', 'publication_choice', 4, NULL, 'Publication Decision', false, true)
) AS stages(stage_key, stage_type, stage_order, deadline_days, display_name, is_initial_stage, is_terminal_stage)
WHERE t.name = 'quick_review_1_round_3_reviewers_10_tokens_v1'
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
    -- review_1 → assessment (when all reviews submitted)
    ('review_1', 'assessment', '{"type": "all_reviews_submitted", "config": {"round_number": 1}}', true, 1),
    
    -- assessment → awarding (when all finalized)
    ('assessment', 'awarding', '{"type": "all_finalized", "config": {}}', true, 1),
    
    -- awarding → publication_choice (when all distributed)
    ('awarding', 'publication_choice', '{"type": "all_awards_distributed", "config": {}}', true, 1)
) AS transitions(from_stage_key, to_stage_key, condition_expression, is_automatic, transition_order)
WHERE t.name = 'quick_review_1_round_3_reviewers_10_tokens_v1';

-- 4. Define token ranks (1st, 2nd, 3rd place)
INSERT INTO pr_template_ranks (template_id, rank_position, tokens)
SELECT t.template_id, rank_position, tokens
FROM pr_templates t,
LATERAL (
  VALUES
    (1, 4),  -- 1st place: 4 tokens
    (2, 3),  -- 2nd place: 3 tokens
    (3, 3)   -- 3rd place: 3 tokens
) AS ranks(rank_position, tokens)
WHERE t.name = 'quick_review_1_round_3_reviewers_10_tokens_v1'
ON CONFLICT (template_id, rank_position) DO UPDATE
  SET tokens = EXCLUDED.tokens;

