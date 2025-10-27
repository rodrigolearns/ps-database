-- =============================================
-- 00000000000047_jc_template_standard_v1.sql
-- JC Template: Standard Journal Club (v1)
-- =============================================
-- Simple workflow: review → assessment → awarding
-- Manual progression (creator-controlled), no deadlines, invitation-only

-- 1. Create template record
INSERT INTO jc_templates (name, user_facing_name, description, max_participants, is_public, display_order)
VALUES (
  'jc_standard_v1',
  'Standard Journal Club',  -- User-facing display name
  'Review, collaborative assessment, and awards. Manual progression with no deadlines.',
  999,   -- max_participants (unlimited)
  true,  -- is_public
  1      -- display_order
)
ON CONFLICT (name) DO UPDATE
  SET user_facing_name = EXCLUDED.user_facing_name,
      description = EXCLUDED.description,
      max_participants = EXCLUDED.max_participants,
      is_public = EXCLUDED.is_public,
      display_order = EXCLUDED.display_order,
      updated_at = NOW();

-- 2. Define workflow stages
INSERT INTO template_stage_graph 
  (template_id, activity_type, stage_key, stage_type, stage_order, deadline_days, display_name, is_initial_stage, is_terminal_stage)
SELECT 
  t.template_id,
  'jc-activity',
  stage_key,
  stage_type,
  stage_order,
  deadline_days,
  display_name,
  is_initial_stage,
  is_terminal_stage
FROM jc_templates t,
LATERAL (
  VALUES
    ('jc_created', 'jc_created', 0, NULL::INTEGER, 'Inviting Reviewers', true, false),
    ('jc_review', 'jc_review', 1, NULL::INTEGER, 'Review Stage', false, false),
    ('jc_assessment', 'jc_assessment', 2, NULL::INTEGER, 'Collaborative Assessment', false, false),
    ('jc_awarding', 'jc_awarding', 3, NULL::INTEGER, 'Award Distribution', false, true)
) AS stages(stage_key, stage_type, stage_order, deadline_days, display_name, is_initial_stage, is_terminal_stage)
WHERE t.name = 'jc_standard_v1'
ON CONFLICT (template_id, activity_type, stage_key) DO NOTHING;

-- 3. Define stage transitions (all manual)
INSERT INTO template_stage_transitions 
  (template_id, activity_type, from_stage_key, to_stage_key, condition_expression, is_automatic, transition_order)
SELECT
  t.template_id,
  'jc-activity',
  from_stage_key,
  to_stage_key,
  condition_expression::jsonb,
  is_automatic,
  transition_order
FROM jc_templates t,
LATERAL (
  VALUES
    -- jc_created → jc_review (manual progression - creator decides when to start reviews)
    ('jc_created', 'jc_review', '{"type": "manual", "config": {}}', false, 1),
    
    -- jc_review → jc_assessment (manual progression - creator decides when reviews complete)
    ('jc_review', 'jc_assessment', '{"type": "manual", "config": {}}', false, 1),
    
    -- jc_assessment → jc_awarding (manual progression - creator decides when assessment complete)
    ('jc_assessment', 'jc_awarding', '{"type": "manual", "config": {}}', false, 1)
) AS transitions(from_stage_key, to_stage_key, condition_expression, is_automatic, transition_order)
WHERE t.name = 'jc_standard_v1';

